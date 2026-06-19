import Foundation

struct ToolRegistry: Sendable {
    private let toolsByName: [String: any AgentTool]

    init(tools: [any AgentTool] = []) {
        var map: [String: any AgentTool] = [:]
        for tool in tools {
            map[tool.spec.function.name] = tool
        }
        self.toolsByName = map
    }

    func specs() -> [ToolSpec] {
        toolsByName.values.map(\.spec).sorted { $0.function.name < $1.function.name }
    }

    func tool(named name: String) -> (any AgentTool)? {
        toolsByName[name]
    }
}
