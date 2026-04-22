import CoreLocation
import Foundation

/// Nearest-transit-station arrivals. Eligible when the user is within 200m
/// of a station and the station has upcoming arrivals; otherwise nil.
final class TransitSource: ContextProvider {
    let name = "transit"
    let priority = 1

    private static let stationGateMeters: CLLocationDistance = 200
    private static let refreshInterval: TimeInterval = 60

    let location: NativeLocation

    private var lastFetch: Date?
    private var cachedStation: String = ""
    private var cachedStationLocation: CLLocation?
    private var cachedArrivals: [(route: String, dir: String, mins: Int)] = []

    init(location: NativeLocation) {
        self.location = location
    }

    var currentNote: QuickNote? {
        guard !cachedStation.isEmpty,
              let stationLoc = cachedStationLocation,
              let userLoc = location.lastKnownLocation(),
              stationLoc.distance(from: userLoc) <= Self.stationGateMeters else {
            return nil
        }
        guard !cachedArrivals.isEmpty else { return nil }
        let body = cachedArrivals
            .map { "\($0.route)\($0.dir)  \($0.mins) min" }
            .joined(separator: "\n")
        return QuickNote(title: cachedStation, body: body)
    }

    func refresh(_ ctx: GlanceContext) async {
        if let last = lastFetch, ctx.now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        lastFetch = ctx.now

        guard let userLoc = location.lastKnownLocation() else {
            trace("no user location — skipping")
            return
        }

        let stations: [WTFTClient.Station]
        do {
            stations = try await WTFTClient.fetchByLocation(
                lat: userLoc.coordinate.latitude,
                lon: userLoc.coordinate.longitude
            )
        } catch {
            trace("WTFT fetch threw: \(error)")
            return
        }

        guard let station = stations.first,
              let lat = station.latitude,
              let lon = station.longitude else {
            trace("no station with coordinates near user")
            cachedStation = ""
            cachedStationLocation = nil
            cachedArrivals = []
            return
        }

        let stationLoc = CLLocation(latitude: lat, longitude: lon)
        let distMeters = stationLoc.distance(from: userLoc)

        cachedStationLocation = stationLoc
        cachedStation = "\(station.name) (\(Int(distMeters.rounded())) m)"

        let now = ctx.now
        var combined: [(dir: String, arr: WTFTClient.Arrival)] = station.N.map { ("↑", $0) }
        combined.append(contentsOf: station.S.map { ("↓", $0) })
        let future = combined.filter { $0.arr.time > now }
        let upcoming = future.sorted { $0.arr.time < $1.arr.time }.prefix(5)

        cachedArrivals = upcoming.map { item in
            let mins = max(0, Int(item.arr.time.timeIntervalSince(now) / 60))
            return (route: item.arr.route, dir: item.dir, mins: mins)
        }

        let gated = distMeters <= Self.stationGateMeters ? "in-range" : "out-of-range"
        trace("\(station.name) \(Int(distMeters))m [\(gated)] · \(cachedArrivals.count) arrivals")
    }
}
