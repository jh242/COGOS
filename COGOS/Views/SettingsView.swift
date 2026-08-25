import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var appState: AppState
    @State private var hermesStatus: String?
    @State private var isCheckingHermes = false
    @State private var openRouterStatus: String?
    @State private var isCheckingOpenRouter = false
    @State private var imapStatus: String?
    @State private var isCheckingIMAP = false

    var body: some View {
        Form {
            Section {
                Picker("Spoken backend", selection: $settings.spokenBackend) {
                    ForEach(SpokenBackend.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
            } header: {
                Text("Spoken assistant")
            } footer: {
                Text("Hermes keeps tools on your VPS. OpenRouter runs SwiftAgent on the phone with calendar, weather, location, IMAP mail, and web search. Long answers scroll on the glasses.")
            }

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
                SecureField("API key", text: $settings.openRouterAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                OpenRouterModelPicker()
                OpenRouterAgentModelPicker()
                Button(isCheckingOpenRouter ? "Checking..." : "Test spoken agent") {
                    testOpenRouterConnection()
                }
                .disabled(isCheckingOpenRouter || settings.makeOpenRouterAgentClient() == nil)
                if let openRouterStatus {
                    Text(openRouterStatus)
                        .foregroundStyle(.secondary)
                }
                if let error = settings.openRouterCredentialError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("OpenRouter")
            } footer: {
                Text("One key in Keychain. News digest uses a cheap free model (default \(OpenRouterClient.defaultModel)). Spoken questions use a tool-capable model (default \(OpenRouterClient.defaultAgentModel)). Override with OPENROUTER_API_KEY, OPENROUTER_MODEL, or OPENROUTER_AGENT_MODEL.")
            }

            Section {
                TextField("IMAP host", text: $settings.imapHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Port", value: $settings.imapPort, format: .number)
                    .keyboardType(.numberPad)
                TextField("Username", text: $settings.imapUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                SecureField("App-specific password", text: $settings.imapPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Mailbox", text: $settings.imapMailbox)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(isCheckingIMAP ? "Checking..." : "Test mailbox") {
                    testIMAPConnection()
                }
                .disabled(isCheckingIMAP || !settings.imapCredentials().isConfigured)
                if let imapStatus {
                    Text(imapStatus)
                        .foregroundStyle(.secondary)
                }
                if let error = settings.imapCredentialError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Mail (IMAP)")
            } footer: {
                Text("Optional. TLS IMAP so the spoken agent can search mail. iCloud default is imap.mail.me.com:993 with an app-specific password from appleid.apple.com, not your Apple ID password. Gmail: imap.gmail.com plus an app password. Password is stored in Keychain. Overrides: IMAP_HOST, IMAP_PORT, IMAP_USER, IMAP_PASSWORD, IMAP_MAILBOX.")
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

    private func testOpenRouterConnection() {
        guard let client = settings.makeOpenRouterAgentClient() else { return }
        isCheckingOpenRouter = true
        openRouterStatus = nil
        Task {
            do {
                openRouterStatus = try await client.checkConnection()
            } catch {
                openRouterStatus = error.localizedDescription
            }
            isCheckingOpenRouter = false
        }
    }

    private func testIMAPConnection() {
        let credentials = settings.imapCredentials()
        guard credentials.isConfigured else { return }
        isCheckingIMAP = true
        imapStatus = nil
        Task {
            do {
                imapStatus = try await IMAPClient(credentials: credentials).probe()
            } catch {
                imapStatus = error.localizedDescription
            }
            isCheckingIMAP = false
        }
    }
}

private struct OpenRouterModelPicker: View {
    @EnvironmentObject var settings: Settings
    @State private var liveModels: [OpenRouterModelInfo] = []
    @State private var usingCustom = false
    @State private var listError: String?

    private static let customSentinel = "__custom__"

    private var models: [OpenRouterModelInfo] {
        OpenRouterClient.pickerModels(live: liveModels, selected: usingCustom ? "" : settings.openRouterModel)
    }

    private var selection: String {
        usingCustom ? Self.customSentinel : settings.openRouterModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("News model", selection: pickerBinding) {
                ForEach(models) { model in
                    Text(model.name).tag(model.id)
                }
                Text("Custom…").tag(Self.customSentinel)
            }
            .pickerStyle(.menu)
            if usingCustom {
                TextField("provider/model:free", text: $settings.openRouterModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
            if let listError {
                Text(listError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await refreshModels() }
    }

    private var pickerBinding: Binding<String> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == Self.customSentinel {
                    usingCustom = true
                } else {
                    usingCustom = false
                    settings.openRouterModel = newValue
                }
            }
        )
    }

    private func refreshModels() async {
        do {
            let fetched = try await OpenRouterClient.listFreeModels()
            liveModels = fetched
            listError = nil
            if fetched.contains(where: { $0.id == settings.openRouterModel }) {
                usingCustom = false
            }
        } catch {
            listError = "Couldn't refresh the free-model list."
        }
    }
}

private struct OpenRouterAgentModelPicker: View {
    @EnvironmentObject var settings: Settings
    @State private var usingCustom = false

    private static let customSentinel = "__custom__"

    private var selection: String {
        usingCustom ? Self.customSentinel : settings.openRouterAgentModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Spoken model", selection: pickerBinding) {
                ForEach(OpenRouterClient.agentModelPresets, id: \.self) { slug in
                    Text(slug).tag(slug)
                }
                Text("Custom…").tag(Self.customSentinel)
            }
            .pickerStyle(.menu)
            if usingCustom {
                TextField("provider/model", text: $settings.openRouterAgentModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
        }
        .onAppear {
            usingCustom = !OpenRouterClient.agentModelPresets.contains(settings.openRouterAgentModel)
        }
    }

    private var pickerBinding: Binding<String> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == Self.customSentinel {
                    usingCustom = true
                } else {
                    usingCustom = false
                    settings.openRouterAgentModel = newValue
                }
            }
        )
    }
}
