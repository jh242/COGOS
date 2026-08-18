import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var appState: AppState
    @State private var hermesStatus: String?
    @State private var isCheckingHermes = false

    var body: some View {
        Form {
            Section {
                TextField("Hermes API URL", text: $settings.hermesURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Access token", text: $settings.hermesToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(isCheckingHermes ? "Checking..." : "Test connection") {
                    testHermesConnection()
                }
                .disabled(isCheckingHermes || settings.makeHermesClient() == nil)
                if let hermesStatus {
                    Text(hermesStatus)
                        .foregroundStyle(.secondary)
                }
                if let error = settings.hermesCredentialError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Hermes Agent")
            } footer: {
                Text("Requires an HTTPS Hermes API server. The access token is stored in Keychain; model, memory, and tools are controlled by Hermes.")
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

            Section(header: Text("Context")) {
                NavigationLink("Context Providers") {
                    ContextProvidersSettingsView()
                }
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

    private func testHermesConnection() {
        guard let client = settings.makeHermesClient() else { return }
        isCheckingHermes = true
        hermesStatus = nil
        Task {
            do {
                let report = try await client.checkConnection()
                hermesStatus = report.statusText
            } catch {
                hermesStatus = error.localizedDescription
            }
            isCheckingHermes = false
        }
    }
}
