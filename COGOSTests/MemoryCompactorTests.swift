import XCTest
@testable import COGOS

private struct MockBackend: LLMBackend {
    let capabilities = LLMCapabilities.openAICompatibleText
    let chunks: [String]
    let onRequest: (@Sendable (LLMRequest) -> Void)?

    init(chunks: [String], onRequest: (@Sendable (LLMRequest) -> Void)? = nil) {
        self.chunks = chunks
        self.onRequest = onRequest
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMBackendEvent, Error> {
        onRequest?(request)
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(.textDelta(chunk)) }
            continuation.yield(.final)
            continuation.finish()
        }
    }
}

final class MemoryCompactorTests: XCTestCase {
    private func memoryWithTurns(_ count: Int, summary: String = "") -> AgentMemory {
        var memory = AgentMemory(rollingSummary: summary)
        for i in 0..<count {
            memory.recentTurns.append(ConversationTurn(userText: "q\(i)", assistantText: "a\(i)"))
        }
        return memory
    }

    func testNeedsCompactionOnlyAboveMaxRecentTurns() {
        let compactor = MemoryCompactor()
        XCTAssertFalse(compactor.needsCompaction(memoryWithTurns(AgentMemory.maxRecentTurns)))
        XCTAssertTrue(compactor.needsCompaction(memoryWithTurns(AgentMemory.maxRecentTurns + 1)))
    }

    func testCompactFoldsOverflowIntoSummaryAndRetainsNewestTurns() async throws {
        let memory = memoryWithTurns(21)
        let backend = MockBackend(chunks: ["User prefers ", "metric units."])

        let compacted = try await MemoryCompactor().compact(memory, using: backend)

        XCTAssertEqual(compacted.rollingSummary, "User prefers metric units.")
        XCTAssertEqual(compacted.recentTurns.count, AgentMemory.retainedTurnsAfterCompaction)
        XCTAssertEqual(compacted.recentTurns.first?.userText, "q11")
        XCTAssertEqual(compacted.recentTurns.last?.userText, "q20")
    }

    func testCompactPromptIncludesPreviousSummaryAndOnlyOverflowTurns() async throws {
        let memory = memoryWithTurns(21, summary: "Old summary text.")
        let captured = CapturedRequest()
        let backend = MockBackend(chunks: ["New summary."]) { captured.set($0) }

        _ = try await MemoryCompactor().compact(memory, using: backend)

        let request = try XCTUnwrap(captured.get())
        XCTAssertNil(request.tools)
        let userContent = try XCTUnwrap(request.messages.last?.content)
        XCTAssertTrue(userContent.contains("Old summary text."))
        XCTAssertTrue(userContent.contains("q0"))
        XCTAssertTrue(userContent.contains("q10"))
        XCTAssertFalse(userContent.contains("q11"))
    }

    func testCompactThrowsOnEmptySummary() async {
        let memory = memoryWithTurns(21)
        let backend = MockBackend(chunks: ["   \n"])

        do {
            _ = try await MemoryCompactor().compact(memory, using: backend)
            XCTFail("expected emptySummary error")
        } catch {
            XCTAssertTrue(error is MemoryCompactionError)
        }
    }

    func testCompactBelowRetainedWindowIsNoOp() async throws {
        let memory = memoryWithTurns(AgentMemory.retainedTurnsAfterCompaction)
        let backend = MockBackend(chunks: ["should not be used"])

        let result = try await MemoryCompactor().compact(memory, using: backend)

        XCTAssertEqual(result.rollingSummary, "")
        XCTAssertEqual(result.recentTurns.count, AgentMemory.retainedTurnsAfterCompaction)
    }

    func testAddTurnEnforcesHardCap() {
        var memory = AgentMemory()
        for i in 0..<(AgentMemory.hardTurnCap + 10) {
            memory.addTurn(userText: "q\(i)", assistantText: "a\(i)")
        }
        XCTAssertEqual(memory.recentTurns.count, AgentMemory.hardTurnCap)
        XCTAssertEqual(memory.recentTurns.last?.userText, "q\(AgentMemory.hardTurnCap + 9)")
    }
}

final class LLMHTTPErrorTests: XCTestCase {
    func testUnsupportedRequestShapeStatuses() {
        XCTAssertTrue(LLMHTTPError(statusCode: 400, bodySnippet: "").suggestsUnsupportedRequestShape)
        XCTAssertTrue(LLMHTTPError(statusCode: 404, bodySnippet: "").suggestsUnsupportedRequestShape)
        XCTAssertTrue(LLMHTTPError(statusCode: 422, bodySnippet: "").suggestsUnsupportedRequestShape)
    }

    func testAuthBillingAndRateLimitAreNotRetried() {
        for status in [401, 402, 403, 407, 408, 429] {
            XCTAssertFalse(
                LLMHTTPError(statusCode: status, bodySnippet: "").suggestsUnsupportedRequestShape,
                "status \(status) should not trigger a tools-off retry"
            )
        }
    }

    func testServerErrorsAreNotRetried() {
        XCTAssertFalse(LLMHTTPError(statusCode: 500, bodySnippet: "").suggestsUnsupportedRequestShape)
        XCTAssertFalse(LLMHTTPError(statusCode: 503, bodySnippet: "").suggestsUnsupportedRequestShape)
    }
}

/// Thread-safe capture box so the @Sendable onRequest closure can hand the
/// request back to the test.
private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var request: LLMRequest?

    func set(_ value: LLMRequest) {
        lock.lock(); defer { lock.unlock() }
        request = value
    }

    func get() -> LLMRequest? {
        lock.lock(); defer { lock.unlock() }
        return request
    }
}
