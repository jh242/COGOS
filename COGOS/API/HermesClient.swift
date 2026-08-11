import Foundation

struct HermesHTTPError: Error, LocalizedError, Sendable {
    let statusCode: Int

    var errorDescription: String? {
        switch statusCode {
        case 401, 403:
            return "Hermes authentication failed. Check the access token."
        case 429:
            return "Hermes is busy. Try again shortly."
        case 500...599:
            return "Hermes is temporarily unavailable."
        default:
            return "Hermes request failed (HTTP \(statusCode))."
        }
    }
}

enum HermesClientError: Error, LocalizedError, Sendable {
    case emptyResponse
    case incompleteResponse
    case invalidEvent

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Hermes returned an empty response."
        case .incompleteResponse:
            return "The Hermes response was interrupted. Try again."
        case .invalidEvent:
            return "Hermes returned an invalid response."
        }
    }
}

struct HermesClient: Sendable {
    static let displayInstructions = "Answer concisely for a five-line smart-glasses display. Plain text only; no Markdown or emoji."

    private let baseURL: URL
    private let accessToken: String
    private let conversationID: String
    private let sessionKey: String
    private let session: URLSession

    init(
        baseURL: URL,
        accessToken: String,
        conversationID: String,
        sessionKey: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.conversationID = conversationID
        self.sessionKey = sessionKey
        self.session = session
    }

    /// Emits the complete answer-so-far. Keeping only the newest buffered
    /// snapshot lets fast network deltas coalesce while BLE waits for ACKs.
    func streamResponse(to input: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let worker = Task {
                do {
                    let request = try makeResponseRequest(input: input)
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response)

                    let parser = SSEParser()
                    var lineData = Data()
                    var accumulated = ""

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        lineData.append(byte)
                        guard byte == 0x0A else { continue }

                        let events = parser.feed(lineData)
                        lineData.removeAll(keepingCapacity: true)
                        for event in events {
                            let parsed = try Self.parse(event)
                            switch parsed {
                            case .delta(let delta):
                                accumulated += delta
                                continuation.yield(accumulated)
                            case .completed(let fallbackText):
                                if accumulated.isEmpty, let fallbackText, !fallbackText.isEmpty {
                                    accumulated = fallbackText
                                    continuation.yield(accumulated)
                                }
                                guard !accumulated.isEmpty else {
                                    throw HermesClientError.emptyResponse
                                }
                                continuation.finish()
                                return
                            case .failed(let message):
                                throw NSError(
                                    domain: "HermesClient",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: message]
                                )
                            case .ignored:
                                break
                            }
                        }
                    }

                    guard !accumulated.isEmpty else {
                        throw HermesClientError.emptyResponse
                    }
                    throw HermesClientError.incompleteResponse
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    worker.cancel()
                }
            }
        }
    }

    func checkConnection() async throws {
        var request = URLRequest(url: endpoint(named: "capabilities"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    private func makeResponseRequest(input: String) throws -> URLRequest {
        let body = ResponseRequest(
            input: input,
            conversation: conversationID,
            instructions: Self.displayInstructions,
            store: true,
            stream: true
        )

        var request = URLRequest(url: endpoint(named: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        return request
    }

    private func endpoint(named name: String) -> URL {
        var root = baseURL
        if root.lastPathComponent == "responses" || root.lastPathComponent == "capabilities" {
            root.deleteLastPathComponent()
        }
        if root.lastPathComponent != "v1" {
            root.appendPathComponent("v1")
        }
        return root.appendingPathComponent(name)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidEvent
        }
        guard (200...299).contains(http.statusCode) else {
            throw HermesHTTPError(statusCode: http.statusCode)
        }
    }

    private enum StreamEvent {
        case delta(String)
        case completed(String?)
        case failed(String)
        case ignored
    }

    private static func parse(_ event: SSEParser.Event) throws -> StreamEvent {
        guard let data = event.data.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesClientError.invalidEvent
        }
        let type = event.event ?? object["type"] as? String ?? ""

        switch type {
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else {
                throw HermesClientError.invalidEvent
            }
            return delta.isEmpty ? .ignored : .delta(delta)
        case "response.completed":
            let response = object["response"] as? [String: Any] ?? object
            return .completed(extractOutputText(from: response))
        case "response.failed", "response.incomplete", "error":
            let response = object["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any] ?? object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Hermes could not complete the request."
            return .failed(message)
        default:
            return .ignored
        }
    }

    private static func extractOutputText(from response: [String: Any]) -> String? {
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        let pieces = output.flatMap { item -> [String] in
            guard item["type"] as? String == "message",
                  item["role"] as? String == "assistant",
                  let content = item["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { part in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }
        }
        return pieces.isEmpty ? nil : pieces.joined()
    }
}

private struct ResponseRequest: Encodable {
    let input: String
    let conversation: String
    let instructions: String
    let store: Bool
    let stream: Bool
}
