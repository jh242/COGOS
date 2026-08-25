import Foundation

/// Strips Responses-API fields OpenRouter rejects so SwiftAgent's OpenAI
/// adapter can post the full transcript without `store` / `previous_response_id`.
enum OpenRouterResponsesSanitizer {
    static func sanitize(_ body: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }
        object.removeValue(forKey: "previous_response_id")
        object.removeValue(forKey: "previousResponseId")
        object.removeValue(forKey: "store")
        guard JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return body
        }
        return encoded
    }
}
