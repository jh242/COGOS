import Foundation

/// Maps spoken queries onto IMAP search keys.
/// Empty queries mean "newest mail", not SEARCH ALL.
enum IMAPSearchPlan: Equatable {
    case recent
    case keys([IMAPSearchKey])
}

enum IMAPSearchKey: Equatable {
    case unseen
    case seen
    case from(String)
    case subject(String)
    case to(String)
    case text(String)
    case since(Date)
}

enum IMAPSearchQuery {
    static func plan(
        from query: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> IMAPSearchPlan {
        let tokens = tokenize(query)
        if tokens.isEmpty { return .recent }

        var keys: [IMAPSearchKey] = []
        var rest: [String] = []

        for token in tokens {
            let lower = token.lowercased()
            if lower == "in:inbox" {
                continue
            }
            if lower == "unread" || lower == "unseen" || lower == "is:unread" {
                keys.append(.unseen)
                continue
            }
            if lower == "is:read" {
                keys.append(.seen)
                continue
            }
            if let value = prefixedValue("from:", in: token) {
                if !value.isEmpty { keys.append(.from(value)) }
                continue
            }
            if let value = prefixedValue("subject:", in: token) {
                if !value.isEmpty { keys.append(.subject(value)) }
                continue
            }
            if let value = prefixedValue("to:", in: token) {
                if !value.isEmpty { keys.append(.to(value)) }
                continue
            }
            if let spec = prefixedValue("newer_than:", in: token) ?? prefixedValue("since:", in: token) {
                if let date = parseDateSpec(spec, now: now, calendar: calendar) {
                    keys.append(.since(date))
                }
                continue
            }
            rest.append(token)
        }

        if keys.isEmpty && rest.isEmpty {
            return .recent
        }
        if !rest.isEmpty {
            keys.append(.text(rest.joined(separator: " ")))
        }
        return .keys(keys)
    }

    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in query.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func prefixedValue(_ prefix: String, in token: String) -> String? {
        guard token.lowercased().hasPrefix(prefix) else { return nil }
        return String(token.dropFirst(prefix.count))
    }

    static func parseDateSpec(_ spec: String, now: Date, calendar: Calendar) -> Date? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasSuffix("d"), let count = Int(lower.dropLast()), count > 0 {
            return calendar.date(byAdding: .day, value: -count, to: now)
        }
        if lower.hasSuffix("w"), let count = Int(lower.dropLast()), count > 0 {
            return calendar.date(byAdding: .day, value: -(count * 7), to: now)
        }
        if lower.hasSuffix("m"), let count = Int(lower.dropLast()), count > 0 {
            return calendar.date(byAdding: .month, value: -count, to: now)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        iso.timeZone = calendar.timeZone
        return iso.date(from: trimmed)
    }
}
