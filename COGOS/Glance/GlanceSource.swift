import CoreGraphics
import Foundation

/// Where a source sits in the glance priority stack.
/// - fixed:      always rendered (time, weather).
/// - contextual: chosen by priority when relevant (transit, calendar, notifications).
/// - fallback:   used only when no contextual source is relevant (news).
enum GlanceTier {
    case fixed
    case contextual
    case fallback
}

/// A pluggable source of contextual data for the glance HUD.
protocol GlanceSource: AnyObject {
    var name: String { get }
    var enabled: Bool { get }
    var cacheDuration: TimeInterval { get }
    var tier: GlanceTier { get }
    /// Lower number = higher priority. `nil` means "not relevant now, skip".
    /// `fixed` and `fallback` sources can ignore this.
    func relevance(_ ctx: GlanceContext) async -> Int?
    func fetch(context: GlanceContext) async -> String?

    /// Draw this source's content into the given rect of the glance bitmap.
    /// Return `true` if custom drawing was performed, `false` to fall back
    /// to plain text rendering of `fetch()` output.
    func drawContent(in rect: CGRect, context: CGContext) -> Bool
}

extension GlanceSource {
    var tier: GlanceTier { .contextual }
    func relevance(_ ctx: GlanceContext) async -> Int? { 0 }
    func drawContent(in rect: CGRect, context: CGContext) -> Bool { false }
}
