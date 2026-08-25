import Foundation

/// Fallback glance provider. Fetches Google News RSS, then asks a cheap
/// OpenRouter model for a three-line digest sized for the Quick Notes pane.
/// If no API key is set (or the model call fails), clipped headlines are shown
/// instead. Last good copy is kept when a refresh fails.
@MainActor
final class NewsSource: ContextProvider {
    let name = "news"

    private static let refreshInterval: TimeInterval = 30 * 60
    private static let rssTimeout: TimeInterval = 10

    private let settings: Settings
    private let session: URLSession
    private let locale: Locale
    private let clientOverride: OpenRouterClient?

    private var lastFetch: Date?
    private var lastTopic: NewsTopic?
    private var displayBody: String = ""

    init(
        settings: Settings,
        session: URLSession = .shared,
        locale: Locale = .current,
        client: OpenRouterClient? = nil
    ) {
        self.settings = settings
        self.session = session
        self.locale = locale
        self.clientOverride = client
    }

    var currentNote: QuickNote? {
        guard !displayBody.isEmpty else { return nil }
        return QuickNote(title: "News", body: displayBody)
    }

    func refresh(_ ctx: GlanceContext) async {
        let topic = settings.newsTopic
        if let last = lastFetch,
           lastTopic == topic,
           ctx.now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }

        let titles: [String]
        do {
            titles = try await fetchTitles(topic: topic)
        } catch {
            trace("RSS fetch failed: \(error)")
            return
        }
        guard !titles.isEmpty else {
            trace("RSS parsed 0 titles")
            return
        }

        let digestTitles = Array(titles.prefix(NewsHeadlines.maxSourceHeadlines))
        var body = NewsHeadlines.fallbackBody(titles: digestTitles)
        if let client = clientOverride ?? settings.makeOpenRouterClient(session: session) {
            do {
                let raw = try await client.complete(
                    system: NewsHeadlines.systemPrompt,
                    user: NewsHeadlines.userPrompt(titles: digestTitles)
                )
                let sanitized = NewsHeadlines.sanitize(raw)
                if sanitized.isEmpty {
                    trace("digest empty after sanitize — using headline fallback")
                } else {
                    body = sanitized
                }
            } catch {
                trace("OpenRouter digest failed: \(error) — using headline fallback")
            }
        } else {
            trace("no OpenRouter key — using clipped headlines")
        }

        displayBody = body
        lastFetch = ctx.now
        lastTopic = topic
        trace("RSS → \(digestTitles.count) titles → \"\(displayBody.replacingOccurrences(of: "\n", with: " | "))\"")
    }

    private func fetchTitles(topic: NewsTopic) async throws -> [String] {
        var req = URLRequest(url: topic.rssURL(locale: locale))
        req.timeoutInterval = Self.rssTimeout
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/rss+xml, application/xml, text/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return NewsHeadlines.parseItemTitles(data)
    }
}
