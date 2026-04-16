import Foundation

/// Context-aware glance HUD.
///
/// Rendering policy:
///   line 1-2  → fixed sources (time, weather) always shown
///   line 3-5  → one contextual source chosen by relevance/priority
///               (calendar → transit → notifications), falling back to news
///               if nothing contextual is relevant right now.
@MainActor
final class GlanceService: ObservableObject {
    private let proto: Proto
    private let location: NativeLocation
    private weak var session: EvenAISession?

    private var sources: [GlanceSource] = []
    private var cachedLines: [String] = []
    private var sourceCache: [String: (String, Date)] = [:]
    private var refreshTimer: Task<Void, Never>?
    private var isRefreshing = false

    @Published var isShowing = false

    init(proto: Proto, location: NativeLocation, session: EvenAISession) {
        self.proto = proto
        self.location = location
        self.session = session
        buildSources()
    }

    private func buildSources() {
        sources = [
            TimeSource(),
            WeatherSource(location: location),
            CalendarSource(),
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

        var snippets: [String] = []

        // 1. Fixed tier — always included.
        for s in sources where s.enabled && s.tier == .fixed {
            if let line = await fetchCached(s, now: now) { snippets.append(line) }
        }

        // 2. Contextual tier — pick the single best relevant source.
        var scored: [(Int, GlanceSource)] = []
        for s in sources where s.enabled && s.tier == .contextual {
            if let p = await s.relevance(ctx) { scored.append((p, s)) }
        }
        scored.sort { $0.0 < $1.0 }
        var pickedContextual = false
        if let winner = scored.first?.1,
           let line = await fetchCached(winner, now: now) {
            snippets.append(line)
            pickedContextual = true
        }

        // 3. Fallback tier — only if no contextual source fired.
        if !pickedContextual {
            for s in sources where s.enabled && s.tier == .fallback {
                if let line = await fetchCached(s, now: now) {
                    snippets.append(line); break
                }
            }
        }

        cachedLines = snippets.isEmpty ? ["No data available"] : snippets
    }

    /// Fetch a source, honoring its cacheDuration.
    private func fetchCached(_ s: GlanceSource, now: Date) async -> String? {
        if let (data, at) = sourceCache[s.name],
           s.cacheDuration > 0, now.timeIntervalSince(at) < s.cacheDuration {
            return data
        }
        guard let data = await s.fetch(), !data.isEmpty else { return nil }
        sourceCache[s.name] = (data, now)
        return data
    }

    // MARK: - Show / dismiss

    func showGlance() async {
        guard !(session?.isRunning ?? false) else { return }
        let lines = cachedLines.isEmpty ? ["Glance loading..."] : cachedLines
        await sendToGlasses(lines)
        isShowing = true
    }

    func forceRefreshAndShow() async {
        guard !(session?.isRunning ?? false) else { return }
        await sendToGlasses(["Refreshing..."])
        isShowing = true
        sourceCache.removeAll()
        await refresh()
        let lines = cachedLines.isEmpty ? ["No data available"] : cachedLines
        await sendToGlasses(lines)
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        Task { _ = await proto.exit() }
    }

    private func sendToGlasses(_ lines: [String]) async {
        var measured: [String] = []
        for line in lines { measured.append(contentsOf: TextPaginator.measureStringList(line)) }
        let first5 = Array(measured.prefix(5))
        let padCount = max(0, 5 - first5.count)
        let pad = Array(repeating: " \n", count: padCount)
        let content = first5.map { $0 + "\n" }
        let screen = (pad + content).joined()
        _ = await proto.sendEvenAIData(screen, newScreen: 0x01 | 0x70,
                                       pos: 0, currentPageNum: 1, maxPageNum: 1)
    }
}
