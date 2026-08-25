import CoreLocation
import EventKit
import Foundation
import WeatherKit

/// On-device data the spoken agent tools read. Isolated to the main actor
/// because EventKit, WeatherKit, and `CLLocationManager` are used from there.
@MainActor
final class AgentDeviceContext {
    private let location: NativeLocation
    private let eventStore = EKEventStore()
    private let weatherService = WeatherService.shared
    private var calendarAccess: Bool?

    init(location: NativeLocation) {
        self.location = location
    }

    func placeSummary() async -> String {
        switch location.checkPermission() {
        case .denied:
            return "Location permission is denied."
        case .notDetermined:
            return "Location permission has not been granted yet."
        case .granted:
            break
        }
        guard let fix = location.lastKnownLocation() else {
            return "No GPS fix yet. The wearer may need to wait for a location update."
        }
        let place = await location.reverseGeocode(
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude
        )
        let name = place?.placeName
        if let name, !name.isEmpty {
            return "\(name) (\(String(format: "%.4f", fix.coordinate.latitude)), \(String(format: "%.4f", fix.coordinate.longitude)))"
        }
        return String(
            format: "Coordinates %.4f, %.4f",
            fix.coordinate.latitude,
            fix.coordinate.longitude
        )
    }

    func weatherSummary() async -> String {
        guard let fix = location.lastKnownLocation() else {
            return "No GPS fix, so weather is unavailable."
        }
        do {
            let weather = try await weatherService.weather(for: fix)
            let current = weather.currentWeather
            let celsius = current.temperature.converted(to: .celsius).value
            let fahrenheit = current.temperature.converted(to: .fahrenheit).value
            let wind = current.wind.speed.converted(to: .milesPerHour).value
            let place = await location.reverseGeocode(
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude
            )
            let whereAt = place?.placeName.isEmpty == false ? place!.placeName : "current location"
            return [
                "Location: \(whereAt)",
                "Condition: \(current.condition.description)",
                String(format: "Temperature: %.0f°C / %.0f°F", celsius, fahrenheit),
                String(format: "Humidity: %.0f%%", current.humidity * 100),
                String(format: "Wind: %.0f mph", wind)
            ].joined(separator: "\n")
        } catch {
            return "WeatherKit failed: \(error.localizedDescription)"
        }
    }

    func calendarSummary(hoursAhead: Int) async -> String {
        let window = TimeInterval(max(1, min(hoursAhead, 168)) * 3600)
        guard await requestCalendarAccess() else {
            return "Calendar access is denied."
        }
        let start = Date()
        let end = start.addingTimeInterval(window)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
        guard !events.isEmpty else {
            return "No events in the next \(max(1, min(hoursAhead, 168))) hours."
        }
        let time = DateFormatter()
        time.dateFormat = "EEE H:mm"
        return events.map { event in
            let title = event.title ?? "Untitled"
            let when = time.string(from: event.startDate)
            let loc = event.location?.isEmpty == false ? " @ \(event.location!)" : ""
            return "\(when) \(title)\(loc)"
        }.joined(separator: "\n")
    }

    private func requestCalendarAccess() async -> Bool {
        if let calendarAccess { return calendarAccess }
        let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
        calendarAccess = granted
        return granted
    }
}
