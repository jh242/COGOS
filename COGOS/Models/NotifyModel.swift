import Foundation

/// App whitelist model for ANCS notification filtering.
/// Ports `lib/models/notify_model.dart`.
struct NotifyAppModel: Codable, Hashable {
    let id: String
    let name: String
}

struct NotifyWhitelistModel: Codable {
    let apps: [NotifyAppModel]
    let calendarEnabled: Bool
    let callsEnabled: Bool
    let messagesEnabled: Bool
    let mailEnabled: Bool

    init(
        apps: [NotifyAppModel],
        calendarEnabled: Bool = true,
        callsEnabled: Bool = true,
        messagesEnabled: Bool = true,
        mailEnabled: Bool = true
    ) {
        self.apps = apps
        self.calendarEnabled = calendarEnabled
        self.callsEnabled = callsEnabled
        self.messagesEnabled = messagesEnabled
        self.mailEnabled = mailEnabled
    }

    /// Serialized shape expected by the glasses firmware.
    var wireDict: [String: Any] {
        [
            "calendar_enable": calendarEnabled,
            "call_enable": callsEnabled,
            "msg_enable": messagesEnabled,
            "ios_mail_enable": mailEnabled,
            "app": [
                "list": apps.map { ["id": $0.id, "name": $0.name] },
                // This is the firmware's app-notification inbox switch, not
                // merely a "list is populated" flag. Keep it enabled even
                // with an empty list so ANCS notifications are retained for
                // the unread counter and dashboard left-tap viewer.
                "enable": true
            ]
        ]
    }

    func jsonString() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: wireDict) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
