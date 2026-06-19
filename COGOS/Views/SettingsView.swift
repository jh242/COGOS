import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $settings.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Model", text: $settings.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $settings.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Stream responses", isOn: $settings.useStreaming)
                Stepper(value: $settings.maxOutputTokens, in: 128...4096, step: 128) {
                    LabeledContent("Max output", value: "\(settings.maxOutputTokens) tokens")
                }
            } header: {
                Text("Assistant Endpoint")
            } footer: {
                Text("OpenRouter is the default. Any OpenAI-compatible chat completions base URL still works.")
            }

            Section {
                Stepper(value: $settings.silenceThreshold, in: 1...5) {
                    LabeledContent("Silence detection", value: "\(settings.silenceThreshold)s")
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("COGOS sends your question after this many seconds of silence.")
            }

            Section {
                Stepper(value: $settings.headUpAngle, in: 10...60, step: 5) {
                    LabeledContent("Head-up angle", value: "\(settings.headUpAngle)°")
                }
                .onChange(of: settings.headUpAngle) { new in
                    Task { await appState.proto.setHeadUpAngle(new) }
                }
                Toggle("Silent mode", isOn: $settings.silentMode)
            } header: {
                Text("Gestures")
            } footer: {
                Text("Silent mode ignores the long-press gesture so the assistant won't start listening. Also togglable via Siri.")
            }

            Section {
                Toggle("Auto brightness", isOn: $settings.autoBrightness)
                    .onChange(of: settings.autoBrightness) { _ in pushBrightness() }

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Brightness", value: "\(settings.brightness)")
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
                    .disabled(settings.autoBrightness)
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Brightness changes are sent to connected glasses.")
            }

            Section {
                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    Label("Notifications", systemImage: "bell.badge")
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
