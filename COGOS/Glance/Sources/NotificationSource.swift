import Foundation
import UserNotifications

/// Pulls recent delivered notifications from UNUserNotificationCenter.
/// Eligible when the newest delivered notification is within the last 10
/// minutes; otherwise `currentNote` is nil.
final class NotificationSource: ContextProvider {
    let name = "notifications"
    let priority = 2

    private static let recentWindow: TimeInterval = 10 * 60
    private static let refreshInterval: TimeInterval = 30

    private var lastFetch: Date?
    private var note: QuickNote?

    var currentNote: QuickNote? { note }

    func refresh(_ ctx: GlanceContext) async {
        if let last = lastFetch, ctx.now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        lastFetch = ctx.now

        let delivered = await Self.getDelivered()
        let recent = delivered
            .filter { ctx.now.timeIntervalSince($0.date) <= Self.recentWindow }
            .sorted { $0.date > $1.date }
            .prefix(3)

        guard !recent.isEmpty else {
            trace("no delivered notifications within \(Int(Self.recentWindow))s")
            note = nil
            return
        }

        let rows = recent.map { n -> (app: String, body: String) in
            let c = n.request.content
            let app = c.threadIdentifier.isEmpty ? c.categoryIdentifier : c.threadIdentifier
            return (app: app, body: c.body)
        }

        let title = rows.first?.app.isEmpty == false
            ? rows.first!.app
            : "Notifications"
        let body = rows.map { r in
            r.app.isEmpty ? r.body : "\(r.app): \(r.body)"
        }.joined(separator: "\n")
        note = QuickNote(title: title, body: body)
    }

    private static func getDelivered() async -> [UNNotification] {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getDeliveredNotifications { cont.resume(returning: $0) }
        }
    }
}
