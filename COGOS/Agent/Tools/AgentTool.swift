import Foundation

struct ToolContext: Sendable {
    let agentSource: AgentSource
}

protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    func call(_ arguments: JSONValue, context: ToolContext) async throws -> JSONValue
}

enum AgentToolError: LocalizedError, Sendable {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        }
    }
}
