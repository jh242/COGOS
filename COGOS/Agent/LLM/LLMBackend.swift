import Foundation

protocol LLMBackend: Sendable {
    var capabilities: LLMCapabilities { get }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMBackendEvent, Error>
}

/// HTTP-level failure from an LLM backend. Carries the status code so the
/// runtime can tell "this request shape was rejected" apart from auth,
/// billing, or rate-limit failures.
struct LLMHTTPError: Error, LocalizedError, Sendable {
    let statusCode: Int
    let bodySnippet: String

    var errorDescription: String? {
        bodySnippet.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(bodySnippet)"
    }

    /// True when the status suggests the server rejected the request shape
    /// (e.g. an unsupported `tools` parameter) rather than failing auth,
    /// billing, or rate limits — the cases where retrying a simpler request
    /// can help.
    var suggestsUnsupportedRequestShape: Bool {
        switch statusCode {
        case 401, 402, 403, 407, 408, 429: return false
        case 400..<500: return true
        default: return false
        }
    }
}

struct LLMCapabilities: Codable, Sendable {
    var supportsNativeTools: Bool
    var supportsStreaming: Bool
    var supportsStreamingToolCalls: Bool
    var supportsStructuredOutput: Bool

    static let openAICompatibleText = LLMCapabilities(
        supportsNativeTools: true,
        supportsStreaming: true,
        supportsStreamingToolCalls: false,
        supportsStructuredOutput: false
    )
}
