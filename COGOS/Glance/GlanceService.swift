import Foundation

/// Context-aware glance HUD rendered as a bitmap.
///
/// Rendering policy:
///   Left column  → fixed sources (time, weather) always shown
///   Right column → one contextual source chosen by relevance/priority
///                  (calendar → transit → notifications), falling back to news
///                  if nothing contextual is relevant right now.
@MainActor
final class GlanceService: ObservableObject {
    private let proto: Proto
    private let location: NativeLocation
    private let bmpTransfer: BmpTransfer
    private weak var session: EvenAISession?
    private weak var settings: Settings?

    private var sources: [GlanceSource] = []
    private var weatherSource: WeatherSource?
    private var calendarSource: CalendarSource?
    private var sourceCache: [String: (String, Date)] = [:]
    private var refreshTimer: Task<Void, Never>?
    private var isRefreshing = false

    private var winningSource: GlanceSource?
    private var winningSourceText: String?

    private let renderer = GlanceRenderer()

    @Published var isShowing = false

    init(proto: Proto, location: NativeLocation, session: EvenAISession,
         requestQueue: BleRequestQueue, bluetooth: BluetoothManager,
         settings: Settings) {
        self.proto = proto
        self.location = location
        self.session = session
        self.settings = settings
        self.bmpTransfer = BmpTransfer(queue: requestQueue, bluetooth: bluetooth)
        buildSources()
    }

    private func buildSources() {
        let weather = WeatherSource(location: location)
        let calendar = CalendarSource()
        weatherSource = weather
        calendarSource = calendar
        sources = [
            TimeSource(),
            weather,
            calendar,
            TransitSource(location: location),
            NotificationSource(),
            NewsSource()
        ]
    }

    // MARK: - Timer

    func startTimer() {
        stopTimer()
        Task { await refresh() }
        refreshTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    func stopTimer() {
        refreshTimer?.cancel(); refreshTimer = nil
    }

    // MARK: - Refresh

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        var userLoc = location.lastKnownLocation()
        if userLoc == nil { userLoc = await location.requestLocation() }
        let ctx = GlanceContext(now: now, userLocation: userLoc)

        // Fetch fixed sources (populates their cached structured data).
        for s in sources where s.enabled && s.tier == .fixed {
            _ = await fetchCached(s, now: now, context: ctx)
        }

        // Contextual tier — pick the most relevant source.
        winningSource = nil
        winningSourceText = nil
        var scored: [(Int, GlanceSource)] = []
        for s in sources where s.enabled && s.tier == .contextual {
            if let p = await s.relevance(ctx) { scored.append((p, s)) }
        }
        scored.sort { $0.0 < $1.0 }

        for (_, source) in scored {
            if let text = await fetchCached(source, now: now, context: ctx) {
                winningSource = source
                winningSourceText = text
                break
            }
        }

        // Fallback tier — only if no contextual source fired.
        if winningSource == nil {
            for s in sources where s.enabled && s.tier == .fallback {
                if let text = await fetchCached(s, now: now, context: ctx) {
                    winningSource = s
                    winningSourceText = text
                    break
                }
            }
        }

        // Firmware-dashboard mode: push pinned panes each tick. Contextual
        // sources (transit/notifications) still lack firmware pane support
        // pending the Quick Notes sniff — see the dashboard-migration plan.
        if settings?.useFirmwareDashboard == true {
            await pushFirmwareDashboard(now: now)
        }
    }

    private func pushFirmwareDashboard(now: Date) async {
        if let info = weatherSource?.lastWeatherInfo {
            _ = await proto.setDashboardTimeAndWeather(now: now, weather: info)
        }
        let events = calendarSource?.lastEvents ?? []
        _ = await proto.setDashboardCalendar(events)
    }

    /// Fetch a source, honoring its cacheDuration.
    private func fetchCached(_ s: GlanceSource, now: Date, context: GlanceContext) async -> String? {
        if let (data, at) = sourceCache[s.name],
           s.cacheDuration > 0, now.timeIntervalSince(at) < s.cacheDuration {
            return data
        }
        guard let data = await s.fetch(context: context), !data.isEmpty else { return nil }
        sourceCache[s.name] = (data, now)
        return data
    }

    // MARK: - Show / dismiss

    func showGlance() async {
        guard !(session?.isRunning ?? false) else { return }
        // Firmware mode is cadence-driven; user invokes the dashboard via
        // firmware gestures (double-tap / head-up). Phase 2 Q2 decision.
        if settings?.useFirmwareDashboard == true { return }
        await sendBitmap()
        isShowing = true
    }

    func forceRefreshAndShow() async {
        guard !(session?.isRunning ?? false) else { return }
        sourceCache.removeAll()
        await refresh()
        if settings?.useFirmwareDashboard == true { return }
        isShowing = true
        await sendBitmap()
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        Task { _ = await proto.exit() }
    }

    private func sendBitmap() async {
        guard let bmp = renderer.render(
            time: Date(),
            weather: weatherSource?.lastWeather,
            contextualSource: winningSource,
            contextualFallbackText: winningSourceText
        ) else { return }
        _ = await bmpTransfer.sendToBoth(bmp)
    }
}
