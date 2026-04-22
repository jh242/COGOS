import Foundation

/// Persistent conversation context. Ports `lib/models/claude_session.dart`.
final class ClaudeSession {
    static let maxTurns = 20

    struct Message {
        let role: String  // "user" or "assistant"
        let content: String
    }

    var messages: [Message] = []
    var lastQuery: String?
    var lastAnswer: String?

    func addUser(_ text: String) { messages.append(.init(role: "user", content: text)) }
    func addAssistant(_ text: String) { messages.append(.init(role: "assistant", content: text)) }

    func reset() {
        messages.removeAll()
        lastQuery = nil
        lastAnswer = nil
    }
}
