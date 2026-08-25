import SwiftUI

struct ContextProvidersSettingsView: View {
    @EnvironmentObject var settings: Settings
    @State private var showPicker = false

    var body: some View {
        Form {
            Section(
                header: Text("News"),
                footer: Text("Google News RSS is summarized by a cheap OpenRouter model into a three-line digest for the glasses. Without an API key, clipped headlines are shown instead.")
            ) {
                Picker("Topic", selection: $settings.newsTopic) {
                    ForEach(NewsTopic.allCases) { topic in
                        Text(topic.displayName).tag(topic)
                    }
                }
            }

            Section(
                header: Text("Commute Locations"),
                footer: Text("Up to 5. Used by CommuteSource to show transit directions.")
            ) {
                ForEach($settings.commuteLocations) { $loc in
                    TextField("Label", text: $loc.label)
                }
                .onDelete { idx in
                    settings.commuteLocations.remove(atOffsets: idx)
                }
                if settings.commuteLocations.count < 5 {
                    Button("Add Location") { showPicker = true }
                }
            }
        }
        .navigationTitle("Context Providers")
        .sheet(isPresented: $showPicker) {
            LocationPickerView { loc in
                settings.commuteLocations.append(loc)
            }
        }
    }
}
