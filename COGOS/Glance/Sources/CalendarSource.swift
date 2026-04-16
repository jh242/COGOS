import Foundation
import EventKit

/// Relevance window: if the next event starts within this many seconds, surface it.
private let imminentEventWindow: TimeInterval = 60 * 60 // 60 min

struct CalendarSource: GlanceSource {
    let name = "calendar"
    var enabled = true
    var cacheDuration: TimeInterval = 300

    func relevance(_ ctx: GlanceContext) async -> Int? {
        guard let next = await Self.nextEventStart() else { return nil }
        return next.timeIntervalSince(ctx.now) <= imminentEventWindow ? 0 : nil
    }

    func fetch() async -> String? {
        guard let events = await Self.upcomingEvents(limit: 3), !events.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        let lines = events.map { ev -> String in
            let t = formatter.string(from: ev.startDate)
            let title = ev.title ?? "Untitled"
            return "- \(t) \(title)"
        }
        return "Calendar:\n\(lines.joined(separator: "\n"))"
    }

    // MARK: - EventKit helpers

    private static func requestAccess(_ store: EKEventStore) async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
        return await withCheckedContinuation { cont in
            store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
        }
    }

    private static func upcomingEvents(limit: Int) async -> [EKEvent]? {
        let store = EKEventStore()
        guard await requestAccess(store) else { return nil }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        guard let end = Calendar.current.date(byAdding: .day, value: 2, to: start) else { return nil }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        return Array(events.prefix(limit))
    }

    private static func nextEventStart() async -> Date? {
        (await upcomingEvents(limit: 1))?.first?.startDate
    }
}
