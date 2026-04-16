import Foundation
import CoreLocation

/// Snapshot of "what's happening right now" used by GlanceSources to decide
/// whether they're worth surfacing on the HUD this refresh cycle.
struct GlanceContext {
    let now: Date
    let userLocation: CLLocation?
}
