import Foundation
import OpenAISession
import SwiftAgent

enum OpenRouterAgentConfiguration {
    static let requestTimeout: TimeInterval = 180
    static let httpReferer = "https://github.com/jh242/COGOS"
    static let appTitle = "COGOS"

    /// Base URL whose `/v1/responses` path matches OpenRouter
    /// (`https://openrouter.ai/api/v1/responses`).
    static let apiRoot = URL(string: "https://openrouter.ai/api")!

    static func make(apiKey: String, sessionID: String) -> OpenAIConfiguration {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let interceptors = HTTPClientInterceptors(
            prepareRequest: { request in
                request.timeoutInterval = requestTimeout
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue(httpReferer, forHTTPHeaderField: "HTTP-Referer")
                request.setValue(appTitle, forHTTPHeaderField: "X-Title")
                request.setValue(sessionID, forHTTPHeaderField: "x-session-id")
                if let body = request.httpBody {
                    request.httpBody = OpenRouterResponsesSanitizer.sanitize(body)
                }
            }
        )

        let http = HTTPClientConfiguration(
            baseURL: apiRoot,
            defaultHeaders: [:],
            timeout: requestTimeout,
            jsonEncoder: encoder,
            jsonDecoder: JSONDecoder(),
            interceptors: interceptors
        )
        return OpenAIConfiguration(httpClient: URLSessionHTTPClient(configuration: http))
    }
}
