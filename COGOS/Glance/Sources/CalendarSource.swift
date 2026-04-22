import EventKit
import Foundation

/// Upcoming-calendar-event provider. Eligible when an event starts within
/// the next 60 minutes; otherwise `currentNote` is nil.
final class CalendarSource: ContextProvider {
    let name = "calendar"
    let priority = 0

    private static let imminentWindow: TimeInterval = 60 * 60
    private static let refreshInterval: TimeInterval = 5 * 60

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    private let store = EKEventStore()
    private var accessGranted: Bool?
    private var lastFetch: Date?
    private var upcomingEvents: [EKEvent] = []

    /// Mirror of the upcoming events for the firmware calendar pane (unused
    /// right now — we render via Quick Notes — but kept so a future pane
    /// swap can reuse the same data without a second fetch path).
    private(set) var lastEvents: [CalendarEvent] = []

    var currentNote: QuickNote? {
        let imminent = upcomingEvents.filter {
            $0.startDate.timeIntervalSince(Date()) <= Self.imminentWindow
                && $0.startDate > Date()
        }
        guard !imminent.isEmpty else { return nil }
        let body = imminent.prefix(3).map { ev -> String in
            let title = ev.title ?? "Untitled"
            let time = Self.timeFormatter.string(from: ev.startDate)
            let loc = ev.location?.isEmpty == false ? " @ \(ev.location!)" : ""
            return "\(time) \(title)\(loc)"
        }.joined(separator: "\n")
        return QuickNote(title: "Calendar", body: body)
    }

    func refresh(_ ctx: GlanceContext) async {
        if let last = lastFetch, ctx.now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        lastFetch = ctx.now

        guard await requestAccess() else {
            trace("EventKit access denied")
            upcomingEvents = []
            lastEvents = []
            return
        }
        let start = Calendar.current.startOfDay(for: ctx.now)
        guard let end = Calendar.current.date(byAdding: .day, value: 2, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: ctx.now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)

        upcomingEvents = Array(events)
        lastEvents = upcomingEvents.map { ev in
            CalendarEvent(
                title: ev.title ?? "Untitled",
                timeString: Self.timeFormatter.string(from: ev.startDate),
                location: ev.location ?? ""
            )
        }
        trace("EventKit → \(upcomingEvents.count) upcoming")
    }

    private func requestAccess() async -> Bool {
        if let granted = accessGranted { return granted }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        accessGranted = granted
        return granted
    }
}
