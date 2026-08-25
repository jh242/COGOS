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

struct OpenRouterModelInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Thin OpenAI-compatible chat client aimed at OpenRouter.
/// Used by the news glance for a cheap, non-streaming digest — not for
/// the Hermes conversation path.
struct OpenRouterClient: Sendable {
    static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    static let defaultModel = "poolside/laguna-xs-2.1:free"

    /// Shown immediately in Settings so the picker isn't empty before the
    /// live `/models` list arrives. Free-pool membership rotates.
    static let fallbackFreeModels: [OpenRouterModelInfo] = [
        OpenRouterModelInfo(id: "openrouter/free", name: "Free Models Router"),
        OpenRouterModelInfo(id: "poolside/laguna-xs-2.1:free", name: "Poolside: Laguna XS 2.1 (free)"),
        OpenRouterModelInfo(id: "poolside/laguna-s-2.1:free", name: "Poolside: Laguna S 2.1 (free)"),
        OpenRouterModelInfo(id: "google/gemma-4-31b-it:free", name: "Google: Gemma 4 31B (free)"),
        OpenRouterModelInfo(id: "nvidia/nemotron-3.5-lightning:free", name: "NVIDIA: Nemotron 3.5 Lightning (free)")
    ]

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

    /// Public catalog; no API key required. Returns glanceable free text models
    /// (the `:free` pool rotates) sorted with the auto-router and default first.
    static func listFreeModels(
        session: URLSession = .shared,
        baseURL: URL = OpenRouterClient.defaultBaseURL
    ) async throws -> [OpenRouterModelInfo] {
        var request = URLRequest(url: endpoint("models", baseURL: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw httpError(statusCode: http.statusCode, body: data)
        }
        return try parseFreeModels(from: data)
    }

    static func parseFreeModels(from data: Data) throws -> [OpenRouterModelInfo] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        let free = decoded.data.compactMap { model -> OpenRouterModelInfo? in
            guard isGlanceableFree(model) else { return nil }
            return OpenRouterModelInfo(id: model.id, name: model.name)
        }
        return sortedForPicker(free)
    }

    static func pickerModels(
        live: [OpenRouterModelInfo],
        selected: String
    ) -> [OpenRouterModelInfo] {
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = live.isEmpty ? fallbackFreeModels : live
        if !trimmed.isEmpty, !list.contains(where: { $0.id == trimmed }) {
            list.insert(OpenRouterModelInfo(id: trimmed, name: trimmed), at: 0)
        }
        return list
    }

    private static func isGlanceableFree(_ model: ModelsResponse.Model) -> Bool {
        let outputs = Set(model.architecture?.outputModalities ?? ["text"])
        guard outputs.contains("text"), !outputs.contains("audio") else { return false }
        if model.id.localizedCaseInsensitiveContains("content-safety") { return false }
        if model.id.hasSuffix(":free") || model.id == "openrouter/free" { return true }
        return isZero(model.pricing?.prompt) && isZero(model.pricing?.completion)
    }

    private static func isZero(_ price: String?) -> Bool {
        guard let price, let value = Double(price) else { return false }
        return value == 0
    }

    private static func sortedForPicker(_ models: [OpenRouterModelInfo]) -> [OpenRouterModelInfo] {
        models.sorted { a, b in
            let ra = pickerRank(a.id)
            let rb = pickerRank(b.id)
            if ra != rb { return ra < rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func pickerRank(_ id: String) -> Int {
        if id == "openrouter/free" { return 0 }
        if id == defaultModel { return 1 }
        return 2
    }

    private func endpoint(_ name: String) -> URL {
        Self.endpoint(name, baseURL: baseURL)
    }

    private static func endpoint(_ name: String, baseURL: URL) -> URL {
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

private struct ModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
        let name: String
        let pricing: Pricing?
        let architecture: Architecture?
    }

    struct Pricing: Decodable {
        let prompt: String?
        let completion: String?
    }

    struct Architecture: Decodable {
        let outputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case outputModalities = "output_modalities"
        }
    }
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
