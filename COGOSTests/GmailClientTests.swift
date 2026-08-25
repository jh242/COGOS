import Foundation
import XCTest
@testable import COGOS

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
