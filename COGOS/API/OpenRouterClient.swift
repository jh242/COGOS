import Foundation

struct OpenRouterHTTPError: Error, LocalizedError, Sendable {
    let statusCode: Int
    let serverMessage: String?

    var errorDescription: String? {
        switch statusCode {
        case 401, 403:
            return "OpenRouter authentication failed. Check the API key."
        case 429:
            return "OpenRouter is rate-limited. Try again shortly."
        case 500...599:
            return serverMessage ?? "OpenRouter is temporarily unavailable."
        default:
            return serverMessage ?? "OpenRouter request failed (HTTP \(statusCode))."
        }
    }
}

enum OpenRouterClientError: Error, LocalizedError, Sendable {
    case emptyResponse
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "OpenRouter returned an empty response."
        case .invalidResponse:
            return "OpenRouter returned an invalid response."
        }
    }
}

/// Thin OpenAI-compatible chat client aimed at OpenRouter.
/// Used by the news glance for a cheap, non-streaming digest — not for
/// the Hermes conversation path.
struct OpenRouterClient: Sendable {
    static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    static let defaultModel = "openai/gpt-4.1-nano"

    private let baseURL: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let httpReferer: String
    private let appTitle: String

    init(
        apiKey: String,
        model: String = OpenRouterClient.defaultModel,
        baseURL: URL = OpenRouterClient.defaultBaseURL,
        session: URLSession = .shared,
        httpReferer: String = "https://github.com/jh242/COGOS",
        appTitle: String = "COGOS"
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
        self.httpReferer = httpReferer
        self.appTitle = appTitle
    }

    func complete(system: String, user: String) async throws -> String {
        let body = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: user)
            ],
            temperature: 0.3,
            maxTokens: 160,
            stream: false
        )

        var request = URLRequest(url: endpoint("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(httpReferer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(appTitle, forHTTPHeaderField: "X-Title")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.httpError(statusCode: http.statusCode, body: data)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw OpenRouterClientError.emptyResponse }
        return text
    }

    private func endpoint(_ name: String) -> URL {
        var root = baseURL
        if root.lastPathComponent != "v1" {
            root.appendPathComponent("v1")
        }
        return root.appendingPathComponent(name)
    }

    private static func httpError(statusCode: Int, body: Data) -> OpenRouterHTTPError {
        let message: String?
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                message = sanitized(error["message"] as? String)
            } else {
                message = sanitized(object["message"] as? String)
            }
        } else {
            message = nil
        }
        return OpenRouterHTTPError(statusCode: statusCode, serverMessage: message)
    }

    private static func sanitized(_ message: String?) -> String? {
        guard let message else { return nil }
        let oneLine = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }
        return String(oneLine.prefix(240))
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
