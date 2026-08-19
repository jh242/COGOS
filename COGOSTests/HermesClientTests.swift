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

        let bodyData = try XCTUnwrap(requestBox.getBody())
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
            switch request.url?.path {
            case "/v1/health":
                return Self.response(for: request, status: 200, body: #"{"status":"ok","version":"0.19.1"}"#)
            case "/v1/capabilities":
                return Self.response(
                    for: request,
                    status: 200,
                    body: #"{"object":"hermes.api_server.capabilities","features":{"responses_api":true}}"#
                )
            case "/v1/responses":
                return Self.streamingProbeResponse(for: request)
            default:
                return Self.response(for: request, status: 404, body: "")
            }
        }

        let report = try await makeClient(baseURL: URL(string: "https://hermes.example")!).checkConnection()
        XCTAssertEqual(report.version, "0.19.1")
        XCTAssertEqual(report.streaming, .verified)
        XCTAssertEqual(report.statusText, "Connected — streaming verified (Hermes 0.19.1)")

        let requests = requestBox.getAll()
        let capabilities = try XCTUnwrap(requests.first { $0.url?.path == "/v1/capabilities" })
        XCTAssertEqual(capabilities.httpMethod, "GET")
        XCTAssertEqual(capabilities.value(forHTTPHeaderField: "Accept"), "application/json")

        let probe = try XCTUnwrap(requests.first { $0.url?.path == "/v1/responses" })
        XCTAssertEqual(probe.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let bodyData = try XCTUnwrap(requestBox.body(forPath: "/v1/responses"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertTrue((body["conversation"] as? String)?.hasPrefix("cogos-stream-probe-") == true)
    }

    func testConnectionCheckReportsBufferedResponse() async throws {
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/health":
                return Self.response(for: request, status: 200, body: #"{"version":"0.19.1"}"#)
            case "/v1/capabilities":
                return Self.response(
                    for: request,
                    status: 200,
                    body: #"{"features":{"responses_api":true}}"#
                )
            default:
                return Self.response(
                    for: request,
                    status: 200,
                    body: """
                    event: response.output_text.delta
                    data: {"type":"response.output_text.delta","delta":"1 "}

                    event: response.output_text.delta
                    data: {"type":"response.output_text.delta","delta":"2"}

                    event: response.completed
                    data: {"type":"response.completed","response":{"output":[]}}

                    """
                )
            }
        }

        let report = try await makeClient().checkConnection()
        XCTAssertEqual(report.streaming, .buffered)
        XCTAssertTrue(report.statusText.contains("appear buffered"))
    }

    func testConnectionCheckRejectsNonHermesSuccessResponse() async {
        MockURLProtocol.handler = { request in
            Self.response(for: request, status: 200, body: #"{"status":"ok"}"#)
        }

        do {
            _ = try await makeClient().checkConnection()
            XCTFail("Expected incompatible server failure")
        } catch let error as HermesClientError {
            guard case .incompatibleServer = error else {
                return XCTFail("Unexpected Hermes error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSurfacesHermesErrorMessageFromResponseBody() async {
        MockURLProtocol.handler = { request in
            Self.response(
                for: request,
                status: 400,
                body: #"{"error":{"message":"Missing 'input' field","type":"invalid_request_error"}}"#
            )
        }

        do {
            for try await _ in makeClient().streamResponse(to: "Hi") {}
            XCTFail("Expected request failure")
        } catch let error as HermesHTTPError {
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertEqual(error.localizedDescription, "Missing 'input' field")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

    func testTextEncoderUsesTypedModesAndClosePacket() {
        XCTAssertEqual(
            EvenAIText54.preparePacket(seq: 0x10),
            Data([0x54, 0x0C, 0x00, 0x10, 0x02, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        )
        XCTAssertEqual(
            EvenAIText54.closePacket(seq: 0x11),
            Data([0x54, 0x06, 0x00, 0x11, 0x01, 0x00])
        )

        let streaming = EvenAIText54.textPackets(seq: 1, text: "a", mode: .streaming)[0]
        XCTAssertEqual(streaming[9], 0)
        XCTAssertEqual(streaming[11], 0xFF)

        let passive = EvenAIText54.textPackets(seq: 2, text: "a", mode: .passiveScroll)[0]
        XCTAssertEqual(passive[9], 0)
        XCTAssertEqual(passive[11], 100)

        let interactive = EvenAIText54.textPackets(seq: 3, text: "a", mode: .interactive(position: 45))[0]
        XCTAssertEqual(interactive[9], 1)
        XCTAssertEqual(interactive[11], 45)
    }

    func testMultiChunkTextUpdateSharesSequence() {
        let packets = EvenAIText54.textPackets(seq: 0xFE, text: String(repeating: "a", count: 201))
        XCTAssertEqual(packets.count, 3)
        XCTAssertTrue(packets.allSatisfy { $0[3] == 0xFE })
        XCTAssertEqual(packets.map { $0[7] }, [1, 2, 3])
    }

    func testTextSequenceRollsOverAfterEveryLogicalUpdate() {
        var sequence = EvenAITextSequence(startingAt: 0xFE)
        XCTAssertEqual(sequence.next(), 0xFE)
        XCTAssertEqual(sequence.next(), 0xFF)
        XCTAssertEqual(sequence.next(), 0x00)
        XCTAssertEqual(sequence.next(), 0x01)
    }

    func testCompletedRequestTimeoutCannotCancelNewerRequestWithSameCommand() async throws {
        let queue = BleRequestQueue(bluetooth: BluetoothManager())
        let command = Data([0x54])

        let first = Task {
            await queue.request(command, lr: "L", timeoutMs: 100)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        queue.deliver(packet: BluetoothManager.ReceivedPacket(
            lr: "L",
            data: Data([0x54, 0xC9]),
            peripheralId: "test"
        ))
        let firstResponse = await first.value
        XCTAssertNotNil(firstResponse)

        let second = Task {
            await queue.request(command, lr: "L", timeoutMs: 500)
        }
        // The first request's timeout fires while the second request is
        // pending. It must not remove the second request's continuation.
        try await Task.sleep(nanoseconds: 150_000_000)
        queue.deliver(packet: BluetoothManager.ReceivedPacket(
            lr: "L",
            data: Data([0x54, 0xC9]),
            peripheralId: "test"
        ))
        let secondResponse = await second.value
        XCTAssertNotNil(secondResponse)
    }

    func testFiveLineLayoutKeepsNonOverlappingPages() {
        let fiveLines = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let streaming = EvenTextLayout.frame(for: fiveLines)
        XCTAssertEqual(streaming.mode, .streaming)
        XCTAssertTrue(streaming.text.hasPrefix("\n\nline 1"))

        let sixLines = fiveLines + "\nline 6"
        let firstPage = EvenTextLayout.frame(for: sixLines, pageIndex: 0)
        let secondPage = EvenTextLayout.frame(for: sixLines, pageIndex: 1)
        XCTAssertEqual(firstPage.mode, .passiveScroll)
        XCTAssertTrue(firstPage.text.contains("line 1"))
        XCTAssertFalse(firstPage.text.contains("line 6"))
        XCTAssertTrue(secondPage.text.hasPrefix("line 6"))
        XCTAssertFalse(secondPage.text.contains("line 1"))
    }

    func testLayoutWrapsAt40CharactersAndPreservesParagraphs() {
        let longWord = String(repeating: "a", count: 41)
        let lines = EvenTextLayout.wrappedLines("\(longWord)\n\nlast")
        XCTAssertEqual(lines.map(\.count), [40, 1, 0, 4])
    }

    func testInteractivePagesUseFiveLinesAndNormalizedUTF8Positions() {
        let text = Array(repeating: "aaaa", count: 15).joined(separator: "\n")
        let pages = EvenTextLayout.pages(for: text)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.map(\.position), [0, 45, 90])
        XCTAssertTrue(pages[0].text.hasPrefix("\n\naaaa"))
        XCTAssertEqual(pages[1].text, Array(repeating: "aaaa", count: 5).joined(separator: "\n") + "\n")
        XCTAssertEqual(pages[2].text, pages[1].text)
    }

    func testCompletedFinalPageIsRemainderNotSlidingTail() {
        let text = (1...7).map { "line \($0)" }.joined(separator: "\n")
        let pages = EvenTextLayout.pages(for: text)

        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(pages[0].text.contains("line 1"))
        XCTAssertTrue(pages[0].text.contains("line 5"))
        XCTAssertFalse(pages[0].text.contains("line 6"))
        XCTAssertEqual(pages[1].text, "line 6\nline 7\n")
    }

    func testInteractivePositionsUseUTF8ByteOffsets() {
        let text = Array(repeating: "é", count: 5)
            + Array(repeating: "a", count: 5)
            + Array(repeating: "z", count: 5)
        let pages = EvenTextLayout.pages(for: text.joined(separator: "\n"))

        XCTAssertEqual(pages.map(\.position), [0, 54, 90])
    }

    func testInteractivePagesCoverEveryWrappedLineWithoutOverlap() {
        let text = (1...23).map { "Answer line \($0)." }.joined(separator: "\n")
        let lines = EvenTextLayout.wrappedLines(text)
        let pages = EvenTextLayout.pages(for: text)
        XCTAssertGreaterThan(lines.count, EvenTextLayout.linesPerPage)

        var covered: [Int] = []
        for page in pages {
            covered.append(contentsOf: page.lines.indices)
        }
        XCTAssertEqual(covered, Array(0..<lines.count))
        XCTAssertEqual(Set(covered).count, lines.count)
    }

    func testTextPacketsDoNotSplitUTF8CodePoints() {
        let prefix = String(repeating: "a", count: 99)
        let packets = EvenAIText54.textPackets(seq: 1, text: prefix + "éé")
        XCTAssertGreaterThanOrEqual(packets.count, 2)
        let payloads = packets.map { $0.dropFirst(12) }
        for payload in payloads {
            XCTAssertNotNil(String(data: Data(payload), encoding: .utf8))
        }
        XCTAssertEqual(
            String(data: Data(payloads.joined()), encoding: .utf8),
            prefix + "éé"
        )
    }

    func testInteractivePositionsIncreaseMonotonically() {
        let text = (1...30).map { "Segment \($0) has enough text to wrap cleanly." }.joined(separator: "\n")
        let positions = EvenTextLayout.pages(for: text).map(\.position)
        for index in 1..<positions.count {
            XCTAssertGreaterThan(positions[index], positions[index - 1])
        }
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

    private static func streamingProbeResponse(for request: URLRequest) -> MockResponse {
        MockResponse(
            response: HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!,
            data: Data(),
            chunks: [
                MockChunk(
                    delay: 0,
                    data: Data("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"1 \"}\n\n".utf8)
                ),
                MockChunk(
                    delay: 0.05,
                    data: Data("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"2 \"}\n\n".utf8)
                ),
                MockChunk(
                    delay: 0.20,
                    data: Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n".utf8)
                )
            ]
        )
    }
}

private struct MockChunk {
    let delay: TimeInterval
    let data: Data
}

private struct MockResponse {
    let response: HTTPURLResponse
    let data: Data
    var chunks: [MockChunk] = []
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
            if result.chunks.isEmpty {
                client?.urlProtocol(self, didLoad: result.data)
            } else {
                for chunk in result.chunks {
                    if chunk.delay > 0 { Thread.sleep(forTimeInterval: chunk.delay) }
                    client?.urlProtocol(self, didLoad: chunk.data)
                }
            }
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
    private var values: [URLRequest] = []
    private var bodiesByPath: [String: Data] = [:]

    func set(_ request: URLRequest) {
        let capturedBody = request.httpBody ?? Self.read(stream: request.httpBodyStream)
        lock.lock()
        values.append(request)
        if let capturedBody, let path = request.url?.path {
            bodiesByPath[path] = capturedBody
        }
        lock.unlock()
    }

    func get() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    func getBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let path = values.last?.url?.path else { return nil }
        return bodiesByPath[path]
    }

    func getAll() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func body(forPath path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return bodiesByPath[path]
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
