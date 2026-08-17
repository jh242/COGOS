import Foundation
import XCTest
@testable import COGOS

final class Smoke: XCTestCase {
    func testTrue() { XCTAssertTrue(true) }
}

final class NotificationProtocolTests: XCTestCase {
    func testDefaultWhitelistKeepsFirmwareInboxEnabledWithEmptyAppList() throws {
        let model = NotifyWhitelistModel(apps: [])
        let data = try XCTUnwrap(model.jsonString().data(using: .utf8))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["calendar_enable"] as? Bool, true)
        XCTAssertEqual(json["call_enable"] as? Bool, true)
        XCTAssertEqual(json["msg_enable"] as? Bool, true)
        XCTAssertEqual(json["ios_mail_enable"] as? Bool, true)
        let app = try XCTUnwrap(json["app"] as? [String: Any])
        XCTAssertEqual(app["enable"] as? Bool, true)
        XCTAssertEqual((app["list"] as? [[String: String]])?.count, 0)
    }

    func testThirdPartyAllowlistIsEnabledWhenItContainsAnApp() throws {
        let model = NotifyWhitelistModel(
            apps: [NotifyAppModel(id: "com.example.chat", name: "Example Chat")]
        )
        let app = try XCTUnwrap(model.wireDict["app"] as? [String: Any])
        let list = try XCTUnwrap(app["list"] as? [[String: String]])

        XCTAssertEqual(app["enable"] as? Bool, true)
        XCTAssertEqual(list, [["id": "com.example.chat", "name": "Example Chat"]])
    }

    func testNotificationAutoDisplayPacketClampsTimeout() {
        XCTAssertEqual(
            Proto.notificationAutoDisplayPacket(enabled: true, timeoutSeconds: 8),
            Data([0x4F, 0x01, 0x08])
        )
        XCTAssertEqual(
            Proto.notificationAutoDisplayPacket(enabled: false, timeoutSeconds: 999),
            Data([0x4F, 0x00, 0xFF])
        )
    }
}
