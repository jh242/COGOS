import Foundation

/// Per-turn user text. Clock lives here (not in system instructions) so the
/// cached instruction+tool prefix stays byte-stable.
enum AgentTurnPrompt {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, d MMM yyyy, h:mm a zzz"
        return formatter
    }()

    static func make(query: String, now: Date = Date()) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Local time: \(clock.string(from: now))\n\n\(trimmed)"
    }
}
