import Foundation

protocol LLMBackend: Sendable {
    var capabilities: LLMCapabilities { get }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMBackendEvent, Error>
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
