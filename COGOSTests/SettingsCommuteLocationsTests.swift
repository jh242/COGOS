import XCTest
@testable import COGOS

@MainActor
final class SettingsCommuteLocationsTests: XCTestCase {
    private let key = "commute_locations"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: "news_topic")
        UserDefaults.standard.removeObject(forKey: "openrouter_model")
        UserDefaults.standard.removeObject(forKey: "openrouter_agent_model")
        UserDefaults.standard.removeObject(forKey: "spoken_backend")
    }

    func testNewsTopicDefaultsToTopStories() {
        let s = Settings()
        XCTAssertEqual(s.newsTopic, .top)
    }

    func testNewsTopicRoundTripsThroughUserDefaults() {
        let s1 = Settings()
        s1.newsTopic = .technology
        let s2 = Settings()
        XCTAssertEqual(s2.newsTopic, .technology)
    }

    func testOpenRouterModelDefaults() {
        let s = Settings()
        XCTAssertEqual(s.openRouterModel, OpenRouterClient.defaultModel)
        XCTAssertEqual(s.openRouterAgentModel, OpenRouterClient.defaultAgentModel)
        XCTAssertEqual(s.spokenBackend, .hermes)
        XCTAssertEqual(s.gmailAccessToken, "")
    }

    func testSpokenBackendAndAgentModelRoundTrip() {
        let s1 = Settings()
        s1.spokenBackend = .openRouter
        s1.openRouterAgentModel = "openai/gpt-4o-mini"
        let s2 = Settings()
        XCTAssertEqual(s2.spokenBackend, .openRouter)
        XCTAssertEqual(s2.openRouterAgentModel, "openai/gpt-4o-mini")
    }

    func testDefaultIsEmpty() {
        let s = Settings()
        XCTAssertEqual(s.commuteLocations, [])
    }

    func testRoundTripsThroughUserDefaults() {
        let s1 = Settings()
        s1.commuteLocations = [
            CommuteLocation(label: "Home", latitude: 40.7, longitude: -74.0),
            CommuteLocation(label: "Work", latitude: 40.75, longitude: -73.99)
        ]
        let s2 = Settings()
        XCTAssertEqual(s2.commuteLocations.map(\.label), ["Home", "Work"])
    }

    func testDecodesLegacyEntriesWithoutID() {
        let legacy = Data(#"[{"label":"Home","latitude":40.7,"longitude":-74.0}]"#.utf8)
        UserDefaults.standard.set(legacy, forKey: key)
        let s = Settings()
        XCTAssertEqual(s.commuteLocations.map(\.label), ["Home"])
    }

    func testSetterTruncatesPastFive() {
        let s = Settings()
        s.commuteLocations = (0..<8).map {
            CommuteLocation(label: "L\($0)", latitude: 0, longitude: 0)
        }
        XCTAssertEqual(s.commuteLocations.count, 5)
        XCTAssertEqual(s.commuteLocations.map(\.label), ["L0", "L1", "L2", "L3", "L4"])
    }
}
