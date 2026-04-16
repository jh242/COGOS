import CoreGraphics
import CoreText
import EventKit
import Foundation

private let imminentEventWindow: TimeInterval = 60 * 60

final class CalendarSource: GlanceSource {
    let name = "calendar"
    var enabled = true
    var cacheDuration: TimeInterval = 300

    private let store = EKEventStore()
    private var accessGranted: Bool?
    private var cachedEvents: [EKEvent] = []

    /// Firmware-dashboard-ready events (first 8). Populated alongside
    /// `cachedEvents` during `fetch`.
    private(set) var lastEvents: [CalendarEvent] = []

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    func relevance(_ ctx: GlanceContext) async -> Int? {
        guard let next = await nextEventStart() else { return nil }
        return next.timeIntervalSince(ctx.now) <= imminentEventWindow ? 0 : nil
    }

    func fetch(context: GlanceContext) async -> String? {
        // Pull up to 8 for the firmware calendar pane (hard cap); bitmap
        // renderer only uses the first ~3.
        guard let events = await upcomingEvents(limit: 8), !events.isEmpty else {
            cachedEvents = []
            lastEvents = []
            return nil
        }
        cachedEvents = events
        lastEvents = events.map { ev in
            CalendarEvent(
                title: ev.title ?? "Untitled",
                timeString: Self.timeFormatter.string(from: ev.startDate),
                location: ev.location ?? ""
            )
        }
        let lines = events.prefix(3).map { ev in
            "- \(Self.timeFormatter.string(from: ev.startDate)) \(ev.title ?? "Untitled")"
        }
        return "Calendar:\n\(lines.joined(separator: "\n"))"
    }

    func drawContent(in rect: CGRect, context: CGContext) -> Bool {
        guard !cachedEvents.isEmpty else { return false }
        let font = CTFontCreateWithName("SFProDisplay-Regular" as CFString, 20, nil)
        let timeColumnWidth: CGFloat = 50

        var y = rect.maxY - 8
        for event in cachedEvents {
            let timeStr = Self.timeFormatter.string(from: event.startDate)
            let title = event.title ?? "Untitled"
            y = GlanceDrawing.drawAlignedRow(
                left: timeStr, right: title,
                at: y, in: rect,
                leftWidth: timeColumnWidth,
                font: font, context: context
            )
            y -= 6
            if y < rect.minY + 10 { break }
        }
        return true
    }

    // MARK: - EventKit

    private func requestAccess() async -> Bool {
        if let granted = accessGranted { return granted }
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        accessGranted = granted
        return granted
    }

    private func upcomingEvents(limit: Int) async -> [EKEvent]? {
        guard await requestAccess() else { return nil }
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        guard let end = Calendar.current.date(byAdding: .day, value: 2, to: start) else { return nil }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        return Array(events.prefix(limit))
    }

    private func nextEventStart() async -> Date? {
        (await upcomingEvents(limit: 1))?.first?.startDate
    }
}
