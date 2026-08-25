import Foundation
import XCTest
@testable import COGOS

@MainActor
final class NewsSourceTests: XCTestCase {
    override func tearDown() {
        NewsHTTPMock.handler = nil
        UserDefaults.standard.removeObject(forKey: "news_topic")
        super.tearDown()
    }

    func testRefreshUsesOpenRouterDigest() async {
        NewsHTTPMock.handler = { request in
            if request.url?.host == "news.google.com" {
                return NewsHTTPMock.response(for: request, status: 200, body: Self.rss)
            }
            return NewsHTTPMock.response(
                for: request,
                status: 200,
                body: """
                {"choices":[{"message":{"content":"- Fed holds rates as inflation eases\\n- Ukraine talks stall in Istanbul\\n- Apple unveils new glasses chip"}}]}
                """
            )
        }

        let session = mockSession()
        let source = NewsSource(
            settings: Settings(),
            session: session,
            locale: Locale(identifier: "en_US"),
            client: OpenRouterClient(apiKey: "test-key", session: session)
        )
        await source.refresh(GlanceContext(now: Date()))
        XCTAssertEqual(
            source.currentNote?.body,
            """
            Fed holds rates as inflation eases
            Ukraine talks stall in Istanbul
            Apple unveils new glasses chip
            """
        )
    }

    func testRefreshFallsBackWhenOpenRouterFails() async {
        NewsHTTPMock.handler = { request in
            if request.url?.host == "news.google.com" {
                return NewsHTTPMock.response(for: request, status: 200, body: Self.rss)
            }
            return NewsHTTPMock.response(for: request, status: 500, body: "{}")
        }

        let session = mockSession()
        let source = NewsSource(
            settings: Settings(),
            session: session,
            locale: Locale(identifier: "en_US"),
            client: OpenRouterClient(apiKey: "test-key", session: session)
        )
        await source.refresh(GlanceContext(now: Date()))
        XCTAssertEqual(
            source.currentNote?.body,
            """
            Fed holds rates steady
            Ukraine talks stall
            Apple unveils glasses chip
            """
        )
    }

    func testKeepsLastDigestWhenRSSFails() async {
        let rssOK = NewsFlag(true)
        NewsHTTPMock.handler = { request in
            if request.url?.host == "news.google.com" {
                if rssOK.value {
                    return NewsHTTPMock.response(for: request, status: 200, body: Self.rss)
                }
                return NewsHTTPMock.response(for: request, status: 500, body: "")
            }
            return NewsHTTPMock.response(
                for: request,
                status: 200,
                body: #"{"choices":[{"message":{"content":"First digest line\nSecond digest line\nThird digest line"}}]}"#
            )
        }

        let session = mockSession()
        let source = NewsSource(
            settings: Settings(),
            session: session,
            locale: Locale(identifier: "en_US"),
            client: OpenRouterClient(apiKey: "test-key", session: session)
        )
        let t0 = Date()
        await source.refresh(GlanceContext(now: t0))
        XCTAssertEqual(source.currentNote?.body, "First digest line\nSecond digest line\nThird digest line")

        rssOK.value = false
        await source.refresh(GlanceContext(now: t0.addingTimeInterval(31 * 60)))
        XCTAssertEqual(source.currentNote?.body, "First digest line\nSecond digest line\nThird digest line")
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewsHTTPMock.self]
        return URLSession(configuration: configuration)
    }

    private static let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Top stories - Google News</title>
        <item><title>Fed holds rates steady - Reuters</title></item>
        <item><title>Ukraine talks stall - BBC</title></item>
        <item><title>Apple unveils glasses chip - Bloomberg</title></item>
      </channel>
    </rss>
    """
}

private final class NewsFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
    init(_ value: Bool) { self.storage = value }
}

private final class NewsHTTPMock: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try Self.handler?(request)
            guard let result else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(for request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }
}
