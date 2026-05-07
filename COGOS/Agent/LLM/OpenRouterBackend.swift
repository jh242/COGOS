import Foundation

/// OpenRouter-first backend that speaks the OpenAI-compatible Chat
/// Completions wire format. Custom base URLs remain supported, so the same
/// backend can target local servers or OpenRouter-compatible proxies.
struct OpenRouterBackend: LLMBackend {
    let capabilities: LLMCapabilities = .openAICompatibleText

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let useStreaming: Bool

    init(
        baseURL: URL,
        apiKey: String,
        model: String,
        maxTokens: Int = 1024,
        useStreaming: Bool = false
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.useStreaming = useStreaming
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMBackendEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let urlRequest = try makeURLRequest(for: request)
                    if useStreaming {
                        try await runStreaming(req: urlRequest, continuation: continuation)
                    } else {
                        try await runOneShot(req: urlRequest, continuation: continuation)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func makeURLRequest(for request: LLMRequest) throws -> URLRequest {
        let messages = request.messages.map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages
        ]
        if useStreaming { body["stream"] = true }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(useStreaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "accept")
        if isOpenRouterURL(baseURL) {
            req.setValue("COGOS", forHTTPHeaderField: "X-Title")
        }
        req.httpBody = bodyData
        req.timeoutInterval = 60
        return req
    }

    private func runStreaming(
        req: URLRequest,
        continuation: AsyncThrowingStream<LLMBackendEvent, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation.finish(throwing: NSError(
                domain: "OpenRouterBackend",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            ))
            return
        }

        let parser = SSEParser()
        var bufferData = Data()
        for try await byte in bytes {
            bufferData.append(byte)
            if byte == 0x0a {
                let events = parser.feed(bufferData)
                bufferData.removeAll(keepingCapacity: true)
                for event in events {
                    if event.data == "[DONE]" {
                        continuation.yield(.final)
                        continuation.finish()
                        return
                    }
                    if let delta = Self.extractDelta(event.data) {
                        continuation.yield(.textDelta(delta))
                    }
                }
            }
        }
        continuation.yield(.final)
        continuation.finish()
    }

    private func runOneShot(
        req: URLRequest,
        continuation: AsyncThrowingStream<LLMBackendEvent, Error>.Continuation
    ) async throws {
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            continuation.finish(throwing: NSError(
                domain: "OpenRouterBackend",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(snippet)"]
            ))
            return
        }

        guard let content = Self.extractMessageContent(data), !content.isEmpty else {
            continuation.finish(throwing: NSError(
                domain: "OpenRouterBackend",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "empty response"]
            ))
            return
        }

        // Fake streaming: yield word-by-word so the 0x54 firmware sees the
        // same cumulative-growth pattern it expects from real SSE. BLE ACK
        // roundtrips in the renderer provide natural pacing — no sleep.
        var token = ""
        for char in content {
            token.append(char)
            if char.isWhitespace {
                continuation.yield(.textDelta(token))
                token = ""
            }
        }
        if !token.isEmpty { continuation.yield(.textDelta(token)) }
        continuation.yield(.final)
        continuation.finish()
    }

    private static func extractMessageContent(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else { return nil }
        return content
    }

    private static func extractDelta(_ json: String) -> String? {
        guard !json.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else { return nil }
        return content
    }

    private func isOpenRouterURL(_ url: URL) -> Bool {
        url.host?.localizedCaseInsensitiveContains("openrouter.ai") == true
    }
}
