import Foundation
import UserNotifications

/// Pulls recent delivered notifications from UNUserNotificationCenter.
/// Direct replacement for the Flutter NotificationChannel buffer.
struct NotificationSource: GlanceSource {
    let name = "notifications"
    var enabled = true
    var cacheDuration: TimeInterval = 0 // always fresh

    /// Surface notifications only if something arrived in the last 10 min.
    private static let recentWindow: TimeInterval = 10 * 60

    func relevance(_ ctx: GlanceContext) async -> Int? {
        let delivered = await Self.getDelivered()
        guard let newest = delivered.map({ $0.date }).max() else { return nil }
        return ctx.now.timeIntervalSince(newest) <= Self.recentWindow ? 2 : nil
    }

    func fetch(context: GlanceContext) async -> String? {
        let delivered = await Self.getDelivered()
        let sorted = delivered.sorted { $0.date > $1.date }.prefix(3)
        if sorted.isEmpty { return nil }
        let snippets = sorted.map { n -> String in
            let c = n.request.content
            let app = c.threadIdentifier.isEmpty ? c.categoryIdentifier : c.threadIdentifier
            let body = c.body
            return app.isEmpty ? "- \(body)" : "- \(app): \(body)"
        }
        return "Notifications:\n\(snippets.joined(separator: "\n"))"
    }

    private static func getDelivered() async -> [UNNotification] {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getDeliveredNotifications { cont.resume(returning: $0) }
        }
    }
}
