import Foundation

struct IMAPCredentials: Equatable, Sendable {
    static let iCloudHost = "imap.mail.me.com"
    static let defaultPort = 993
    static let defaultMailbox = "INBOX"

    var host: String
    var port: Int
    var username: String
    var password: String
    var mailbox: String

    var isConfigured: Bool {
        !host.isEmpty
            && (1...65_535).contains(port)
            && !username.isEmpty
            && !password.isEmpty
            && !mailbox.isEmpty
    }
}

struct MailMessageSummary: Equatable, Sendable {
    var from: String
    var subject: String
    var date: String
    var snippet: String
}

extension MailMessageSummary {
    var formattedLine: String {
        let who = from.isEmpty ? "Unknown sender" : from
        let what = subject.isEmpty ? "(no subject)" : subject
        let when = date.isEmpty ? "" : " · \(date)"
        let preview = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty {
            return "\(who)\(when)\n\(what)"
        }
        return "\(who)\(when)\n\(what)\n\(preview)"
    }
}
