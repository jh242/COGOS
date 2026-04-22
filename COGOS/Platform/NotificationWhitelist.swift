import Foundation

/// Persisted ANCS app whitelist, pushed to glasses via Proto.
@MainActor
final class NotificationWhitelist: ObservableObject {
    private let key = "notification_whitelist"
    private let defaults = UserDefaults.standard

    @Published var appIds: [String] = []

    init() {
        if let stored = defaults.string(forKey: key),
           let data = stored.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            appIds = arr
        }
    }

    func set(_ ids: [String]) {
        appIds = ids
        if let data = try? JSONSerialization.data(withJSONObject: ids),
           let s = String(data: data, encoding: .utf8) {
            defaults.set(s, forKey: key)
        }
    }

    func pushToGlasses(proto: Proto) async {
        let model = NotifyWhitelistModel(apps: appIds.map { NotifyAppModel(id: $0, name: $0) })
        await proto.sendNewAppWhiteListJson(model.jsonString())
    }
}
