import Foundation

final class LocationSource: GlanceSource {
    let name = "location"
    var enabled = true
    var cacheDuration: TimeInterval = 60

    let location: NativeLocation

    init(location: NativeLocation) {
        self.location = location
    }

    func fetch(context: GlanceContext) async -> String? {
        let perm = location.checkPermission()
        if perm == .notDetermined {
            location.requestPermission()
            return nil
        }
        if perm == .denied { return nil }

        guard let loc = await location.requestLocation() else { return nil }
        if let info = await location.reverseGeocode(latitude: loc.coordinate.latitude,
                                                    longitude: loc.coordinate.longitude),
           !info.placeName.isEmpty {
            return "Location: \(info.placeName)"
        }
        return String(format: "Location: %.2f, %.2f", loc.coordinate.latitude, loc.coordinate.longitude)
    }
}
