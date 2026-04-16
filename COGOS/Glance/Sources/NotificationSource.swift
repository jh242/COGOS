import CoreGraphics
import CoreText
import Foundation
import UserNotifications

/// Pulls recent delivered notifications from UNUserNotificationCenter.
final class NotificationSource: GlanceSource {
    let name = "notifications"
    var enabled = true
    var cacheDuration: TimeInterval = 0 // always fresh

    private static let recentWindow: TimeInterval = 10 * 60
    private var cachedNotifications: [(app: String, body: String)] = []

    func relevance(_ ctx: GlanceContext) async -> Int? {
        let delivered = await Self.getDelivered()
        guard let newest = delivered.map({ $0.date }).max() else { return nil }
        return ctx.now.timeIntervalSince(newest) <= Self.recentWindow ? 2 : nil
    }

    func fetch(context: GlanceContext) async -> String? {
        let delivered = await Self.getDelivered()
        let sorted = delivered.sorted { $0.date > $1.date }.prefix(5)
        if sorted.isEmpty {
            cachedNotifications = []
            return nil
        }
        cachedNotifications = sorted.map { n in
            let c = n.request.content
            let app = c.threadIdentifier.isEmpty ? c.categoryIdentifier : c.threadIdentifier
            return (app: app, body: c.body)
        }
        let snippets = cachedNotifications.prefix(3).map { n in
            n.app.isEmpty ? "- \(n.body)" : "- \(n.app): \(n.body)"
        }
        return "Notifications:\n\(snippets.joined(separator: "\n"))"
    }

    func drawContent(in rect: CGRect, context: CGContext) -> Bool {
        guard !cachedNotifications.isEmpty else { return false }
        let font = CTFontCreateWithName("SFProDisplay-Regular" as CFString, 19, nil)
        let appFont = CTFontCreateWithName("SFProDisplay-Medium" as CFString, 19, nil)

        var y = rect.maxY - 8
        for notif in cachedNotifications {
            if !notif.app.isEmpty {
                y = GlanceDrawing.drawText(
                    notif.app, at: CGPoint(x: rect.minX, y: y),
                    font: appFont, in: context
                )
                y -= 2
            }
            let truncBody = GlanceDrawing.truncateToFit(notif.body, font: font, maxWidth: rect.width)
            y = GlanceDrawing.drawText(
                truncBody, at: CGPoint(x: rect.minX, y: y),
                font: font, in: context
            )
            y -= 8
            if y < rect.minY + 10 { break }
        }
        return true
    }

    private static func getDelivered() async -> [UNNotification] {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getDeliveredNotifications { cont.resume(returning: $0) }
        }
    }
}
