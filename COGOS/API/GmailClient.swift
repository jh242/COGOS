import Foundation

struct GmailHTTPError: Error, LocalizedError, Sendable {
    let statusCode: Int
    let serverMessage: String?

    var errorDescription: String? {
        switch statusCode {
        case 401, 403:
            return "Gmail authentication failed. Check the access token."
        case 429:
            return "Gmail is rate-limited. Try again shortly."
        case 500...599:
            return serverMessage ?? "Gmail is temporarily unavailable."
        default:
            return serverMessage ?? "Gmail request failed (HTTP \(statusCode))."
        }
    }
}

enum GmailClientError: Error, LocalizedError, Sendable {
    case notConfigured
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Gmail is not connected. Add a Gmail access token in Settings."
        case .invalidResponse:
            return "Gmail returned an invalid response."
        }
    }
}

struct GmailMessageSummary: Equatable, Sendable {
    var from: String
    var subject: String
    var date: String
    var snippet: String
}

/// Read-only Gmail REST client. Needs an OAuth access token with `gmail.readonly`.
struct GmailClient: Sendable {
    static let defaultBaseURL = URL(string: "https://gmail.googleapis.com/gmail/v1")!

    private let accessToken: String
    private let session: URLSession
    private let baseURL: URL

    init(
        accessToken: String,
        session: URLSession = .shared,
        baseURL: URL = GmailClient.defaultBaseURL
    ) {
        self.accessToken = accessToken
        self.session = session
        self.baseURL = baseURL
    }

    func search(query: String, maxResults: Int = 8) async throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(max(1, maxResults), 8)
        var components = URLComponents(
            url: baseURL.appendingPathComponent("users/me/messages"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed.isEmpty ? "in:inbox" : trimmed),
            URLQueryItem(name: "maxResults", value: String(limit))
        ]
        guard let listURL = components.url else { throw GmailClientError.invalidResponse }

        var listRequest = URLRequest(url: listURL)
        listRequest.httpMethod = "GET"
        listRequest.timeoutInterval = 20
        applyAuth(to: &listRequest)

        let (listData, listResponse) = try await session.data(for: listRequest)
        try Self.validate(listResponse, body: listData)
        let ids = try Self.parseMessageIDs(from: listData)
        guard !ids.isEmpty else {
            return trimmed.isEmpty
                ? "Inbox is empty."
                : "No mail matched \"\(trimmed)\"."
        }

        var lines: [String] = []
        for id in ids {
            let summary = try await fetchSummary(id: id)
            lines.append(summary.formattedLine)
        }
        return lines.joined(separator: "\n")
    }

    private func fetchSummary(id: String) async throws -> GmailMessageSummary {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("users/me/messages/\(id)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "Date")
        ]
        guard let url = components.url else { throw GmailClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, body: data)
        return try Self.parseSummary(from: data)
    }

    private func applyAuth(to request: inout URLRequest) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    static func parseMessageIDs(from data: Data) throws -> [String] {
        let decoded = try JSONDecoder().decode(MessageList.self, from: data)
        return (decoded.messages ?? []).compactMap(\.id)
    }

    static func parseSummary(from data: Data) throws -> GmailMessageSummary {
        let decoded = try JSONDecoder().decode(MessageDetail.self, from: data)
        let headers = decoded.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name?.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        return GmailMessageSummary(
            from: header("From"),
            subject: header("Subject"),
            date: header("Date"),
            snippet: decoded.snippet ?? ""
        )
    }

    private static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GmailClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw httpError(statusCode: http.statusCode, body: body)
        }
    }

    private static func httpError(statusCode: Int, body: Data) -> GmailHTTPError {
        let message: String?
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            message = error["message"] as? String
        } else {
            message = nil
        }
        return GmailHTTPError(statusCode: statusCode, serverMessage: message)
    }

    private struct MessageList: Decodable {
        let messages: [Ref]?

        struct Ref: Decodable {
            let id: String?
        }
    }

    private struct MessageDetail: Decodable {
        let snippet: String?
        let payload: Payload?

        struct Payload: Decodable {
            let headers: [Header]?
        }

        struct Header: Decodable {
            let name: String?
            let value: String?
        }
    }
}

extension GmailMessageSummary {
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
