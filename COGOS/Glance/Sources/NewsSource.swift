import CoreGraphics
import CoreText
import Foundation

final class NewsSource: GlanceSource {
    let name = "news"
    var enabled = true
    var cacheDuration: TimeInterval = 1800
    var tier: GlanceTier = .fallback

    var topic: String = "BUSINESS"

    private var cachedHeadlines: [String] = []

    func fetch(context: GlanceContext) async -> String? {
        let urlStr = "https://news.google.com/rss/headlines/section/topic/\(topic)?hl=en-US&gl=US&ceid=US:en"
        guard let url = URL(string: urlStr) else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }

        let titles = GoogleNewsRSSParser.parseItemTitles(data)
        guard !titles.isEmpty else {
            cachedHeadlines = []
            return nil
        }

        cachedHeadlines = titles.prefix(5).map { cleanTitle($0) }
        let headlines = cachedHeadlines.prefix(3).map { "- \($0)" }
        return "News:\n\(headlines.joined(separator: "\n"))"
    }

    func drawContent(in rect: CGRect, context: CGContext) -> Bool {
        guard !cachedHeadlines.isEmpty else { return false }
        let font = CTFontCreateWithName("SFProDisplay-Regular" as CFString, 19, nil)

        var y = rect.maxY - 8
        for headline in cachedHeadlines {
            let truncated = GlanceDrawing.truncateToFit(headline, font: font, maxWidth: rect.width)
            y = GlanceDrawing.drawText(
                truncated, at: CGPoint(x: rect.minX, y: y),
                font: font, in: context
            )
            y -= 8
            if y < rect.minY + 10 { break }
        }
        return true
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
