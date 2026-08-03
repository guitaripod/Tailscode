import AppKit
import CodingAgentKit
import TailscodeCore
import UserNotifications

/// The app tapping your shoulder: UNUserNotificationCenter, raised only for the edges
/// `ActivityWatch` finds and only while the app is not the thing being looked at. Tapping one
/// lands back in the window as an ordinary open of the session it names.
@MainActor
final class MacNotifier: NSObject {
    static let shared = MacNotifier()

    var onOpen: ((String) -> Void)?
    private var watch = ActivityWatch()
    private var authorizationAsked = false

    static var notifyTurnComplete: Bool {
        UserDefaults.standard.object(forKey: "pref.notify.turnComplete") as? Bool ?? true
    }

    static var notifyNeedsYou: Bool {
        UserDefaults.standard.object(forKey: "pref.notify.approvals") as? Bool ?? true
    }

    static func setNotifyTurnComplete(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "pref.notify.turnComplete")
    }

    static func setNotifyNeedsYou(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "pref.notify.approvals")
    }

    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Turn-end edges across the listing, skipping the open session — its own stream reports it.
    func observeListing(_ rows: [ActivityObservation], openSessionID: String?) {
        deliver(watch.observeListing(rows, openSessionID: openSessionID))
    }

    func observeConversation(
        profileID: String, sessionID: String, title: String, state: ConversationState
    ) {
        let (alerts, withdrawals) = watch.observeConversation(
            profileID: profileID, sessionID: sessionID, title: title, state: state)
        if !withdrawals.isEmpty {
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: withdrawals)
            center.removePendingNotificationRequests(withIdentifiers: withdrawals)
        }
        deliver(alerts)
    }

    private func deliver(_ alerts: [ActivityAlert]) {
        guard !NSApp.isActive else { return }
        for alert in alerts {
            switch alert.reason {
            case .turnEnded:
                guard Self.notifyTurnComplete else { continue }
            case .needsApproval, .needsAnswer:
                guard Self.notifyNeedsYou else { continue }
            }
            send(alert)
        }
    }

    private func send(_ alert: ActivityAlert) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.userInfo = ["sessionID": alert.sessionID]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
    }

    /// The system prompt appears the first time something is actually worth saying — never at
    /// launch, and never in a headless run.
    private func requestAuthorizationIfNeeded() {
        guard !authorizationAsked else { return }
        authorizationAsked = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Proves the whole delivery path from Preferences — authorization, banner, sound — which is
    /// otherwise only observable by backgrounding the app and waiting for a real turn. The short
    /// delay is what lets it banner over the foreground app.
    func sendTest() {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Tailscode"
        content.body = Localized.text(
            "Notifications are working. This is what a finished turn looks like.")
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "test:\(UUID().uuidString)", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
    }
}

extension MacNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        guard let sessionID else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            MacNotifier.shared.onOpen?(sessionID)
        }
    }
}
