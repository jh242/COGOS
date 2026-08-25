import Foundation
import XCTest
@testable import COGOS

final class OpenRouterResponsesSanitizerTests: XCTestCase {
    func testStripsStoreAndPreviousResponseIdAndKeepsSortedKeys() throws {
        let original = """
        {"store":false,"model":"google/gemini-2.5-flash","previous_response_id":null,"input":"hi","tools":[]}
        """.data(using: .utf8)!
        let sanitized = OpenRouterResponsesSanitizer.sanitize(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        XCTAssertNil(object["store"])
        XCTAssertNil(object["previous_response_id"])
        XCTAssertEqual(object["model"] as? String, "google/gemini-2.5-flash")
        XCTAssertEqual(object["input"] as? String, "hi")
        let keys = Set(object.keys.map { String(describing: $0) })
        XCTAssertEqual(keys, ["input", "model", "tools"])
    }

    func testLeavesNonJSONUnchanged() {
        let raw = Data("not-json".utf8)
        XCTAssertEqual(OpenRouterResponsesSanitizer.sanitize(raw), raw)
    }
}

final class AgentTranscriptTrimmerTests: XCTestCase {
    func testKeepFromIndexZeroWhenUnderBudget() {
        XCTAssertEqual(AgentTranscriptTrimmer.keepFromIndex(promptIndices: [0, 3, 8], maxPromptTurns: 12), 0)
        XCTAssertEqual(AgentTranscriptTrimmer.keepFromIndex(promptIndices: [], maxPromptTurns: 12), 0)
    }

    func testKeepFromIndexDropsOldestPromptsFromTheFront() {
        let indices = [0, 2, 5, 9, 12, 18]
        XCTAssertEqual(AgentTranscriptTrimmer.keepFromIndex(promptIndices: indices, maxPromptTurns: 3), 9)
    }
}

final class AgentTurnPromptTests: XCTestCase {
    func testPutsClockOnTheUserTurnNotAsBareQuery() {
        let now = Date(timeIntervalSince1970: 1_777_046_400) // 2026-05-25 00:00 UTC-ish
        let prompt = AgentTurnPrompt.make(query: "  What's next?  ", now: now)
        XCTAssertTrue(prompt.hasPrefix("Local time:"))
        XCTAssertTrue(prompt.contains("What's next?"))
        XCTAssertFalse(prompt.hasPrefix("What's next?"))
    }
}
