import Foundation

struct WriteAgentNoteTool: AgentTool {
    let spec = ToolSpec(
        name: "write_agent_note",
        description: "Write a short note from the assistant to the Agent glance provider on the glasses dashboard.",
        parameters: .object(
            properties: [
                "title": .string(description: "Short note title."),
                "body": .string(description: "Brief note body to show on the dashboard.")
            ],
            required: ["title", "body"]
        )
    )

    func call(_ arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        guard let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw AgentToolError.invalidArguments("Missing required string argument: title")
        }
        guard let body = arguments["body"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else {
            throw AgentToolError.invalidArguments("Missing required string argument: body")
        }

        await MainActor.run {
            context.agentSource.setNote(title: title, body: body)
        }
        return .object(["ok": .bool(true)])
    }
}
