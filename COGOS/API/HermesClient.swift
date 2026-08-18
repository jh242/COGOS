import Foundation

struct HermesHTTPError: Error, LocalizedError, Sendable {
    let statusCode: Int
    let serverMessage: String?

    init(statusCode: Int, serverMessage: String? = nil) {
        self.statusCode = statusCode
        self.serverMessage = serverMessage
    }

    var errorDescription: String? {
        switch statusCode {
        case 401, 403:
            return "Hermes authentication failed. Check the access token."
        case 429:
            return "Hermes is busy. Try again shortly."
        case 500...599:
            return serverMessage ?? "Hermes is temporarily unavailable."
        default:
            return serverMessage ?? "Hermes request failed (HTTP \(statusCode))."
        }
    }
}

enum HermesClientError: Error, LocalizedError, Sendable {
    case emptyResponse
    case incompleteResponse
    case invalidEvent
    case incompatibleServer

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Hermes returned an empty response."
        case .incompleteResponse:
            return "The Hermes response was interrupted. Try again."
        case .invalidEvent:
            return "Hermes returned an invalid response."
        case .incompatibleServer:
            return "This endpoint does not advertise Hermes Responses API support."
        }
    }
}

struct HermesConnectionReport: Equatable, Sendable {
    enum StreamingState: Equatable, Sendable {
        case verified
        case buffered
    }

    let version: String?
    let streaming: StreamingState

    var statusText: String {
        let versionSuffix = version.map { " (Hermes \($0))" } ?? ""
        switch streaming {
        case .verified:
            return "Connected — streaming verified\(versionSuffix)"
        case .buffered:
            return "Connected — responses appear buffered\(versionSuffix)"
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
        streamResponse(
            to: input,
            conversationID: conversationID,
            sessionKey: sessionKey,
            instructions: Self.displayInstructions,
            store: true,
            probeRecorder: nil
        )
    }

    private func streamResponse(
        to input: String,
        conversationID: String,
        sessionKey: String,
        instructions: String,
        store: Bool,
        probeRecorder: StreamProbeRecorder?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let worker = Task {
                do {
                    let request = try makeResponseRequest(
                        input: input,
                        conversationID: conversationID,
                        sessionKey: sessionKey,
                        instructions: instructions,
                        store: store
                    )
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       !(200...299).contains(http.statusCode) {
                        var errorBody = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            guard errorBody.count < Self.maxErrorBodyBytes else { break }
                            errorBody.append(byte)
                        }
                        throw Self.httpError(statusCode: http.statusCode, body: errorBody)
                    }
                    try Self.validate(response)

                    let parser = SSEParser()
                    var lineData = Data()
                    var accumulated = ""

                    func process(_ events: [SSEParser.Event]) throws -> Bool {
                        for event in events {
                            let parsed = try Self.parse(event)
                            switch parsed {
                            case .delta(let delta):
                                probeRecorder?.recordDelta()
                                accumulated += delta
                                continuation.yield(accumulated)
                            case .completed(let fallbackText):
                                probeRecorder?.recordCompleted()
                                if accumulated.isEmpty, let fallbackText, !fallbackText.isEmpty {
                                    accumulated = fallbackText
                                    continuation.yield(accumulated)
                                }
                                guard !accumulated.isEmpty else {
                                    throw HermesClientError.emptyResponse
                                }
                                continuation.finish()
                                return true
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
                        return false
                    }

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        lineData.append(byte)
                        guard byte == 0x0A else { continue }

                        let events = parser.feed(lineData)
                        lineData.removeAll(keepingCapacity: true)
                        if try process(events) { return }
                    }

                    if !lineData.isEmpty {
                        _ = parser.feed(lineData)
                    }
                    if try process(parser.finish()) { return }

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

    func checkConnection() async throws -> HermesConnectionReport {
        async let version = serverVersion()

        var request = URLRequest(url: endpoint(named: "capabilities"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, body: data)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = object["features"] as? [String: Any],
              features["responses_api"] as? Bool == true else {
            throw HermesClientError.incompatibleServer
        }

        let probeID = "cogos-stream-probe-\(UUID().uuidString.lowercased())"
        let recorder = StreamProbeRecorder()
        let stream = streamResponse(
            to: "Output exactly the integers 1 through 40, separated by single spaces, and nothing else.",
            conversationID: probeID,
            sessionKey: probeID,
            instructions: "This is a transport test. Follow the requested output format exactly.",
            store: false,
            probeRecorder: recorder
        )
        for try await _ in stream {}

        let metrics = recorder.metrics()
        let streaming: HermesConnectionReport.StreamingState =
            metrics.deltaCount >= 2 && metrics.firstDeltaLeadNanoseconds >= 200_000_000
            ? .verified
            : .buffered
        return HermesConnectionReport(version: await version, streaming: streaming)
    }

    private func serverVersion() async -> String? {
        var request = URLRequest(url: endpoint(named: "health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }

    private func makeResponseRequest(
        input: String,
        conversationID: String,
        sessionKey: String,
        instructions: String,
        store: Bool
    ) throws -> URLRequest {
        let body = ResponseRequest(
            input: input,
            conversation: conversationID,
            instructions: instructions,
            store: store,
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

    private static let maxErrorBodyBytes = 4_096

    private static func validate(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HermesClientError.invalidEvent
        }
        guard (200...299).contains(http.statusCode) else {
            throw httpError(statusCode: http.statusCode, body: body ?? Data())
        }
    }

    private static func httpError(statusCode: Int, body: Data) -> HermesHTTPError {
        let message: String?
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            message = sanitizedServerMessage(error["message"] as? String)
        } else {
            message = nil
        }
        return HermesHTTPError(statusCode: statusCode, serverMessage: message)
    }

    private static func sanitizedServerMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let oneLine = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }
        return String(oneLine.prefix(240))
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

private final class StreamProbeRecorder: @unchecked Sendable {
    struct Metrics {
        let deltaCount: Int
        let firstDeltaLeadNanoseconds: UInt64
    }

    private let lock = NSLock()
    private var deltaCount = 0
    private var firstDeltaNanoseconds: UInt64?
    private var completionNanoseconds: UInt64?

    func recordDelta(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        deltaCount += 1
        if firstDeltaNanoseconds == nil { firstDeltaNanoseconds = now }
        lock.unlock()
    }

    func recordCompleted(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        completionNanoseconds = now
        lock.unlock()
    }

    func metrics() -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        let lead: UInt64
        if let firstDeltaNanoseconds, let completionNanoseconds,
           completionNanoseconds >= firstDeltaNanoseconds {
            lead = completionNanoseconds - firstDeltaNanoseconds
        } else {
            lead = 0
        }
        return Metrics(deltaCount: deltaCount, firstDeltaLeadNanoseconds: lead)
    }
}
