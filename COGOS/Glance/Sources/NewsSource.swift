import Foundation

/// Fallback provider — shows cached headlines when nothing higher-priority
/// is eligible. Because every other provider compact-filters out when idle,
/// News naturally fills a bottom slot once its cache is populated.
final class NewsSource: ContextProvider {
    let name = "news"
    let priority = 3

    private static let refreshInterval: TimeInterval = 30 * 60

    var topic: String = "BUSINESS"

    private var lastFetch: Date?
    private var cachedHeadlines: [String] = []

    var currentNote: QuickNote? {
        guard !cachedHeadlines.isEmpty else { return nil }
        let body = cachedHeadlines.prefix(3).joined(separator: "\n")
        return QuickNote(title: "News", body: body)
    }

    func refresh(_ ctx: GlanceContext) async {
        if let last = lastFetch, ctx.now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        lastFetch = ctx.now

        let urlStr = "https://news.google.com/rss/headlines/section/topic/\(topic)?hl=en-US&gl=US&ceid=US:en"
        guard let url = URL(string: urlStr) else { return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let pair: (Data, URLResponse)
        do {
            pair = try await URLSession.shared.data(for: req)
        } catch {
            trace("RSS fetch threw: \(error)")
            return
        }
        let (data, response) = pair
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            trace("RSS HTTP \(http.statusCode)")
            return
        }

        let titles = GoogleNewsRSSParser.parseItemTitles(data)
        guard !titles.isEmpty else {
            trace("RSS parsed 0 titles")
            return
        }
        cachedHeadlines = titles.prefix(5).map { cleanTitle($0) }
        trace("RSS → \(cachedHeadlines.count) headlines")
    }

    private func cleanTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dashRange = trimmed.range(of: " - ", options: .backwards) {
            return String(trimmed[..<dashRange.lowerBound])
        }
        return trimmed
    }
}

/// Minimal XMLParserDelegate that collects the text of <title> elements nested inside <item>.
private final class GoogleNewsRSSParser: NSObject, XMLParserDelegate {
    private var titles: [String] = []
    private var inItem = false
    private var inTitle = false
    private var buffer = ""

    static func parseItemTitles(_ data: Data) -> [String] {
        let delegate = GoogleNewsRSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.titles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" { inItem = true }
        if inItem && elementName == "title" {
            inTitle = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inTitle, let s = String(data: CDATABlock, encoding: .utf8) { buffer += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if inItem && elementName == "title" {
            titles.append(buffer)
            inTitle = false
            buffer = ""
        }
        if elementName == "item" { inItem = false }
    }
}
