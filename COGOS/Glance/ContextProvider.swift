import Foundation

/// A pluggable context source that refreshes on every dashboard tick and
/// exposes a single Quick Notes payload when it has something to show.
///
/// `GlanceService` drives the loop:
///   - Calls `refresh(ctx)` on every provider every tick (~5 s).
///   - Each provider decides internally whether to do I/O or early-return
///     based on its own cadence.
///   - `currentNote` is the sole signal of "show me this". `nil` means
///     "don't show me" — display eligibility (transit distance, calendar
///     window, notification age, etc.) lives inside the provider.
///   - Providers are sorted by `priority` (lower = higher priority), their
///     notes compacted into the 4 Quick Notes slots; overflow is dropped.
///
/// `WeatherSource` does **not** conform. It has the same `refresh(ctx)`
/// lifecycle but produces `WeatherInfo` for the firmware's dedicated
/// time+weather pane, not a `QuickNote`.
protocol ContextProvider: AnyObject {
    var name: String { get }
    /// Lower = higher priority when populating the 4 Quick Notes slots.
    var priority: Int { get }
    func refresh(_ ctx: GlanceContext) async
    var currentNote: QuickNote? { get }
}

extension ContextProvider {
    func trace(_ msg: String) { print("[provider:\(name)] \(msg)") }
}
