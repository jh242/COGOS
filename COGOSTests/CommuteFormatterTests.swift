import XCTest
@testable import COGOS

final class CommuteFormatterTests: XCTestCase {
    func testDirect() {
        let row = CommuteFormatter.row(
            label: "Work",
            minutes: 22,
            legs: [CommuteLeg(line: "1", station: "14 St")]
        )
        XCTAssertEqual(row, "Work 22m: 1 @ 14 St")
    }

    func testOneTransfer() {
        let row = CommuteFormatter.row(
            label: "Home",
            minutes: 35,
            legs: [
                CommuteLeg(line: "E", station: "23 St"),
                CommuteLeg(line: "D", station: "W4 St")
            ]
        )
        XCTAssertEqual(row, "Home 35m: E @ 23 St → D @ W4 St")
    }

    func testBodyJoinsAndSortsByMinutes() {
        let body = CommuteFormatter.body(rows: [
            (label: "Home", minutes: 35, legs: [CommuteLeg(line: "E", station: "23 St")]),
            (label: "Work", minutes: 22, legs: [CommuteLeg(line: "1", station: "14 St")]),
            (label: "Gym",  minutes: 15, legs: [CommuteLeg(line: "L", station: "8 Av")])
        ])
        XCTAssertEqual(body, """
        Gym 15m: L @ 8 Av
        Work 22m: 1 @ 14 St
        Home 35m: E @ 23 St
        """)
    }

    func testEmptyBodyIsEmptyString() {
        XCTAssertEqual(CommuteFormatter.body(rows: []), "")
    }
}
