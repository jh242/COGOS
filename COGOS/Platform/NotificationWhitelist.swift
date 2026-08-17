import Foundation

/// Persisted ANCS app whitelist, pushed to glasses via Proto.
@MainActor
final class NotificationWhitelist: ObservableObject {
    private enum Key {
        static let appIds = "notification_whitelist"
        static let calendar = "notification_calendar_enabled"
        static let calls = "notification_calls_enabled"
        static let messages = "notification_messages_enabled"
        static let mail = "notification_mail_enabled"
        static let autoDisplay = "notification_auto_display_enabled"
        static let displayTimeout = "notification_display_timeout_seconds"
    }

    private let defaults = UserDefaults.standard

    @Published var appIds: [String] = []
    @Published var calendarEnabled: Bool { didSet { defaults.set(calendarEnabled, forKey: Key.calendar) } }
    @Published var callsEnabled: Bool { didSet { defaults.set(callsEnabled, forKey: Key.calls) } }
    @Published var messagesEnabled: Bool { didSet { defaults.set(messagesEnabled, forKey: Key.messages) } }
    @Published var mailEnabled: Bool { didSet { defaults.set(mailEnabled, forKey: Key.mail) } }
    @Published var autoDisplayEnabled: Bool { didSet { defaults.set(autoDisplayEnabled, forKey: Key.autoDisplay) } }
    @Published var displayTimeoutSeconds: Int {
        didSet {
            let clamped = max(1, min(30, displayTimeoutSeconds))
            if clamped != displayTimeoutSeconds {
                displayTimeoutSeconds = clamped
                return
            }
            defaults.set(displayTimeoutSeconds, forKey: Key.displayTimeout)
        }
    }
    @Published private(set) var isSyncing = false
    @Published private(set) var syncStatus: String?

    init() {
        self.calendarEnabled = Self.bool(defaults, key: Key.calendar, fallback: true)
        self.callsEnabled = Self.bool(defaults, key: Key.calls, fallback: true)
        self.messagesEnabled = Self.bool(defaults, key: Key.messages, fallback: true)
        self.mailEnabled = Self.bool(defaults, key: Key.mail, fallback: true)
        self.autoDisplayEnabled = Self.bool(defaults, key: Key.autoDisplay, fallback: true)
        let storedTimeout = defaults.object(forKey: Key.displayTimeout) as? Int ?? 8
        self.displayTimeoutSeconds = max(1, min(30, storedTimeout))

        if let stored = defaults.string(forKey: Key.appIds),
           let data = stored.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            appIds = arr
        }
    }

    func set(_ ids: [String]) {
        let normalized = Array(Set(ids.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        appIds = normalized
        if let data = try? JSONSerialization.data(withJSONObject: normalized),
           let s = String(data: data, encoding: .utf8) {
            defaults.set(s, forKey: Key.appIds)
        }
    }

    @discardableResult
    func pushToGlasses(proto: Proto) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        syncStatus = "Syncing…"
        defer { isSyncing = false }

        let model = NotifyWhitelistModel(
            apps: appIds.map { NotifyAppModel(id: $0, name: $0) },
            calendarEnabled: calendarEnabled,
            callsEnabled: callsEnabled,
            messagesEnabled: messagesEnabled,
            mailEnabled: mailEnabled
        )
        let whitelistOK = await proto.sendNewAppWhiteListJson(model.jsonString())
        var displayOK = false
        if whitelistOK {
            displayOK = await proto.setNotificationAutoDisplay(
                enabled: autoDisplayEnabled,
                timeoutSeconds: displayTimeoutSeconds
            )
        }
        let success = whitelistOK && displayOK
        syncStatus = success ? "Synced to glasses" : "Sync failed — reconnect and retry"
        return success
    }

    private static func bool(_ defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}
