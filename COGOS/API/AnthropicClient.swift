import Foundation

/// Streaming client for https://api.anthropic.com/v1/messages.
/// Ports `lib/services/api_claude_service.dart`.
final class AnthropicClient: NSObject {
    private static let systemPrompt =
        "You are a helpful assistant on Even Realities G1 smart glasses. " +
        "The display shows 5 lines at a time. Be concise. No markdown."

    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Streams assistant text chunks for a given user message + session history.
    func stream(message: String, session: ClaudeSession) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var all: [[String: String]] = session.messages.map { ["role": $0.role, "content": $0.content] }
                all.append(["role": "user", "content": message])
                if all.count > ClaudeSession.maxTurns {
                    all = Array(all.suffix(ClaudeSession.maxTurns))
                }

                let body: [String: Any] = [
                    "model": "claude-sonnet-4-6",
                    "max_tokens": 1024,
                    "stream": true,
                    "system": Self.systemPrompt,
                    "messages": all
                ]
                guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                    continuation.finish(throwing: NSError(domain: "Anthropic", code: -1))
                    return
                }

                var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                req.httpMethod = "POST"
                req.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = bodyData
                req.timeoutInterval = 60

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        continuation.finish(throwing: NSError(domain: "Anthropic", code: http.statusCode,
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
                                self.emitDelta(event: event, continuation: continuation)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func emitDelta(event: SSEParser.Event, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        guard event.event == "content_block_delta" else { return }
        let json = event.data
        guard !json.isEmpty, json != "[DONE]",
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let delta = obj["delta"] as? [String: Any],
              let type = delta["type"] as? String, type == "text_delta",
              let text = delta["text"] as? String, !text.isEmpty else { return }
        continuation.yield(text)
    }
}

/// Haiku one-shot client for glance summarization.
final class HaikuClient {
    private let apiKey: String
    init(apiKey: String) { self.apiKey = apiKey }

    func summarize(context: String, systemPrompt: String, maxTokens: Int = 100) async throws -> [String] {
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": context]]
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]], !content.isEmpty,
              let text = content[0]["text"] as? String else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(5).map { String($0) }
    }
}
