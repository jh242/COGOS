import Foundation
import XCTest
@testable import COGOS

final class OpenRouterClientTests: XCTestCase {
    override func tearDown() {
        OpenRouterMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testCompletePostsChatCompletionsAndReadsContent() async throws {
        let requestBox = OpenRouterRequestBox()
        OpenRouterMockURLProtocol.handler = { request in
            requestBox.set(request)
            return OpenRouterMockURLProtocol.response(
                for: request,
                status: 200,
                body: """
                {"choices":[{"message":{"role":"assistant","content":"Fed holds rates as inflation eases\\nUkraine talks stall in Istanbul\\nApple unveils new glasses chip"}}]}
                """
            )
        }

        let text = try await makeClient().complete(
            system: NewsHeadlines.systemPrompt,
            user: NewsHeadlines.userPrompt(titles: ["Fed holds rates", "Ukraine talks"])
        )
        XCTAssertEqual(
            text,
            """
            Fed holds rates as inflation eases
            Ukraine talks stall in Istanbul
            Apple unveils new glasses chip
            """
        )

        let request = try XCTUnwrap(requestBox.get())
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), "https://github.com/jh242/COGOS")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "COGOS")

        let bodyData = try XCTUnwrap(requestBox.getBody())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, OpenRouterClient.defaultModel)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["max_tokens"] as? NSNumber)?.intValue, 160)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
    }

    func testMapsAuthenticationFailure() async {
        OpenRouterMockURLProtocol.handler = { request in
            OpenRouterMockURLProtocol.response(
                for: request,
                status: 401,
                body: #"{"error":{"message":"Invalid token"}}"#
            )
        }
        do {
            _ = try await makeClient().complete(system: "s", user: "u")
            XCTFail("Expected authentication failure")
        } catch let error as OpenRouterHTTPError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertTrue(error.localizedDescription.contains("authentication"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsEmptyAssistantContent() async {
        OpenRouterMockURLProtocol.handler = { request in
            OpenRouterMockURLProtocol.response(
                for: request,
                status: 200,
                body: #"{"choices":[{"message":{"role":"assistant","content":"   "}}]}"#
            )
        }
        do {
            _ = try await makeClient().complete(system: "s", user: "u")
            XCTFail("Expected empty response")
        } catch let error as OpenRouterClientError {
            guard case .emptyResponse = error else {
                return XCTFail("Unexpected OpenRouter error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testParseFreeModelsKeepsTextFreePoolAndDropsAudio() throws {
        let json = """
        {"data":[
          {"id":"google/lyria-3-clip-preview","name":"Lyria","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["text","audio"]}},
          {"id":"nvidia/nemotron-3.5-content-safety:free","name":"Safety","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["text"]}},
          {"id":"openai/gpt-4.1-nano","name":"GPT-4.1 Nano","pricing":{"prompt":"0.0000001","completion":"0.0000004"},"architecture":{"output_modalities":["text"]}},
          {"id":"poolside/laguna-xs-2.1:free","name":"Poolside: Laguna XS 2.1 (free)","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["text"]}},
          {"id":"openrouter/free","name":"Free Models Router","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["text"]}},
          {"id":"google/gemma-4-31b-it:free","name":"Google: Gemma 4 31B (free)","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["text"]}}
        ]}
        """.data(using: .utf8)!
        let models = try OpenRouterClient.parseFreeModels(from: json)
        XCTAssertEqual(models.map(\.id), [
            "openrouter/free",
            "poolside/laguna-xs-2.1:free",
            "google/gemma-4-31b-it:free"
        ])
    }

    func testPickerModelsInjectsSelectedSlugWhenMissing() {
        let live = [OpenRouterModelInfo(id: "openrouter/free", name: "Free Models Router")]
        let options = OpenRouterClient.pickerModels(live: live, selected: "acme/custom:free")
        XCTAssertEqual(options.first?.id, "acme/custom:free")
        XCTAssertEqual(options.map(\.id), ["acme/custom:free", "openrouter/free"])
    }

    func testPickerModelsFallsBackWhenLiveListEmpty() {
        let options = OpenRouterClient.pickerModels(live: [], selected: OpenRouterClient.defaultModel)
        XCTAssertTrue(options.contains(where: { $0.id == OpenRouterClient.defaultModel }))
        XCTAssertTrue(options.contains(where: { $0.id == "openrouter/free" }))
    }

    func testListFreeModelsHitsModelsEndpoint() async throws {
        let requestBox = OpenRouterRequestBox()
        OpenRouterMockURLProtocol.handler = { request in
            requestBox.set(request)
            return OpenRouterMockURLProtocol.response(
                for: request,
                status: 200,
                body: #"{"data":[{"id":"poolside/laguna-xs-2.1:free","name":"Laguna XS","pricing":{"prompt":"0","completion":"0"},"architecture":{"output_modalities":["text"]}}]}"#
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterMockURLProtocol.self]
        let models = try await OpenRouterClient.listFreeModels(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://openrouter.ai/api/v1")!
        )
        XCTAssertEqual(models.map(\.id), ["poolside/laguna-xs-2.1:free"])
        XCTAssertEqual(requestBox.get()?.url?.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(requestBox.get()?.httpMethod, "GET")
    }

    private func makeClient() -> OpenRouterClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterMockURLProtocol.self]
        return OpenRouterClient(
            apiKey: "test-key",
            session: URLSession(configuration: configuration)
        )
    }
}

private final class OpenRouterMockURLProtocol: URLProtocol {
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

private final class OpenRouterRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var body: Data?

    func set(_ request: URLRequest) {
        let capturedBody = request.httpBody ?? Self.read(stream: request.httpBodyStream)
        lock.lock()
        self.request = request
        self.body = capturedBody
        lock.unlock()
    }

    func get() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
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
