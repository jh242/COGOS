import Foundation
import XCTest
@testable import COGOS

final class GmailClientTests: XCTestCase {
    func testParseMessageIDs() throws {
        let json = Data(#"{"messages":[{"id":"aaa","threadId":"t1"},{"id":"bbb","threadId":"t2"}]}"#.utf8)
        XCTAssertEqual(try GmailClient.parseMessageIDs(from: json), ["aaa", "bbb"])
    }

    func testParseMessageIDsEmptyInbox() throws {
        XCTAssertEqual(try GmailClient.parseMessageIDs(from: Data(#"{}"#.utf8)), [])
    }

    func testParseSummaryReadsHeadersAndSnippet() throws {
        let json = Data("""
        {"snippet":"See you at 3","payload":{"headers":[
          {"name":"From","value":"Ada <ada@example.com>"},
          {"name":"Subject","value":"Lunch"},
          {"name":"Date","value":"Tue, 25 Aug 2026 10:00:00 -0700"}
        ]}}
        """.utf8)
        let summary = try GmailClient.parseSummary(from: json)
        XCTAssertEqual(summary.from, "Ada <ada@example.com>")
        XCTAssertEqual(summary.subject, "Lunch")
        XCTAssertEqual(summary.snippet, "See you at 3")
        XCTAssertTrue(summary.formattedLine.contains("Lunch"))
        XCTAssertTrue(summary.formattedLine.contains("Ada"))
    }
}

final class OpenRouterWebSearchTests: XCTestCase {
    override func tearDown() {
        OpenRouterWebSearchMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSearchWebPostsServerTool() async throws {
        let box = OpenRouterWebSearchRequestBox()
        OpenRouterWebSearchMockURLProtocol.handler = { request in
            box.set(request)
            return OpenRouterWebSearchMockURLProtocol.response(
                for: request,
                status: 200,
                body: #"{"choices":[{"message":{"role":"assistant","content":"Bitcoin is trading around 60k."}}]}"#
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterWebSearchMockURLProtocol.self]
        let client = OpenRouterClient(
            apiKey: "test-key",
            model: OpenRouterClient.defaultAgentModel,
            session: URLSession(configuration: configuration)
        )
        let text = try await client.searchWeb(query: "bitcoin price")
        XCTAssertEqual(text, "Bitcoin is trading around 60k.")

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(box.getBody())) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, OpenRouterClient.defaultAgentModel)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "openrouter:web_search")
        let parameters = try XCTUnwrap(tools.first?["parameters"] as? [String: Any])
        XCTAssertEqual((parameters["max_results"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual((parameters["max_uses"] as? NSNumber)?.intValue, 2)
    }
}

private final class OpenRouterWebSearchMockURLProtocol: URLProtocol {
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

private final class OpenRouterWebSearchRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data?

    func set(_ request: URLRequest) {
        let captured = request.httpBody ?? Self.read(stream: request.httpBodyStream)
        lock.lock()
        body = captured
        lock.unlock()
    }

    func getBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return body
    }

    private static func read(stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
