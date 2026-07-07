import SwiftUI
import MapKit

/// Two-step add-location flow: search → confirm + label.
///
/// Selecting a suggestion swaps the whole form to the confirm step, so the
/// state change is unmissable (previously the label section was appended
/// below the suggestion list, off-screen behind the keyboard, and resolve
/// failures were silent).
struct LocationPickerView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var completer = LocationSearchCompleter()
    @Environment(\.dismiss) private var dismiss

    let onPick: (CommuteLocation) -> Void

    private struct ResolvedPlace {
        var name: String
        var detail: String
        var coord: CLLocationCoordinate2D
    }

    @State private var resolved: ResolvedPlace?
    @State private var label = ""
    @State private var resolving: MKLocalSearchCompletion?
    @State private var resolveFailed = false
    @FocusState private var labelFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let place = resolved {
                    selectedSections(place)
                } else {
                    searchSections
                }
            }
            .navigationTitle("Add Location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let here = appState.location.lastKnownLocation() {
                    completer.bias(to: here.coordinate)
                }
            }
        }
    }

    // MARK: - Step 1: search

    @ViewBuilder private var searchSections: some View {
        Section {
            TextField("Search for an address or place", text: $completer.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } footer: {
            if resolveFailed {
                Text("Couldn't load that place. Check your connection and pick a result again.")
                    .foregroundStyle(.red)
            }
        }
        Section {
            ForEach(completer.suggestions, id: \.self) { s in
                Button {
                    Task { await select(s) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.title)
                            Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if resolving === s {
                            ProgressView()
                        }
                    }
                }
                .disabled(resolving != nil)
            }
        }
    }

    // MARK: - Step 2: confirm + label

    @ViewBuilder private func selectedSections(_ place: ResolvedPlace) -> some View {
        Section("Location") {
            VStack(alignment: .leading) {
                Text(place.name)
                if !place.detail.isEmpty {
                    Text(place.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Choose a different location") {
                resolved = nil
                label = ""
            }
        }
        Section("Label") {
            TextField("e.g. Home, Work, Gym", text: $label)
                .focused($labelFocused)
            Button("Add") { commit() }
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Actions

    private func select(_ s: MKLocalSearchCompletion) async {
        guard resolving == nil else { return }
        resolving = s
        resolveFailed = false
        defer { resolving = nil }

        guard let r = await completer.resolve(s) else {
            resolveFailed = true
            return
        }
        resolved = ResolvedPlace(name: r.name, detail: s.subtitle, coord: r.coord)
        label = r.name
        labelFocused = true
    }

    private func commit() {
        guard let place = resolved else { return }
        onPick(CommuteLocation(
            label: label.trimmingCharacters(in: .whitespaces),
            latitude: place.coord.latitude,
            longitude: place.coord.longitude
        ))
        dismiss()
    }
}
