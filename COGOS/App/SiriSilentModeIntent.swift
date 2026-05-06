import AppIntents

/// Siri tool: toggles app-level silent mode so long-press AI capture is ignored.
struct SetSilentModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Silent Mode"
    static let description = IntentDescription("Enable or disable COGOS silent mode.")
    static let openAppWhenRun = false

    @Parameter(title: "Enabled")
    var enabled: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(enabled, forKey: "app_silent_mode")
        let text = enabled ? "COGOS silent mode is on." : "COGOS silent mode is off."
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct COGOSShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: SetSilentModeIntent(),
                phrases: [
                    "Turn on silent mode in \(.applicationName)",
                    "Turn off silent mode in \(.applicationName)",
                    "Set silent mode in \(.applicationName)"
                ],
                shortTitle: "Silent Mode",
                systemImageName: "bell.slash"
            )
        ]
    }
}
