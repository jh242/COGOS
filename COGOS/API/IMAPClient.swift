import Foundation
import SwiftMail

enum IMAPClientError: Error, LocalizedError, Sendable {
    case notConfigured
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Mail is not connected. Add an IMAP username and app-specific password in Settings."
        case .loginFailed(let message):
            return "IMAP login failed: \(message)"
        }
    }
}

/// Read-only IMAP search via Cocoanetics SwiftMail (`IMAPServer`).
struct IMAPClient: Sendable {
    let credentials: IMAPCredentials

    func search(query: String, maxResults: Int = 8) async throws -> String {
        guard credentials.isConfigured else { throw IMAPClientError.notConfigured }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(max(1, maxResults), 8)
        let plan = IMAPSearchQuery.plan(from: trimmed)

        return try await withServer { server in
            let mailbox = try await server.examineMailbox(credentials.mailbox)
            let infos: [MessageInfo]
            switch plan {
            case .recent:
                guard let set = mailbox.latest(limit) else {
                    return "Inbox is empty."
                }
                infos = try await fetchInfos(server, using: set)
            case .keys(let keys):
                let result: ExtendedSearchResult<UID> = try await server.extendedSearch(
                    criteria: keys.map(\.asSearchCriteria)
                )
                let set = Self.newestIdentifiers(from: result, limit: limit)
                guard !set.isEmpty else {
                    return trimmed.isEmpty
                        ? "Inbox is empty."
                        : "No mail matched \"\(trimmed)\"."
                }
                infos = try await fetchInfos(server, using: set)
            }
            guard !infos.isEmpty else {
                return trimmed.isEmpty
                    ? "Inbox is empty."
                    : "No mail matched \"\(trimmed)\"."
            }
            return infos
                .map(Self.summary(from:))
                .map(\.formattedLine)
                .joined(separator: "\n")
        }
    }

    func probe() async throws -> String {
        guard credentials.isConfigured else { throw IMAPClientError.notConfigured }
        return try await withServer { server in
            let mailbox = try await server.examineMailbox(credentials.mailbox)
            return "Connected to \(credentials.host). \(credentials.mailbox) has \(mailbox.messageCount) messages."
        }
    }

    private func withServer<T: Sendable>(
        _ work: @Sendable (IMAPServer) async throws -> T
    ) async throws -> T {
        let server = IMAPServer(host: credentials.host, port: credentials.port)
        do {
            try await server.connect()
            try await authenticate(server)
            let value = try await work(server)
            try? await server.logout()
            return value
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    private func authenticate(_ server: IMAPServer) async throws {
        do {
            try await server.login(username: credentials.username, password: credentials.password)
        } catch {
            do {
                try await server.authenticatePlain(
                    username: credentials.username,
                    password: credentials.password
                )
            } catch {
                throw IMAPClientError.loginFailed(error.localizedDescription)
            }
        }
    }

    private func fetchInfos<T: MessageIdentifier>(
        _ server: IMAPServer,
        using set: MessageIdentifierSet<T>
    ) async throws -> [MessageInfo] {
        let infos = try await server.fetchMessageInfosBulk(using: set, options: .slim)
        return infos.sorted { lhs, rhs in
            (lhs.date ?? lhs.internalDate ?? .distantPast) > (rhs.date ?? rhs.internalDate ?? .distantPast)
        }
    }

    static func newestIdentifiers(
        from result: ExtendedSearchResult<UID>,
        limit: Int
    ) -> UIDSet {
        if let partial = result.partial, !partial.results.isEmpty {
            return newest(partial.results, limit: limit)
        }
        if let ordered = result.ordered, !ordered.isEmpty {
            return UIDSet(Array(ordered.suffix(limit)))
        }
        if let all = result.all, !all.isEmpty {
            return newest(all, limit: limit)
        }
        return UIDSet()
    }

    static func newest(_ set: UIDSet, limit: Int) -> UIDSet {
        let ids = set.toArray().sorted { $0.value > $1.value }
        return UIDSet(Array(ids.prefix(limit)))
    }

    static func summary(from info: MessageInfo) -> MailMessageSummary {
        MailMessageSummary(
            from: info.from?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            subject: info.subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            date: format(info.date ?? info.internalDate),
            snippet: ""
        )
    }

    static func format(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension IMAPSearchKey {
    var asSearchCriteria: SearchCriteria {
        switch self {
        case .unseen: return .unseen
        case .seen: return .seen
        case .from(let value): return .from(value)
        case .subject(let value): return .subject(value)
        case .to(let value): return .to(value)
        case .text(let value): return .text(value)
        case .since(let date): return .since(date)
        }
    }
}
