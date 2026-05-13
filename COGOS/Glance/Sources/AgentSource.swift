import Foundation

/// Assistant-owned glance provider. The tool layer writes notes here; the
/// normal GlanceService provider ordering decides which Quick Notes slot shows
/// it. No BLE or slot override logic lives in the agent runtime.
final class AgentSource: ContextProvider, @unchecked Sendable {
    let name = "agent"
    let priority = 1

    private static let ttl: TimeInterval = 10 * 60
    private var latest: Entry?

    var currentNote: QuickNote? {
        guard let latest else { return nil }
        guard Date().timeIntervalSince(latest.writtenAt) <= Self.ttl else { return nil }
        return QuickNote(title: latest.title, body: latest.body)
    }

    func refresh(_ ctx: GlanceContext) async {
        // No I/O. Expiration is checked lazily in currentNote on each tick.
    }

    @MainActor
    func setNote(title: String, body: String) {
        latest = Entry(
            title: Self.truncatedString(title, maxBytes: 0xFF),
            body: Self.truncatedString(body, maxBytes: Int(UInt16.max)),
            writtenAt: Date()
        )
    }

    @MainActor
    func clear() {
        latest = nil
    }

    private static func truncatedString(_ value: String, maxBytes: Int) -> String {
        let data = value.utf8Truncated(max: maxBytes)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private struct Entry: Sendable {
        let title: String
        let body: String
        let writtenAt: Date
    }
}
