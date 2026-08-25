import Foundation
import FoundationModels

struct MailTool: Tool {
    let name = "search_mail"
    let description = "Search the wearer's IMAP mailbox (iCloud or other). Use from:name, subject:word, is:unread, newer_than:2d, or plain text. Empty query returns the newest messages."
    let context: AgentDeviceContext

    @Generable
    struct Arguments {
        @Guide(description: "Mail search query. Empty or in:inbox returns the newest messages.")
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
