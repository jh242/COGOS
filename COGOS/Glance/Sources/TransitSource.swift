import Foundation
import CoreLocation

private let maxStationDistance: CLLocationDistance = 500  // meters

struct TransitSource: GlanceSource {
    let name = "transit"
    var enabled = true
    var cacheDuration: TimeInterval = 120

    let location: NativeLocation

    func relevance(_ ctx: GlanceContext) async -> Int? {
        guard let userLoc = ctx.userLocation else { return nil }
        let stations: [WTFTClient.Station]
        do {
            stations = try await WTFTClient.fetchByLocation(
                lat: userLoc.coordinate.latitude,
                lon: userLoc.coordinate.longitude
            )
        } catch { return nil }
        guard let s = stations.first, let lat = s.latitude, let lon = s.longitude else { return nil }
        let dist = CLLocation(latitude: lat, longitude: lon).distance(from: userLoc)
        return dist <= maxStationDistance ? 1 : nil
    }

    func fetch() async -> String? {
        var loc = location.lastKnownLocation()
        if loc == nil { loc = await location.requestLocation() }
        guard let userLoc = loc else { return nil }

        let stations: [WTFTClient.Station]
        do {
            stations = try await WTFTClient.fetchByLocation(
                lat: userLoc.coordinate.latitude,
                lon: userLoc.coordinate.longitude
            )
        } catch {
            return nil
        }

        guard let station = stations.first,
              let lat = station.latitude, let lon = station.longitude
        else { return nil }

        let distMeters = CLLocation(latitude: lat, longitude: lon).distance(from: userLoc)
        guard distMeters <= maxStationDistance else { return nil }

        let distStr = "\(Int(distMeters.rounded())) m"

        let now = Date()
        // Tag each arrival with its direction: N = uptown (↑), S = downtown (↓).
        var combined: [(dir: String, arr: WTFTClient.Arrival)] = station.N.map { ("↑", $0) }
        combined.append(contentsOf: station.S.map { ("↓", $0) })
        let future = combined.filter { $0.arr.time > now }
        let sorted = future.sorted { $0.arr.time < $1.arr.time }
        let upcoming = Array(sorted.prefix(3))

        if upcoming.isEmpty {
            return "Transit: \(station.name) (\(distStr)) · no arrivals"
        }
        let parts = upcoming.map { item -> String in
            let mins = max(0, Int(item.arr.time.timeIntervalSince(now) / 60))
            return "\(item.arr.route)\(item.dir) \(mins)m"
        }
        return "Transit: \(station.name) (\(distStr)) · \(parts.joined(separator: ", "))"
    }
}
