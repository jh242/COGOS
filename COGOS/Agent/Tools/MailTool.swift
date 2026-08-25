import Foundation
import FoundationModels

struct MailTool: Tool {
    let name = "search_mail"
    let description = "Search the wearer's Gmail. Use Gmail search syntax when helpful, such as from:name, subject:word, is:unread, newer_than:2d."
    let context: AgentDeviceContext

    @Generable
    struct Arguments {
        @Guide(description: "Gmail search query. Use in:inbox if the user just wants recent mail.")
        var query: String
    }

    @Generable
    struct Output {
        var summary: String
    }

    func call(arguments: Arguments) async throws -> Output {
        let summary = await context.mailSearch(query: arguments.query)
        return Output(summary: summary)
    }
}
