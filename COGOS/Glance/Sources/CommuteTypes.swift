import Foundation

/// One leg of a transit trip after parsing.
struct CommuteLeg: Equatable {
    var line: String
    var station: String
}

/// MapKit-independent mirror of `MKRoute.Step` — only the fields we read.
struct RawStep: Equatable {
    enum Kind { case walking, transit, other }
    var kind: Kind
    var instructions: String
}

/// Pure parser over `[RawStep]`. English-only by design — `MKRoute.Step.instructions`
/// is localized; we lock to en-US at the call site (see `CommuteSource`).
enum CommuteParser {
    private static let takeRegex = try! NSRegularExpression(
        pattern: #"Take the (\S+) train"#
    )
    private static let walkRegex = try! NSRegularExpression(
        pattern: #"Walk to (.+?)(?: Station)?$"#
    )

    static func transferCount(in steps: [RawStep]) -> Int {
        let transit = steps.filter { $0.kind == .transit }.count
        return max(0, transit - 1)
    }

    static func legs(from steps: [RawStep]) -> [CommuteLeg] {
        var out: [CommuteLeg] = []
        for (i, step) in steps.enumerated() where step.kind == .transit {
            guard let line = firstCapture(in: step.instructions, regex: takeRegex) else {
                continue
            }
            let station: String
            if i > 0, steps[i - 1].kind == .walking,
               let s = firstCapture(in: steps[i - 1].instructions, regex: walkRegex) {
                station = s
            } else {
                station = "?"
            }
            out.append(CommuteLeg(line: line, station: station))
        }
        return out
    }

    private static func firstCapture(in s: String, regex: NSRegularExpression) -> String? {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: s) else {
            return nil
        }
        return String(s[r])
    }
}

enum CommuteFormatter {
    typealias Row = (label: String, minutes: Int, legs: [CommuteLeg])

    static func row(label: String, minutes: Int, legs: [CommuteLeg]) -> String {
        let path = legs.map { "\($0.line) @ \($0.station)" }.joined(separator: " → ")
        return "\(label) \(minutes)m: \(path)"
    }

    static func body(rows: [Row]) -> String {
        rows
            .sorted { $0.minutes < $1.minutes }
            .map { row(label: $0.label, minutes: $0.minutes, legs: $0.legs) }
            .joined(separator: "\n")
    }
}
