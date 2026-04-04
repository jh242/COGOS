import Flutter
import MapKit

/// Provides nearby transit departure info via a Flutter MethodChannel.
class TransitChannel: NSObject {
    static let shared = TransitChannel()

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "method.transit",
            binaryMessenger: messenger
        )

        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }

            switch call.method {
            case "getNearbyDepartures":
                self.getNearbyDepartures(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func getNearbyDepartures(result: @escaping FlutterResult) {
        guard CLLocationManager.locationServicesEnabled() else {
            result(nil)
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "transit station"
        request.resultTypes = .pointOfInterest

        let search = MKLocalSearch(request: request)
        search.start { response, error in
            guard let response = response, error == nil else {
                result(nil)
                return
            }

            let stations = response.mapItems.prefix(3)
            let names = stations.map { $0.name ?? "Unknown" }
            result(names.joined(separator: ", "))
        }
    }
}
