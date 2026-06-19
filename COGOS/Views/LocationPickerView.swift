import SwiftUI
import MapKit

struct LocationPickerView: View {
    @EnvironmentObject var location: NativeLocation
    @StateObject private var completer = LocationSearchCompleter()
    @Environment(\.dismiss) private var dismiss

    let onPick: (CommuteLocation) -> Void

    @State private var pendingName: String?
    @State private var pendingCoord: CLLocationCoordinate2D?
    @State private var label: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search for an address or place", text: $completer.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(completer.suggestions, id: \.self) { s in
                        Button {
                            Task { await select(s) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(s.title)
                                Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if pendingName != nil {
                    Section("Label") {
                        TextField("e.g. Home, Work, Gym", text: $label)
                        Button("Add") { commit() }.disabled(label.isEmpty)
                    }
                }
            }
            .navigationTitle("Add Location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let here = location.lastKnownLocation() {
                    completer.bias(to: here.coordinate)
                }
            }
        }
    }

    private func select(_ s: MKLocalSearchCompletion) async {
        guard let resolved = await completer.resolve(s) else { return }
        pendingName = resolved.name
        pendingCoord = resolved.coord
        label = resolved.name
    }

    private func commit() {
        guard let coord = pendingCoord else { return }
        onPick(CommuteLocation(
            label: label,
            latitude: coord.latitude,
            longitude: coord.longitude
        ))
        dismiss()
    }
}
