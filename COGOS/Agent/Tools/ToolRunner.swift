import Foundation

struct ToolResult: Sendable, Equatable {
    let toolCallID: String
    let name: String
    let payload: JSONValue

    func asChatMessage() -> ChatMessage {
        ChatMessage.toolResult(toolCallID: toolCallID, content: payload.jsonString())
    }
}

struct ToolRunner: Sendable {
    private let registry: ToolRegistry
    private let context: ToolContext

    init(registry: ToolRegistry, context: ToolContext) {
        self.registry = registry
        self.context = context
    }

    /// Executes finalized tool calls only. Partial streamed deltas never reach
    /// this type; the backend emits `.toolCallsFinal` after the model turn is
    /// complete.
    func run(_ calls: [ToolCall]) async -> [ToolResult] {
        var results: [ToolResult] = []
        for call in calls {
            guard let tool = registry.tool(named: call.name) else {
                results.append(errorResult(call: call, message: "Unknown tool: \(call.name)"))
                continue
            }

            do {
                let arguments = try JSONValue.parse(call.argumentsJSON)
                let payload = try await tool.call(arguments, context: context)
                results.append(ToolResult(toolCallID: call.id, name: call.name, payload: payload))
            } catch {
                results.append(errorResult(call: call, message: error.localizedDescription))
            }
        }
        return results
    }

    private func errorResult(call: ToolCall, message: String) -> ToolResult {
        ToolResult(
            toolCallID: call.id,
            name: call.name,
            payload: .object([
                "ok": .bool(false),
                "error": .string(message)
            ])
        )
    }
}
