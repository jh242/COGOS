import Foundation

struct ToolCall: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let argumentsJSON: String

    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case function
    }

    enum FunctionKeys: String, CodingKey {
        case name
        case arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        let function = try container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        self.name = try function.decode(String.self, forKey: .name)
        self.argumentsJSON = try function.decode(String.self, forKey: .arguments)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode("function", forKey: .type)
        var function = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        try function.encode(name, forKey: .name)
        try function.encode(argumentsJSON, forKey: .arguments)
    }
}

enum LLMBackendEvent: Sendable {
    case textDelta(String)
    case toolCallsFinal([ToolCall])
    case final
}
