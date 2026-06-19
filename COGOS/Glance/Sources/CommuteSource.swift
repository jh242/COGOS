import Foundation
import CoreLocation
import MapKit

/// Transit directions to up to 5 saved locations. Eligible when at least one
/// saved location has a parseable transit route with ≤ 1 transfer and the
/// user is not within 200 m of it.
@MainActor
final class CommuteSource: ContextProvider {
    let name = "commute"

    private static let refreshInterval: TimeInterval = 5 * 60
    private static let selfSkipMeters: CLLocationDistance = 200
    private static let maxTransfers = 1

    private let location: NativeLocation
    private let settings: Settings

    private var lastFetch: Date?
    private var cachedRows: [String: CommuteFormatter.Row] = [:]  // keyed by label

    init(location: NativeLocation, settings: Settings) {
        self.location = location
        self.settings = settings
    }

    var currentNote: QuickNote? {
        guard !cachedRows.isEmpty else { return nil }
        let body = CommuteFormatter.body(rows: Array(cachedRows.values))
        guard !body.isEmpty else { return nil }
        return QuickNote(title: "Commute", body: body)
    }

    func refresh(_ ctx: GlanceContext) async {
        if let last = lastFetch, ctx.now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        lastFetch = ctx.now

        let destinations = settings.commuteLocations
        guard !destinations.isEmpty else {
            cachedRows.removeAll()
            return
        }
        // Fetch implementation lands in Task 7.
    }
}
