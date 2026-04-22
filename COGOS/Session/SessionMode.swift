import Foundation

/// Conversation mode for the AI session.
enum SessionMode: String {
    case chat
    case code

    var headerTag: String {
        switch self {
        case .chat: return "[CHAT]"
        case .code: return "[CODE]"
        }
    }
}
