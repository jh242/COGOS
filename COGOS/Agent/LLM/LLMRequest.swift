import Foundation

struct LLMRequest: Sendable {
    var messages: [ChatMessage]
    var tools: [ToolSpec]?

    init(messages: [ChatMessage], tools: [ToolSpec]? = nil) {
        self.messages = messages
        self.tools = tools?.isEmpty == true ? nil : tools
    }
}
