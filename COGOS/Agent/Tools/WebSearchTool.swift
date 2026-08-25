import Foundation
import FoundationModels

struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the live web for current information, news, or facts."
    let context: AgentDeviceContext

    @Generable
    struct Arguments {
        @Guide(description: "Search query.")
        var query: String
    }

    @Generable
    struct Output {
        var summary: String
    }

    func call(arguments: Arguments) async throws -> Output {
        let summary = await context.webSearch(query: arguments.query)
        return Output(summary: summary)
    }
}
