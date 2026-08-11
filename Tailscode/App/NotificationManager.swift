import CodingAgentKit
import TailscodeCore
import UIKit
import UserNotifications

/// Local notifications for agent activity that finishes while the app isn't in the foreground —
/// so a phone user can send a long task, leave, and get pinged when it's done or needs approval.
@MainActor
enum NotificationManager {
    /// Every alert the app raises itself, each behind its own preference so a
    /// user who only wants approval pings isn't opted into the rest.
    enum Kind {
        case turnComplete, approval, question, usage

        var isEnabled: Bool {
            switch self {
            case .turnComplete: return AppPreferences.notifyTurnComplete
            case .approval, .question: return AppPreferences.notifyApprovals
            case .usage: return AppPreferences.notifyUsageWarnings
            }
        }

        var face: AlertFace {
            switch self {
            case .turnComplete: return .turnEnded
            case .approval: return .needsApproval
            case .question: return .needsAnswer
            case .usage: return .usage
            }
        }

        /// Where a tap lands when the notice is not about one conversation. A quota warning names
        /// no session, and a notification whose tap does nothing at all is worse than none — the
        /// thing it is about has a screen, so it opens it.
        var route: String? {
            switch self {
            case .usage: return "usage"
            case .turnComplete, .approval, .question: return nil
            }
        }
    }

    /// Tells the system what each kind of notification is and which buttons it carries, from the
    /// same catalog every client reads — an approval arrives wearing Approve and Deny, everything
    /// else answers only to being opened.
    static func registerCategories() {
        let categories = AlertCategory.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: category.actions.map { action in
                    UNNotificationAction(
                        identifier: action.id, title: action.title,
                        options: action.isDestructive ? [.destructive] : [])
                },
                intentIdentifiers: [])
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }

    static func requestAuthorizationIfNeeded() {
        guard !CommandLine.arguments.contains("--demo"),
            !CommandLine.arguments.contains("--usage")
        else { return }
        #if DEBUG
            let env = ProcessInfo.processInfo.environment
            guard env["TAILSCODE_AUTOSEND"] == nil, env["TAILSCODE_OPEN_SESSION"] == nil,
                env["TAILSCODE_NEW_CHAT"] == nil
            else { return }
        #endif
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The explicit ask from the Settings row, for a user who reached the app's
    /// notification controls without ever having seen the system prompt.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        AppLogger.lifecycle.info("notification authorization requested from settings")
        return (try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
    }

    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// An approval or question notification describes a request that stops
    /// existing the moment it is answered — on the phone, on another device, or
    /// by the agent timing out. Left in Notification Center it becomes a lie
    /// the user taps into and finds nothing, so every request notification is
    /// withdrawn once its request is no longer pending.
    static func withdraw(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        ActivityInbox.withdraw(identifiers)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// - Parameters:
    ///   - permission: the request an approval is about, carried whole so the notification's own
    ///     Approve and Deny buttons can answer it without opening the app.
    ///   - activity: what happened in the session, when the notice is about one. A notice raised
    ///     is also a notice that can be missed — a banner lasts seconds whether or not anybody was
    ///     looking — so anything named here is written into `ActivityInbox` by the same decision
    ///     that banners it: suppressed by preference means never raised, so never missed.
    static func notify(
        kind: Kind, title: String, body: String, identifier: String, sessionID: String? = nil,
        profileID: String? = nil, permission: PermissionRequest? = nil,
        activity: MissedActivity.Reason? = nil
    ) {
        guard kind.isEnabled else {
            AppLogger.lifecycle.info("notification suppressed by preference: \(identifier)")
            return
        }
        guard UIApplication.shared.applicationState != .active else { return }
        if let activity, let sessionID {
            ActivityInbox.record([
                MissedActivity(
                    identifier: identifier, profileID: profileID ?? "", sessionID: sessionID,
                    title: title, body: body, reason: activity)
            ])
        }
        let face = kind.face
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = face.category.rawValue
        var userInfo: [String: Any] = [:]
        if let sessionID {
            userInfo["sessionID"] = sessionID
            content.threadIdentifier = sessionID
        }
        if let profileID { userInfo["profileID"] = profileID }
        if let route = kind.route { userInfo["route"] = route }
        if let permission, let encoded = try? JSONEncoder().encode(permission) {
            userInfo["permission"] = String(decoding: encoded, as: UTF8.self)
        }
        content.userInfo = userInfo
        if let attachment = faceAttachment(face) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The kind's face as a thumbnail, so a glance at a stack of banners separates the finished
    /// from the waiting before a word is read. Written fresh per notification because the system
    /// takes ownership of the file it is handed.
    private static func faceAttachment(_ face: AlertFace) -> UNNotificationAttachment? {
        let image = faceImage(face)
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alert-face-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "face", url: url)
        } catch {
            AppLogger.lifecycle.error("notification face attachment failed: \(error)")
            return nil
        }
    }

    private static func faceImage(_ face: AlertFace) -> UIImage {
        let side: CGFloat = 256
        let size = CGSize(width: side, height: side)
        let tint = face.tone.color
        return UIGraphicsImageRenderer(size: size).image { _ in
            tint.withAlphaComponent(0.18).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.42, weight: .semibold)
            guard
                let symbol = UIImage(systemName: face.symbol, withConfiguration: config)?
                    .withTintColor(tint, renderingMode: .alwaysOriginal)
            else { return }
            let rect = CGRect(
                x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: rect)
        }
    }

    /// Proves the whole delivery path end to end from Settings — authorization,
    /// presentation, sound — which is otherwise only observable by waiting for a
    /// real turn to finish while the app is backgrounded. The short delay is what
    /// lets it banner over a foreground app.
    static func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "Tailscode"
        content.body = String(
            localized: "Notifications are working. This is what a finished turn looks like.")
        content.sound = .default
        content.categoryIdentifier = AlertCategory.turn.rawValue
        if let attachment = faceAttachment(.turnEnded) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(
            identifier: "test:\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        UNUserNotificationCenter.current().add(request)
        AppLogger.lifecycle.info("test notification scheduled")
    }
}

/// Routes notification taps to the session they concern, and answers an approval's own buttons
/// without ever opening the app — the decision travels straight to the server the request came
/// from.
///
/// Both delegate methods are implemented in their completion-handler form, never as `async`: the
/// async variants hand their compiler-generated completion to whatever concurrency thread the
/// method resumed on, and UIKit runs its state-restoration snapshot synchronously inside that
/// completion when a tap is foregrounding the app — main-thread-only work that asserts and aborts
/// on any other thread. The completion must be invoked from the main thread, after the work.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationRouter()

    /// Without this, notifications posted while the app is foreground-inactive
    /// (app switcher, banner pull-down) get no presentation and vanish. Remote
    /// pushes arriving while the app is actively foregrounded (the chat already
    /// on screen) go to the list silently instead of bannering over it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isPush = notification.request.trigger is UNPushNotificationTrigger
        nonisolated(unsafe) let complete = completionHandler
        DispatchQueue.main.async {
            guard isPush else {
                complete([.banner, .list, .sound])
                return
            }
            let isActive = UIApplication.shared.applicationState == .active
            complete(isActive ? [.list] : [.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let payload = content.userInfo["permission"] as? String
        let profileID = content.userInfo["profileID"] as? String
        let sessionID = content.userInfo["sessionID"] as? String
        let route = content.userInfo["route"] as? String
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        nonisolated(unsafe) let complete = completionHandler
        Task { @MainActor in
            switch action {
            case AlertCategory.approveActionID, AlertCategory.denyActionID:
                await Self.decide(
                    payload: payload, profileID: profileID, identifier: identifier,
                    approve: action == AlertCategory.approveActionID)
            default:
                if let url = Self.destination(route: route, sessionID: sessionID) {
                    PendingRoute.deliver(url)
                }
            }
            complete()
        }
    }

    /// A notice about one conversation opens it; one about the account opens the screen it is
    /// about. Anything else lands on whatever the app was showing, which is what a tap with
    /// nothing to say means.
    private static func destination(route: String?, sessionID: String?) -> URL? {
        if let route, let url = URL(string: "tailscode://\(route)") { return url }
        guard let sessionID, !sessionID.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) ?? sessionID
        return URL(string: "tailscode://session/\(encoded)")
    }

    /// The lock-screen answer: rebuild the backend the request came from and respond by name.
    /// Failure leaves the request standing — the inbox entry and the in-app banner still know
    /// about it, and resolving it from inside the chat stays possible.
    @MainActor
    private static func decide(
        payload: String?, profileID: String?, identifier: String, approve: Bool
    ) async {
        guard let payload,
            let permission = try? JSONDecoder().decode(
                PermissionRequest.self, from: Data(payload.utf8)),
            let profileID,
            let profile = ConnectionController.shared.profiles.first(where: { $0.id == profileID }),
            let backend = ConnectionController.shared.makeBackend(for: profile)
        else {
            AppLogger.session.error("notification decision: no backend for stored payload")
            return
        }
        do {
            try await backend.respond(to: permission, decision: approve ? .once : .reject)
            NotificationManager.withdraw(identifiers: [identifier])
            AppLogger.session.info(
                "notification decision \(approve ? "approved" : "denied"): \(permission.id)")
        } catch {
            AppLogger.session.error("notification decision failed: \(error)")
        }
    }
}
