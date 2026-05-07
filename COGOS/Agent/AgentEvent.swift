import Foundation

/// Normalized events entering the agent runtime.
enum AgentEvent: Codable, Sendable {
    case appLaunched
    case voiceTranscriptFinal(String)
    case userCancelled
    case resetRequested
}
