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

    private struct Fetched {
        let label: String
        let minutes: Int
        let legs: [CommuteLeg]
    }

    private func fetch(for dest: CommuteLocation, from origin: CLLocation) async -> Fetched? {
        let originItem = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        let destItem = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: dest.latitude, longitude: dest.longitude)
        ))
        let req = MKDirections.Request()
        req.source = originItem
        req.destination = destItem
        req.transportType = .transit
        req.requestsAlternateRoutes = true
        let directions = MKDirections(request: req)

        let response: MKDirections.Response
        do {
            response = try await directions.calculate()
        } catch {
            trace("\(dest.label): MKDirections failed — \(error.localizedDescription)")
            return nil
        }

        let eligible = response.routes.first { route in
            CommuteParser.transferCount(in: route.steps.map(toRawStep)) <= Self.maxTransfers
        }
        guard let route = eligible else {
            trace("\(dest.label): no route with ≤\(Self.maxTransfers) transfer")
            return nil
        }
        let legs = CommuteParser.legs(from: route.steps.map(toRawStep))
        guard !legs.isEmpty else {
            trace("\(dest.label): route had no parseable transit legs")
            return nil
        }
        let minutes = max(1, Int((route.expectedTravelTime / 60).rounded()))
        return Fetched(label: dest.label, minutes: minutes, legs: legs)
    }

    private func toRawStep(_ step: MKRoute.Step) -> RawStep {
        let kind: RawStep.Kind
        switch step.transportType {
        case .walking: kind = .walking
        case .transit: kind = .transit
        default:       kind = .other
        }
        return RawStep(kind: kind, instructions: step.instructions)
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
        guard let userLoc = location.lastKnownLocation() else {
            trace("no user location — skipping cycle")
            return
        }

        let nearby: Set<String> = Set(destinations.compactMap { dest -> String? in
            let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
            return destLoc.distance(from: userLoc) <= Self.selfSkipMeters ? dest.label : nil
        })
        for label in nearby { cachedRows.removeValue(forKey: label) }

        let toFetch = destinations.filter { !nearby.contains($0.label) }
        guard !toFetch.isEmpty else { return }

        let results = await withTaskGroup(of: Fetched?.self, returning: [Fetched].self) { group in
            for dest in toFetch {
                group.addTask { await self.fetch(for: dest, from: userLoc) }
            }
            var collected: [Fetched] = []
            for await r in group { if let r { collected.append(r) } }
            return collected
        }

        for r in results {
            cachedRows[r.label] = (label: r.label, minutes: r.minutes, legs: r.legs)
        }
        // Keep only entries whose label is still in the current settings list,
        // so destinations removed by the user are evicted on the next cycle.
        let validLabels = Set(destinations.map(\.label))
        cachedRows = cachedRows.filter { validLabels.contains($0.key) }
        trace("refreshed \(results.count)/\(toFetch.count) destinations")
    }
}
