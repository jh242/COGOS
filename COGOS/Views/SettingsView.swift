import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section(header: Text("API Keys")) {
                SecureField("Anthropic API Key (sk-ant-...)", text: $settings.anthropicAPIKey)
            }
            Section(header: Text("Voice")) {
                Stepper("Silence threshold: \(settings.silenceThreshold)s",
                        value: $settings.silenceThreshold, in: 1...5)
            }
            Section(header: Text("Head-up")) {
                Stepper("Angle: \(settings.headUpAngle)°",
                        value: $settings.headUpAngle, in: 10...60, step: 5)
                    .onChange(of: settings.headUpAngle) { new in
                        Task { await appState.proto.setHeadUpAngle(new) }
                    }
            }
        }
        .navigationTitle("Settings")
    }
}
