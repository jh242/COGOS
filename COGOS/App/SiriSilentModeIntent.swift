import AppIntents

/// A general Siri-callable tool intent surface for COGOS.
struct RunCOGOSToolIntent: AppIntent {
    static let title: LocalizedStringResource = "Run COGOS Tool"
    static let description = IntentDescription("Run a COGOS tool action from Siri or Shortcuts.")
    static let openAppWhenRun = false

    @Parameter(title: "Tool")
    var tool: COGOSTool

    @Parameter(title: "Enabled")
    var enabled: Bool?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch tool {
        case .silentMode:
            let isEnabled = enabled ?? true
            UserDefaults.standard.set(isEnabled, forKey: "app_silent_mode")
            let text = isEnabled ? "COGOS silent mode is on." : "COGOS silent mode is off."
            return .result(dialog: IntentDialog(stringLiteral: text))

        case .autoBrightness:
            let isEnabled = enabled ?? true
            UserDefaults.standard.set(isEnabled, forKey: "display_auto_brightness")
            let text = isEnabled ? "COGOS auto brightness is on." : "COGOS auto brightness is off."
            return .result(dialog: IntentDialog(stringLiteral: text))
        }
    }
}

enum COGOSTool: String, AppEnum {
    case silentMode
    case autoBrightness

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "COGOS Tool")
    static let caseDisplayRepresentations: [COGOSTool: DisplayRepresentation] = [
        .silentMode: DisplayRepresentation(title: "Silent Mode"),
        .autoBrightness: DisplayRepresentation(title: "Auto Brightness")
    ]
}

struct COGOSShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: RunCOGOSToolIntent(tool: .silentMode),
                phrases: [
                    "Turn on silent mode in \(.applicationName)",
                    "Turn off silent mode in \(.applicationName)",
                    "Set silent mode in \(.applicationName)"
                ],
                shortTitle: "Silent Mode",
                systemImageName: "bell.slash"
            ),
            AppShortcut(
                intent: RunCOGOSToolIntent(tool: .autoBrightness),
                phrases: [
                    "Turn on auto brightness in \(.applicationName)",
                    "Turn off auto brightness in \(.applicationName)",
                    "Set auto brightness in \(.applicationName)"
                ],
                shortTitle: "Auto Brightness",
                systemImageName: "sun.max"
            )
        ]
    }
}
