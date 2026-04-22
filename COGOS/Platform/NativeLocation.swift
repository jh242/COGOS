import Foundation
import CoreLocation

/// Continuous background location + reverse geocoding.
///
/// Lifecycle is tied to the BLE connection (see `AppState`):
///   - glasses connect → `startUpdates()` begins streaming fixes
///   - glasses disconnect → `stopUpdates()` releases the GPS
///
/// Consumers read the latest fix synchronously via `lastKnownLocation()`;
/// there are no async one-shot requests because `startUpdatingLocation` keeps
/// `manager.location` fresh on the `distanceFilter` cadence.
final class NativeLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var isUpdating = false

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
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
    }

    enum PermissionStatus: String {
        case granted
        case denied
        case notDetermined
    }

    func checkPermission() -> PermissionStatus {
        switch manager.authorizationStatus {
        case .authorizedAlways: return .granted
        case .authorizedWhenInUse: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Prompt for Always authorization. iOS will show the WhenInUse prompt
    /// first, then escalate to Always on the next request.
    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func lastKnownLocation() -> CLLocation? {
        manager.location
    }

    /// Begin streaming fixes. Idempotent.
    func startUpdates() {
        guard !isUpdating else { return }
        isUpdating = true
        manager.startUpdatingLocation()
    }

    /// Stop streaming fixes. Idempotent.
    func stopUpdates() {
        guard isUpdating else { return }
        isUpdating = false
        manager.stopUpdatingLocation()
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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // When the user grants WhenInUse, immediately escalate to Always.
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Fixes land in `manager.location`; consumers poll.
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[location] update failed: \(error)")
    }
}
