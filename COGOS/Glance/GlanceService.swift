import Foundation

/// Drives the firmware-dashboard tick loop.
///
/// Every ~5 s:
///   1. Build a `GlanceContext`.
///   2. Refresh weather + every provider (each decides internally whether
///      to do I/O or early-return based on its own cadence).
///   3. Push time+weather always; push Quick Notes slots only when they
///      change; always commit.
///
/// The service is dumb: it loops, sorts providers by priority, and pushes.
/// All eligibility/display logic lives inside each provider's `currentNote`.
@MainActor
final class GlanceService: ObservableObject {
    private static let tickInterval: UInt64 = 5 * 1_000_000_000

    private let proto: Proto
    private let location: NativeLocation
    private weak var session: EvenAISession?

    private let weather: WeatherSource
    private let providers: [ContextProvider]

    private var refreshTimer: Task<Void, Never>?
    private var isTicking = false
    private var lastSlots: [QuickNote?] = []

    init(proto: Proto, location: NativeLocation, session: EvenAISession) {
        self.proto = proto
        self.location = location
        self.session = session
        self.weather = WeatherSource(location: location)
        self.providers = [
            CalendarSource(),
            TransitSource(location: location),
            NotificationSource(),
            NewsSource()
        ].sorted { $0.priority < $1.priority }
    }

    // MARK: - Timer

    func startTimer() {
        stopTimer()
        refreshTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: Self.tickInterval)
            }
        }
    }

    func stopTimer() {
        refreshTimer?.cancel(); refreshTimer = nil
    }

    // MARK: - Tick

    private func tick() async {
        if isTicking { return }
        isTicking = true
        defer { isTicking = false }

        let now = Date()
        if location.checkPermission() == .notDetermined {
            location.requestPermission()
        }
        var userLoc = location.lastKnownLocation()
        if userLoc == nil { userLoc = await location.requestLocation() }
        let ctx = GlanceContext(now: now, userLocation: userLoc)

        await weather.refresh(ctx)
        for p in providers {
            await p.refresh(ctx)
        }

        await push(now: now, ctx: ctx)
    }

    private func push(now: Date, ctx: GlanceContext) async {
        let info = weather.currentInfo ?? WeatherInfo(
            icon: .none, temperatureCelsius: 0, displayFahrenheit: false, hour24: true
        )
        _ = await proto.setDashboardTimeAndWeather(now: now, weather: info)

        let notes = providers.compactMap { $0.currentNote }
        let slots: [QuickNote?] = (0..<4).map {
            notes.indices.contains($0) ? notes[$0] : nil
        }
        let slotsChanged = slots != lastSlots
        if slotsChanged {
            _ = await proto.setQuickNoteSlots(slots)
            lastSlots = slots
        }

        logPush(now: now, weather: info, slots: slots, changed: slotsChanged)

        _ = await proto.commitDashboard()
    }

    private func logPush(now: Date, weather: WeatherInfo,
                         slots: [QuickNote?], changed: Bool) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let timeStr = fmt.string(from: now)
        let weatherStr = "\(weather.icon) \(weather.temperatureCelsius)°C"
        let tag = changed ? "slots*" : "slots"
        print("[dashboard] \(timeStr) | weather=\(weatherStr)")
        for (i, slot) in slots.enumerated() {
            if let note = slot {
                print("[dashboard]   \(tag)[\(i + 1)] \(note.title)")
                for line in note.body.split(separator: "\n", omittingEmptySubsequences: false) {
                    print("[dashboard]     \(line)")
                }
            } else {
                print("[dashboard]   \(tag)[\(i + 1)]=nil")
            }
        }
    }
}
