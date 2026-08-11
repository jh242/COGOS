import Foundation
import XCTest
@testable import COGOS

final class HermesClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.onStart = nil
        MockURLProtocol.onStop = nil
        super.tearDown()
    }

    func testStreamsCumulativeTextAndBuildsThinRequest() async throws {
        let requestBox = RequestBox()
        MockURLProtocol.handler = { request in
            requestBox.set(request)
            return Self.response(
                for: request,
                status: 200,
                body: """
                event: response.created
                data: {"type":"response.created","response":{"id":"resp_1"}}

                event: hermes.tool.progress
                data: {"type":"hermes.tool.progress","name":"terminal"}

                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"Hello"}

                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":" world"}

                event: response.completed
                data: {"type":"response.completed","response":{"output":[]}}

                """
            )
        }

        let client = makeClient(baseURL: URL(string: "https://hermes.example/v1/")!)
        var snapshots: [String] = []
        for try await snapshot in client.streamResponse(to: "Hi") {
            snapshots.append(snapshot)
        }

        XCTAssertEqual(snapshots.last, "Hello world")
        let request = try XCTUnwrap(requestBox.get())
        XCTAssertEqual(request.url?.absoluteString, "https://hermes.example/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Key"), "cogos-test")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["input"] as? String, "Hi")
        XCTAssertEqual(body["conversation"] as? String, "conversation-test")
        XCTAssertEqual(body["instructions"] as? String, HermesClient.displayInstructions)
        XCTAssertEqual(body["store"] as? Bool, true)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["model"])
        XCTAssertNil(body["messages"])
        XCTAssertNil(body["tools"])
    }

    func testUsesCompletedResponseAsFallbackWhenNoDeltasArrive() async throws {
        MockURLProtocol.handler = { request in
            Self.response(
                for: request,
                status: 200,
                body: """
                event: response.completed
                data: {"type":"response.completed","response":{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fallback answer"}]}]}}

                """
            )
        }

        var received: [String] = []
        for try await snapshot in makeClient().streamResponse(to: "Hi") {
            received.append(snapshot)
        }
        XCTAssertEqual(received, ["Fallback answer"])
    }

    func testRejectsStreamThatEndsWithoutCompletedEvent() async {
        MockURLProtocol.handler = { request in
            Self.response(
                for: request,
                status: 200,
                body: """
                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"Partial"}

                """
            )
        }

        do {
            for try await _ in makeClient().streamResponse(to: "Hi") {}
            XCTFail("Expected incomplete response failure")
        } catch let error as HermesClientError {
            guard case .incompleteResponse = error else {
                return XCTFail("Unexpected Hermes error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMapsAuthenticationFailure() async {
        MockURLProtocol.handler = { request in
            Self.response(for: request, status: 401, body: "")
        }

        do {
            for try await _ in makeClient().streamResponse(to: "Hi") {}
            XCTFail("Expected authentication failure")
        } catch let error as HermesHTTPError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertTrue(error.localizedDescription.contains("authentication"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConnectionCheckUsesCapabilitiesEndpoint() async throws {
        let requestBox = RequestBox()
        MockURLProtocol.handler = { request in
            requestBox.set(request)
            return Self.response(for: request, status: 200, body: "{}")
        }

        try await makeClient(baseURL: URL(string: "https://hermes.example")!).checkConnection()
        let request = try XCTUnwrap(requestBox.get())
        XCTAssertEqual(request.url?.absoluteString, "https://hermes.example/v1/capabilities")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testCancellingConsumerCancelsURLRequest() async {
        let started = expectation(description: "URL request started")
        let stopped = expectation(description: "URL request cancelled")
        MockURLProtocol.onStart = { started.fulfill() }
        MockURLProtocol.onStop = { stopped.fulfill() }
        MockURLProtocol.handler = { request in
            var response = Self.response(for: request, status: 200, body: "")
            response.finishes = false
            return response
        }

        let consumer = Task {
            let client = self.makeClient()
            do {
                for try await _ in client.streamResponse(to: "Hi") {}
            } catch {}
        }
        await fulfillment(of: [started], timeout: 1)
        consumer.cancel()

        await fulfillment(of: [stopped], timeout: 1)
    }

    func testTextEncoderCapsPayloadAtOneByteChunkCount() {
        let packets = EvenAIText54.textPackets(seq: 1, text: String(repeating: "a", count: 26_000))
        XCTAssertEqual(packets.count, 255)
        XCTAssertTrue(packets.allSatisfy { $0[5] == 255 })
        XCTAssertEqual(packets.last?[7], 255)
    }

    private func makeClient(baseURL: URL = URL(string: "https://hermes.example/v1")!) -> HermesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return HermesClient(
            baseURL: baseURL,
            accessToken: "secret",
            conversationID: "conversation-test",
            sessionKey: "cogos-test",
            session: URLSession(configuration: configuration)
        )
    }

    private static func response(for request: URLRequest, status: Int, body: String) -> MockResponse {
        MockResponse(
            response: HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!,
            data: Data(body.utf8)
        )
    }
}

private struct MockResponse {
    let response: HTTPURLResponse
    let data: Data
    var finishes = true
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> MockResponse)?
    static var onStart: (() -> Void)?
    static var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onStart?()
        do {
            let result = try Self.handler?(request)
            guard let result else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: result.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            if result.finishes {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        Self.onStop?()
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?

    func set(_ request: URLRequest) {
        lock.lock()
        value = request
        lock.unlock()
    }

    func get() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
