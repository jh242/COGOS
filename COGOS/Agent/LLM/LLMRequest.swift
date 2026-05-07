import Foundation

struct LLMRequest: Sendable {
    var messages: [ChatMessage]

    init(messages: [ChatMessage]) {
        self.messages = messages
    }
}
