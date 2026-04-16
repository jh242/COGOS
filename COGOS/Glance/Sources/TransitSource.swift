import CoreGraphics
import CoreLocation
import CoreText
import Foundation

private let maxStationDistance: CLLocationDistance = 500  // meters

final class TransitSource: GlanceSource {
    let name = "transit"
    var enabled = true
    var cacheDuration: TimeInterval = 120

    let location: NativeLocation

    private var cachedStation: String = ""
    private var cachedArrivals: [(route: String, dir: String, mins: Int)] = []

    init(location: NativeLocation) {
        self.location = location
    }

    func relevance(_ ctx: GlanceContext) async -> Int? {
        guard ctx.userLocation != nil else { return nil }
        return 1
    }

    func fetch(context: GlanceContext) async -> String? {
        guard let userLoc = context.userLocation else { return nil }

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

        let now = context.now
        var combined: [(dir: String, arr: WTFTClient.Arrival)] = station.N.map { ("↑", $0) }
        combined.append(contentsOf: station.S.map { ("↓", $0) })
        let future = combined.filter { $0.arr.time > now }
        let sorted = future.sorted { $0.arr.time < $1.arr.time }
        let upcoming = Array(sorted.prefix(5))

        cachedStation = "\(station.name) (\(distStr))"
        cachedArrivals = upcoming.map { item in
            let mins = max(0, Int(item.arr.time.timeIntervalSince(now) / 60))
            return (route: item.arr.route, dir: item.dir, mins: mins)
        }

        if upcoming.isEmpty {
            return "Transit: \(station.name) (\(distStr)) · no arrivals"
        }
        let parts = cachedArrivals.map { "\($0.route)\($0.dir) \($0.mins)m" }
        return "Transit: \(station.name) (\(distStr)) · \(parts.joined(separator: ", "))"
    }

    func drawContent(in rect: CGRect, context: CGContext) -> Bool {
        guard !cachedArrivals.isEmpty else { return false }
        let headerFont = CTFontCreateWithName("SFProDisplay-Medium" as CFString, 20, nil)
        let font = CTFontCreateWithName("SFProDisplay-Regular" as CFString, 20, nil)
        let routeColWidth: CGFloat = 60

        var y = rect.maxY - 8
        // Station header.
        y = GlanceDrawing.drawText(
            cachedStation, at: CGPoint(x: rect.minX, y: y),
            font: headerFont, in: context
        )
        y -= 8

        for arrival in cachedArrivals {
            let routeStr = "\(arrival.route)\(arrival.dir)"
            let timeStr = "\(arrival.mins) min"
            y = GlanceDrawing.drawAlignedRow(
                left: routeStr, right: timeStr,
                at: y, in: rect,
                leftWidth: routeColWidth,
                font: font, context: context
            )
            y -= 4
            if y < rect.minY + 10 { break }
        }
        return true
    }
}
