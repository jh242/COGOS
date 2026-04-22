import Foundation

/// Backend-agnostic chat client. Concrete implementations assume an
/// OpenAI-compatible `/v1/chat/completions` endpoint — Anthropic-specific
/// headers, event names, and body shape have been retired.
protocol ChatCompletionsClient {
    func stream(message: String, session: ClaudeSession) -> AsyncThrowingStream<String, Error>
}

/// Streaming client for any OpenAI-compatible Chat Completions endpoint
/// (`POST {baseURL}/chat/completions` with `stream: true`).
/// Parses `data: {choices:[{delta:{content}}]}` SSE frames.
final class OpenAICompatibleClient: ChatCompletionsClient {
    private static let systemPrompt = """
        You are a wearable assistant on smart glasses. Voice in, five-line display out.

        Plain UTF-8 only — no markdown, no bullets, no emoji.
        Metric units always (°C, km, m).
        Answer in five lines or fewer. Short sentences; numbers over words when it saves room.
        No preambles, no trailing offers, no echoing the question.
        Current time and location are ambient context.
        Voice input may have STT errors — be charitable with homophones and fragments.
        If truly ambiguous, ask one short clarifying question. Otherwise answer.
        Tone: direct, dry, confident.
        """

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let useStreaming: Bool
    private let singleMessageMode: Bool

    init(baseURL: URL, apiKey: String,
         model: String = "claude-sonnet-4-6", maxTokens: Int = 1024,
         useStreaming: Bool = false, singleMessageMode: Bool = true) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.useStreaming = useStreaming
        self.singleMessageMode = singleMessageMode
    }

    func stream(message: String, session: ClaudeSession) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var all: [[String: String]]
                if singleMessageMode {
                    let folded = Self.systemPrompt + "\n\n---\n\n" + message
                    all = [["role": "user", "content": folded]]
                } else {
                    all = [["role": "system", "content": Self.systemPrompt]]
                    all.append(contentsOf: session.messages.map { ["role": $0.role, "content": $0.content] })
                    all.append(["role": "user", "content": message])
                    if all.count > ClaudeSession.maxTurns + 1 {
                        all = [all[0]] + Array(all.suffix(ClaudeSession.maxTurns))
                    }
                }

                var body: [String: Any] = [
                    "model": model,
                    "max_tokens": maxTokens,
                    "messages": all
                ]
                if useStreaming { body["stream"] = true }
                guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                    continuation.finish(throwing: NSError(domain: "ChatCompletions", code: -1))
                    return
                }

                var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                req.httpMethod = "POST"
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.setValue(useStreaming ? "text/event-stream" : "application/json",
                             forHTTPHeaderField: "accept")
                req.httpBody = bodyData
                req.timeoutInterval = 60

                do {
                    if useStreaming {
                        try await runStreaming(req: req, continuation: continuation)
                    } else {
                        try await runOneShot(req: req, continuation: continuation)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runStreaming(req: URLRequest,
                              continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation.finish(throwing: NSError(domain: "ChatCompletions", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
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
                    if let delta = Self.extractDelta(event.data) {
                        continuation.yield(delta)
                    }
                }
            }
        }
        continuation.finish()
    }

    private func runOneShot(req: URLRequest,
                            continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            continuation.finish(throwing: NSError(domain: "ChatCompletions", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(snippet)"]))
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String, !content.isEmpty else {
            continuation.finish(throwing: NSError(domain: "ChatCompletions", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "empty response"]))
            return
        }
        // Fake streaming: yield word-by-word so the 0x54 firmware sees the
        // same cumulative-growth pattern it expects from real SSE. BLE ACK
        // roundtrips in `sendEvenAIText` provide natural pacing — no sleep.
        var token = ""
        for char in content {
            token.append(char)
            if char.isWhitespace {
                continuation.yield(token)
                token = ""
            }
        }
        if !token.isEmpty { continuation.yield(token) }
        continuation.finish()
    }

    private static func extractDelta(_ json: String) -> String? {
        guard !json.isEmpty, json != "[DONE]",
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else { return nil }
        return content
    }
}
