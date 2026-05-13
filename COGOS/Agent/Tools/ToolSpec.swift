import Foundation

/// OpenAI-compatible function-tool declaration.
struct ToolSpec: Codable, Sendable, Equatable {
    let type: String
    let function: Function

    init(
        name: String,
        description: String,
        parameters: JSONSchema,
        type: String = "function"
    ) {
        self.type = type
        self.function = Function(name: name, description: description, parameters: parameters)
    }

    struct Function: Codable, Sendable, Equatable {
        let name: String
        let description: String
        let parameters: JSONSchema
    }
}
