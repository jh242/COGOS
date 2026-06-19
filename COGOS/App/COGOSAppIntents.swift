import AppIntents

/// On/off state for toggle-style intents. An `AppEnum` (not `Bool`) so Siri
/// can resolve it directly from App Shortcut phrases via `\(\.$state)`.
enum ToggleState: String, AppEnum {
    case on
    case off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "State")
    static let caseDisplayRepresentations: [ToggleState: DisplayRepresentation] = [
        .on: DisplayRepresentation(title: "On"),
        .off: DisplayRepresentation(title: "Off")
    ]

    var isOn: Bool { self == .on }
}

/// Mutes the glasses long-press AI capture (app-level silent mode — distinct
/// from the G1 firmware's own silent mode telemetry on 0xF5 0x04/05).
struct SetSilentModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Silent Mode"
    static let description = IntentDescription(
        "Turn COGOS silent mode on or off. While on, the glasses long-press gesture won't start an AI session."
    )
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Turn silent mode \(\.$state)")
    }

    @Parameter(title: "State")
    var state: ToggleState

    @Dependency
    private var settings: Settings

    init() {}

    init(state: ToggleState) {
        self.state = state
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Only blocks new sessions; a capture already in progress finishes.
        settings.silentMode = state.isOn
        return .result(dialog: state.isOn
            ? "COGOS silent mode is on."
            : "COGOS silent mode is off.")
    }
}

/// Toggles auto brightness and pushes the change to connected glasses,
/// mirroring the Settings screen behavior.
struct SetAutoBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Auto Brightness"
    static let description = IntentDescription(
        "Turn auto brightness on or off on the connected glasses."
    )
    static let openAppWhenRun = false

    static var parameterSummary: some ParameterSummary {
        Summary("Turn auto brightness \(\.$state)")
    }

    @Parameter(title: "State")
    var state: ToggleState

    @Dependency
    private var appState: AppState

    init() {}

    init(state: ToggleState) {
        self.state = state
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let settings = appState.settings
        settings.autoBrightness = state.isOn
        await appState.proto.setBrightness(
            level: settings.brightness,
            auto: settings.autoBrightness
        )
        return .result(dialog: state.isOn
            ? "COGOS auto brightness is on."
            : "COGOS auto brightness is off.")
    }
}

struct COGOSShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetSilentModeIntent(),
            phrases: [
                "Turn \(\.$state) silent mode in \(.applicationName)",
                "Set silent mode \(\.$state) in \(.applicationName)",
                "Set silent mode in \(.applicationName)"
            ],
            shortTitle: "Silent Mode",
            systemImageName: "bell.slash"
        )
        AppShortcut(
            intent: SetAutoBrightnessIntent(),
            phrases: [
                "Turn \(\.$state) auto brightness in \(.applicationName)",
                "Set auto brightness \(\.$state) in \(.applicationName)",
                "Set auto brightness in \(.applicationName)"
            ],
            shortTitle: "Auto Brightness",
            systemImageName: "sun.max"
        )
    }
}
