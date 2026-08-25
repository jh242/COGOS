import Foundation
import SwiftMail
import XCTest
@testable import COGOS

final class IMAPSearchQueryTests: XCTestCase {
    func testEmptyAndInboxOnlyMeanRecent() {
        XCTAssertEqual(IMAPSearchQuery.plan(from: ""), .recent)
        XCTAssertEqual(IMAPSearchQuery.plan(from: "  "), .recent)
        XCTAssertEqual(IMAPSearchQuery.plan(from: "in:inbox"), .recent)
    }

    func testFromUnreadAndQuotedSubject() {
        let plan = IMAPSearchQuery.plan(from: #"from:Ada is:unread subject:"lunch plans""#)
        guard case .keys(let keys) = plan else {
            return XCTFail("expected keys")
        }
        XCTAssertEqual(keys, [.from("Ada"), .unseen, .subject("lunch plans")])
    }

    func testPlainTextBecomesTextKey() {
        let plan = IMAPSearchQuery.plan(from: "invoice from last week")
        guard case .keys(let keys) = plan else {
            return XCTFail("expected keys")
        }
        XCTAssertEqual(keys, [.text("invoice from last week")])
    }

    func testNewerThanDays() {
        let now = Date(timeIntervalSince1970: 1_777_046_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let plan = IMAPSearchQuery.plan(from: "newer_than:2d", now: now, calendar: calendar)
        guard case .keys(let keys) = plan, case .since(let date) = keys.first else {
            return XCTFail("expected since key")
        }
        let expected = calendar.date(byAdding: .day, value: -2, to: now)
        XCTAssertEqual(date, expected)
    }

    func testFormattedLineWithoutSnippet() {
        let summary = MailMessageSummary(
            from: "Ada <ada@example.com>",
            subject: "Lunch",
            date: "Aug 25, 2026, 10:00 AM",
            snippet: ""
        )
        XCTAssertEqual(summary.formattedLine, "Ada <ada@example.com> · Aug 25, 2026, 10:00 AM\nLunch")
    }
}

final class IMAPClientSelectionTests: XCTestCase {
    func testNewestTakesHighestUIDs() {
        let set = UIDSet([UID(1), UID(40), UID(7), UID(12)])
        let newest = IMAPClient.newest(set, limit: 2)
        XCTAssertEqual(newest.toArray().sorted(), [UID(12), UID(40)])
    }

    func testNewestIdentifiersPrefersOrderedThenAll() {
        let ordered = ExtendedSearchResult<UID>(ordered: [UID(1), UID(2), UID(3), UID(4)])
        XCTAssertEqual(
            IMAPClient.newestIdentifiers(from: ordered, limit: 2).toArray(),
            [UID(3), UID(4)]
        )

        let all = ExtendedSearchResult<UID>(all: UIDSet([UID(5), UID(50), UID(15)]))
        XCTAssertEqual(
            IMAPClient.newestIdentifiers(from: all, limit: 2).toArray().sorted(),
            [UID(15), UID(50)]
        )
    }
}
