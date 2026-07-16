import UIKit
import UserNotifications

/// Local notifications for agent activity that finishes while the app isn't in the foreground —
/// so a phone user can send a long task, leave, and get pinged when it's done or needs approval.
@MainActor
enum NotificationManager {
    static func requestAuthorizationIfNeeded() {
        guard !CommandLine.arguments.contains("--demo"),
            !CommandLine.arguments.contains("--usage")
        else { return }
        #if DEBUG
            guard ProcessInfo.processInfo.environment["TAILSCODE_AUTOSEND"] == nil else { return }
        #endif
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    static func notify(title: String, body: String, identifier: String, sessionID: String? = nil) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let sessionID { content.userInfo = ["sessionID": sessionID] }
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Routes notification taps to the session they concern.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationRouter()

    /// Without this, notifications posted while the app is foreground-inactive
    /// (app switcher, banner pull-down) get no presentation and vanish.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        if let sessionID, let url = URL(string: "tailscode://session/\(sessionID)") {
            Task { @MainActor in
                let scene = UIApplication.shared.connectedScenes
                    .compactMap { $0.delegate as? SceneDelegate }.first
                scene?.routeDeepLink(url)
            }
        }
        completionHandler()
    }
}
