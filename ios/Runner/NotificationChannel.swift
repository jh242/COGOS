import Flutter
import UserNotifications

/// Provides recent notification snippets via a Flutter MethodChannel.
/// Maintains an in-memory buffer of the last 3 delivered notifications.
class NotificationChannel: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationChannel()

    private var recentNotifications: [String] = []
    private let maxBuffer = 3

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "method.notifications",
            binaryMessenger: messenger
        )

        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }

            switch call.method {
            case "getRecentNotifications":
                result(self.recentNotifications)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // Set ourselves as the notification center delegate to capture
        // delivered notifications.
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        addNotification(notification)
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        addNotification(response.notification)
        completionHandler()
    }

    private func addNotification(_ notification: UNNotification) {
        let content = notification.request.content
        let app = content.threadIdentifier.isEmpty
            ? content.categoryIdentifier
            : content.threadIdentifier
        let snippet = app.isEmpty
            ? content.body
            : "\(app): \(content.body)"

        recentNotifications.insert(snippet, at: 0)
        if recentNotifications.count > maxBuffer {
            recentNotifications.removeLast()
        }
    }
}
