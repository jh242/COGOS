import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Fallback provider — shows cached headlines when nothing higher-priority
/// is eligible. Headlines are individually summarized with Apple's on-device
/// Foundation model (5 words max), and entries blocked by content protections
/// are skipped so the remaining summaries can still be displayed.
final class NewsSource: ContextProvider {
    let name = "news"

    private static let refreshInterval: TimeInterval = 30 * 60
    private static let separator = " · "
    private static let maxHeadlines = 4
    private static let wordsPerHeadline = 5

    var topic: String = "BUSINESS"

    private var lastFetch: Date?
    private var displayBody: String = ""
    private let summarizer = HeadlineSummarizer()

    var currentNote: QuickNote? {
        guard !displayBody.isEmpty else { return nil }
        return QuickNote(title: "News", body: displayBody)
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

        var shortened: [String] = []
        for title in titles.prefix(Self.maxHeadlines) {
            let clean = cleanTitle(title)
            guard !clean.isEmpty else { continue }

            if let summary = await summarizer.summarize(clean, maxWords: Self.wordsPerHeadline), !summary.isEmpty {
                shortened.append(summary)
            } else {
                trace("Skipped headline due to model/content protection: \(clean)")
            }
        }

        displayBody = shortened.joined(separator: Self.separator)
        trace("RSS → \(shortened.count) headlines → \"\(displayBody)\"")
    }

    private func cleanTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dashRange = trimmed.range(of: " - ", options: .backwards) {
            return String(trimmed[..<dashRange.lowerBound])
        }
        return trimmed
    }

    private func trace(_ msg: String) { print("[news] \(msg)") }
}

private actor HeadlineSummarizer {
    func summarize(_ headline: String, maxWords: Int) async -> String? {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let session = LanguageModelSession()
                let prompt = """
                Summarize this news headline in \(maxWords) words or fewer.
                Output only the summary phrase with no punctuation at the end.

                Headline: \(headline)
                """
                let response = try await session.respond(to: prompt)
                return trimToWordLimit(response.content, maxWords: maxWords)
            } catch {
                return nil
            }
        }
#endif
        return trimToWordLimit(headline, maxWords: maxWords)
    }

    private func trimToWordLimit(_ text: String, maxWords: Int) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .prefix(maxWords)
            .joined(separator: " ")
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
