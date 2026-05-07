import Foundation

enum LLMBackendEvent: Sendable {
    case textDelta(String)
    case final
}
