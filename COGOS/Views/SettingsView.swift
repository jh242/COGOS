import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section(header: Text("LLM Endpoint")) {
                TextField("Base URL", text: $settings.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model", text: $settings.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $settings.apiKey)
                Toggle("Stream responses", isOn: $settings.useStreaming)
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
            Section(header: Text("Display")) {
                Toggle("Auto brightness", isOn: $settings.autoBrightness)
                    .onChange(of: settings.autoBrightness) { _ in pushBrightness() }
                HStack {
                    Text("Brightness")
                    Slider(
                        value: Binding(
                            get: { Double(settings.brightness) },
                            set: { settings.brightness = Int($0) }
                        ),
                        in: 0...42,
                        step: 1,
                        onEditingChanged: { editing in
                            if !editing { pushBrightness() }
                        }
                    )
                    Text("\(settings.brightness)").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func pushBrightness() {
        Task {
            await appState.proto.setBrightness(
                level: settings.brightness,
                auto: settings.autoBrightness
            )
        }
    }
}
