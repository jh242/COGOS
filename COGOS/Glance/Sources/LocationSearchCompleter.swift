import Foundation
import MapKit
import Combine

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet { schedule() }
    }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()
    private var debounce: Task<Void, Never>?

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    func bias(to coordinate: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 50_000,
            longitudinalMeters: 50_000
        )
    }

    private func schedule() {
        debounce?.cancel()
        let q = query
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.completer.queryFragment = q }
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> (name: String, coord: CLLocationCoordinate2D)? {
        let req = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: req)
        do {
            let resp = try await search.start()
            guard let item = resp.mapItems.first else { return nil }
            let name = item.placemark.name ?? completion.title
            return (name, item.placemark.coordinate)
        } catch {
            return nil
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in self.suggestions = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
