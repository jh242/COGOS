import Foundation
import CoreLocation

/// Location + reverse geocoding via CoreLocation, exposed as async API.
/// Un-Flutterized port of `ios/Runner/LocationChannel.swift`.
final class NativeLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pending: [CheckedContinuation<CLLocation?, Never>] = []

    struct PlaceInfo {
        let placeName: String
        let locality: String
        let administrativeArea: String
        let subLocality: String
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    enum PermissionStatus: String {
        case granted
        case denied
        case notDetermined
    }

    func checkPermission() -> PermissionStatus {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func lastKnownLocation() -> CLLocation? {
        manager.location
    }

    func requestLocation() async -> CLLocation? {
        guard checkPermission() == .granted else { return nil }
        return await withCheckedContinuation { cont in
            pending.append(cont)
            manager.requestLocation()
        }
    }

    func reverseGeocode(latitude: Double, longitude: Double) async -> PlaceInfo? {
        let loc = CLLocation(latitude: latitude, longitude: longitude)
        return await withCheckedContinuation { cont in
            CLGeocoder().reverseGeocodeLocation(loc) { placemarks, error in
                guard let p = placemarks?.first, error == nil else { cont.resume(returning: nil); return }
                var parts: [String] = []
                if let s = p.subLocality, !s.isEmpty { parts.append(s) }
                if let l = p.locality, !l.isEmpty { parts.append(l) }
                if let a = p.administrativeArea, !a.isEmpty { parts.append(a) }
                cont.resume(returning: PlaceInfo(
                    placeName: parts.joined(separator: ", "),
                    locality: p.locality ?? "",
                    administrativeArea: p.administrativeArea ?? "",
                    subLocality: p.subLocality ?? ""
                ))
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let loc = locations.last
        let continuations = pending
        pending.removeAll()
        for cont in continuations { cont.resume(returning: loc) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let continuations = pending
        pending.removeAll()
        for cont in continuations { cont.resume(returning: nil) }
    }
}
