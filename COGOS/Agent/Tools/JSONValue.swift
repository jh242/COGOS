import Foundation

/// Minimal in-tree JSON representation for tool arguments, schemas, and
/// results. Keeps the tool layer dependency-free while still round-tripping
/// through JSONEncoder / JSONDecoder.
enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    static func parse(_ json: String) throws -> JSONValue {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }
}

/// Thin wrapper used where the JSON value is specifically an OpenAI-style
/// function parameter schema.
struct JSONSchema: Codable, Sendable, Equatable {
    let value: JSONValue

    init(_ value: JSONValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        self.value = try JSONValue(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    static func object(properties: [String: JSONSchema], required: [String]) -> JSONSchema {
        JSONSchema(.object([
            "type": .string("object"),
            "properties": .object(properties.mapValues(\.value)),
            "required": .array(required.map { .string($0) })
        ]))
    }

    static func string(description: String? = nil) -> JSONSchema {
        var object: [String: JSONValue] = ["type": .string("string")]
        if let description { object["description"] = .string(description) }
        return JSONSchema(.object(object))
    }
}
