import Foundation

enum NewsTopic: String, CaseIterable, Identifiable {
    case top
    case world = "WORLD"
    case nation = "NATION"
    case business = "BUSINESS"
    case technology = "TECHNOLOGY"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top: return "Top stories"
        case .world: return "World"
        case .nation: return "National"
        case .business: return "Business"
        case .technology: return "Technology"
        }
    }

    func rssURL(locale: Locale = .current) -> URL {
        let lang = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? "US"
        let query = "hl=\(lang)-\(region)&gl=\(region)&ceid=\(region):\(lang)"
        switch self {
        case .top:
            return URL(string: "https://news.google.com/rss?\(query)")!
        default:
            return URL(string: "https://news.google.com/rss/headlines/section/topic/\(rawValue)?\(query)")!
        }
    }
}

/// RSS parsing, glance clipping, and OpenRouter digest prompting for NewsSource.
enum NewsHeadlines {
    static let maxCharsPerLine = 40
    static let digestLineCount = 3
    static let maxSourceHeadlines = 12

    static let systemPrompt = """
    You write a glanceable news digest for a 40-character-wide smart-glasses display.
    Rules:
    - Output exactly 3 lines.
    - Each line is one distinct story, at most 40 characters.
    - No markdown, bullets, numbering, emoji, quotes, or source names.
    - Plain English, present tense.
    - Prefer the most important stories; skip duplicates and market-ticker noise.
    """

    static func userPrompt(titles: [String]) -> String {
        let bullets = titles.map { "- \($0)" }.joined(separator: "\n")
        return "Headlines:\n\(bullets)"
    }

    static func cleanTitle(_ raw: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutSource: String
        if let dashRange = trimmed.range(of: " - ", options: .backwards) {
            withoutSource = String(trimmed[..<dashRange.lowerBound])
        } else {
            withoutSource = trimmed
        }
        return withoutSource
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clip(_ text: String, maxChars: Int = maxCharsPerLine) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxChars else { return collapsed }
        let prefix = String(collapsed.prefix(maxChars))
        if let space = prefix.lastIndex(of: " "), space > prefix.startIndex {
            return String(prefix[..<space]).trimmingCharacters(in: .whitespaces)
        }
        return prefix
    }

    /// Normalize a model reply (or fallback text) into at most three 40-char lines.
    static func sanitize(_ raw: String, maxLines: Int = digestLineCount) -> String {
        let stripped = stripDecorations(raw)
        var lines = stripped
            .split(whereSeparator: \.isNewline)
            .map { clip(String($0)) }
            .filter { !$0.isEmpty }

        if lines.count == 1 {
            lines = wrap(lines[0], maxChars: maxCharsPerLine, maxLines: maxLines)
        }
        return Array(lines.prefix(maxLines)).joined(separator: "\n")
    }

    static func fallbackBody(titles: [String]) -> String {
        sanitize(titles.prefix(digestLineCount).joined(separator: "\n"))
    }

    static func parseItemTitles(_ data: Data) -> [String] {
        GoogleNewsRSSParser.parseItemTitles(data)
            .map(cleanTitle)
            .filter { !$0.isEmpty }
    }

    private static func stripDecorations(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .split(whereSeparator: \.isNewline)
            .map { line -> String in
                var s = String(line)
                s = s.replacingOccurrences(of: #"^\s*[-*•]\s+"#, with: "", options: .regularExpression)
                s = s.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
                return s.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: "\"“”")))
            }
            .joined(separator: "\n")
    }

    private static func wrap(_ text: String, maxChars: Int, maxLines: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            if lines.count == maxLines { break }
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count <= maxChars {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                current = clip(word, maxChars: maxChars)
            }
        }
        if !current.isEmpty, lines.count < maxLines {
            lines.append(current)
        }
        return lines
    }
}

/// Minimal XMLParserDelegate that collects `<title>` text nested inside `<item>`.
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
