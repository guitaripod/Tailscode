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
            let env = ProcessInfo.processInfo.environment
            guard env["TAILSCODE_AUTOSEND"] == nil, env["TAILSCODE_OPEN_SESSION"] == nil
            else { return }
        #endif
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// An approval or question notification describes a request that stops
    /// existing the moment it is answered — on the phone, on another device, or
    /// by the agent timing out. Left in Notification Center it becomes a lie
    /// the user taps into and finds nothing, so every request notification is
    /// withdrawn once its request is no longer pending.
    static func withdraw(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
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
    /// (app switcher, banner pull-down) get no presentation and vanish. Remote
    /// pushes arriving while the app is actively foregrounded (the chat already
    /// on screen) go to the list silently instead of bannering over it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.trigger is UNPushNotificationTrigger else {
            return [.banner, .list, .sound]
        }
        let isActive = await MainActor.run { UIApplication.shared.applicationState == .active }
        return isActive ? [.list] : [.banner, .list, .sound]
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
