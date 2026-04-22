import Foundation

/// App whitelist model for ANCS notification filtering.
/// Ports `lib/models/notify_model.dart`.
struct NotifyAppModel: Codable, Hashable {
    let id: String
    let name: String
}

struct NotifyWhitelistModel: Codable {
    let apps: [NotifyAppModel]

    /// Serialized shape expected by the glasses firmware.
    var wireDict: [String: Any] {
        [
            "calendar_enable": false,
            "call_enable": false,
            "msg_enable": false,
            "ios_mail_enable": false,
            "app": [
                "list": apps.map { ["id": $0.id, "name": $0.name] },
                "enable": true
            ]
        ]
    }

    func jsonString() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: wireDict) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
