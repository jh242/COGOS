import XCTest
@testable import COGOS

final class NewsHeadlinesTests: XCTestCase {
    func testCleanTitleStripsSourceSuffix() {
        XCTAssertEqual(
            NewsHeadlines.cleanTitle("Fed holds rates steady - The Wall Street Journal"),
            "Fed holds rates steady"
        )
    }

    func testCleanTitleCollapsesWhitespace() {
        XCTAssertEqual(
            NewsHeadlines.cleanTitle("  Ukraine  talks   stall  "),
            "Ukraine talks stall"
        )
    }

    func testClipBreaksOnWordBoundary() {
        let title = "Federal Reserve holds interest rates steady as inflation cools"
        let clipped = NewsHeadlines.clip(title, maxChars: 40)
        XCTAssertLessThanOrEqual(clipped.count, 40)
        XCTAssertFalse(clipped.hasSuffix(" "))
        XCTAssertEqual(clipped, "Federal Reserve holds interest rates")
    }

    func testSanitizeStripsBulletsAndCapsAtThreeLines() {
        let raw = """
        - Fed holds rates as inflation eases
        - Ukraine talks stall in Istanbul
        3. Apple unveils new glasses chip
        • Extra fourth line that should drop
        """
        XCTAssertEqual(
            NewsHeadlines.sanitize(raw),
            """
            Fed holds rates as inflation eases
            Ukraine talks stall in Istanbul
            Apple unveils new glasses chip
            """
        )
    }

    func testSanitizeWrapsSingleParagraph() {
        let raw = "Fed holds rates as inflation eases while Ukraine talks stall in Istanbul"
        let lines = NewsHeadlines.sanitize(raw).split(separator: "\n")
        XCTAssertLessThanOrEqual(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 40 })
        XCTAssertFalse(lines.isEmpty)
    }

    func testFallbackBodyTakesThreeClippedHeadlines() {
        let body = NewsHeadlines.fallbackBody(titles: [
            "Fed holds rates steady",
            "Ukraine talks stall in Istanbul",
            "Apple unveils new glasses chip",
            "Ignored fourth"
        ])
        XCTAssertEqual(
            body,
            """
            Fed holds rates steady
            Ukraine talks stall in Istanbul
            Apple unveils new glasses chip
            """
        )
    }

    func testParseItemTitlesIgnoresChannelTitle() {
        let rss = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Top stories - Google News</title>
            <item>
              <title>Fed holds rates steady - Reuters</title>
            </item>
            <item>
              <title><![CDATA[Ukraine talks stall - BBC]]></title>
            </item>
          </channel>
        </rss>
        """.data(using: .utf8)!
        XCTAssertEqual(
            NewsHeadlines.parseItemTitles(rss),
            ["Fed holds rates steady", "Ukraine talks stall"]
        )
    }

    func testUserPromptListsHeadlines() {
        let prompt = NewsHeadlines.userPrompt(titles: ["Alpha", "Beta"])
        XCTAssertEqual(prompt, "Headlines:\n- Alpha\n- Beta")
    }

    func testTopStoriesRSSURLUsesLocale() {
        let url = NewsTopic.top.rssURL(locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(url.host, "news.google.com")
        XCTAssertEqual(url.path, "/rss")
        XCTAssertTrue(url.absoluteString.contains("gl=GB"))
        XCTAssertTrue(url.absoluteString.contains("hl=en-GB"))
    }

    func testTopicRSSURLIncludesSection() {
        let url = NewsTopic.world.rssURL(locale: Locale(identifier: "en_US"))
        XCTAssertTrue(url.path.contains("/topic/WORLD"))
    }
}
