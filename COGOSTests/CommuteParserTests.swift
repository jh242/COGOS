import XCTest
@testable import COGOS

final class CommuteParserTests: XCTestCase {
    func testDirectTrip() {
        let steps = [
            RawStep(kind: .walking, instructions: "Walk to 14 St Station"),
            RawStep(kind: .transit, instructions: "Take the 1 train toward South Ferry"),
            RawStep(kind: .walking, instructions: "Walk to destination")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [CommuteLeg(line: "1", station: "14 St")]
        )
    }

    func testOneTransfer() {
        let steps = [
            RawStep(kind: .walking, instructions: "Walk to 23 St Station"),
            RawStep(kind: .transit, instructions: "Take the E train toward Jamaica Center"),
            RawStep(kind: .walking, instructions: "Walk to W 4 St Station"),
            RawStep(kind: .transit, instructions: "Take the D train toward Coney Island"),
            RawStep(kind: .walking, instructions: "Walk to destination")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [
                CommuteLeg(line: "E", station: "23 St"),
                CommuteLeg(line: "D", station: "W 4 St")
            ]
        )
    }

    func testTransferCount() {
        let zero: [RawStep] = []
        XCTAssertEqual(CommuteParser.transferCount(in: zero), 0)
        let one = [RawStep(kind: .transit, instructions: "Take the 1 train")]
        XCTAssertEqual(CommuteParser.transferCount(in: one), 0)
        let two = [
            RawStep(kind: .transit, instructions: "Take the 1 train"),
            RawStep(kind: .walking, instructions: "Walk to X Station"),
            RawStep(kind: .transit, instructions: "Take the 2 train")
        ]
        XCTAssertEqual(CommuteParser.transferCount(in: two), 1)
        let three = [
            RawStep(kind: .transit, instructions: "Take the 1 train"),
            RawStep(kind: .transit, instructions: "Take the 2 train"),
            RawStep(kind: .transit, instructions: "Take the 3 train")
        ]
        XCTAssertEqual(CommuteParser.transferCount(in: three), 2)
    }

    func testStationSuffixStripped() {
        let steps = [
            RawStep(kind: .walking, instructions: "Walk to Times Sq-42 St Station"),
            RawStep(kind: .transit, instructions: "Take the 7 train toward Flushing")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [CommuteLeg(line: "7", station: "Times Sq-42 St")]
        )
    }

    func testMissingWalkStepFallsBackToUnknown() {
        let steps = [
            RawStep(kind: .transit, instructions: "Take the L train toward Canarsie")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [CommuteLeg(line: "L", station: "?")]
        )
    }

    func testUnparseableTransitStepIsSkipped() {
        let steps = [
            RawStep(kind: .walking, instructions: "Walk to X Station"),
            RawStep(kind: .transit, instructions: "Board the express coach"),
            RawStep(kind: .walking, instructions: "Walk to Y Station"),
            RawStep(kind: .transit, instructions: "Take the 6 train toward Pelham Bay")
        ]
        XCTAssertEqual(
            CommuteParser.legs(from: steps),
            [CommuteLeg(line: "6", station: "Y")]
        )
    }
}
