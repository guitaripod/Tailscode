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
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Set(Self.categories))
    }

    /// The kinds this app raises and the buttons each carries, from the same catalog every client
    /// reads — an approval arrives wearing Approve and Deny, everything else answers only to being
    /// opened.
    private static var categories: [UNNotificationCategory] {
        AlertCategory.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: category.actions.map { action in
                    UNNotificationAction(
                        identifier: action.id, title: action.title,
                        options: action.isDestructive ? [.destructive] : [])
                },
                intentIdentifiers: [])
        }
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
            ActivityInbox.withdraw(withdrawals)
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: withdrawals)
            center.removePendingNotificationRequests(withIdentifiers: withdrawals)
        }
        deliver(alerts)
    }

    /// Raised and written down in one step: a notice nobody happened to be at the screen for is
    /// the whole event lost otherwise, so what banners also goes to the list that keeps it until
    /// someone looks.
    private func deliver(_ alerts: [ActivityAlert]) {
        guard !NSApp.isActive else { return }
        var raised: [ActivityAlert] = []
        for alert in alerts {
            switch alert.reason {
            case .turnEnded, .turnFailed:
                guard Self.notifyTurnComplete else { continue }
            case .needsApproval, .needsAnswer:
                guard Self.notifyNeedsYou else { continue }
            }
            send(alert)
            raised.append(alert)
        }
        ActivityInbox.record(raised)
    }

    private func send(_ alert: ActivityAlert) {
        requestAuthorizationIfNeeded()
        let face = alert.reason.face
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.categoryIdentifier = face.category.rawValue
        content.threadIdentifier = alert.sessionID
        var userInfo: [String: Any] = [
            "sessionID": alert.sessionID, "profileID": alert.profileID,
        ]
        if let permission = alert.permission,
            let encoded = try? JSONEncoder().encode(permission)
        {
            userInfo["permission"] = String(decoding: encoded, as: UTF8.self)
        }
        content.userInfo = userInfo
        if let attachment = Self.faceAttachment(face) {
            content.attachments = [attachment]
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
    }

    /// The alert's face as a thumbnail, so a glance at a stack of banners separates the finished
    /// from the waiting before a word is read. Written fresh per notification because the system
    /// takes ownership of the file it is handed.
    private static func faceAttachment(_ face: AlertFace) -> UNNotificationAttachment? {
        let image = faceImage(face)
        guard let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alert-face-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "face", url: url)
        } catch {
            return nil
        }
    }

    private static func faceImage(_ face: AlertFace) -> NSImage {
        let side: CGFloat = 256
        let tint = face.tone.color
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            tint.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let config = NSImage.SymbolConfiguration(pointSize: side * 0.42, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            guard
                let symbol = NSImage(
                    systemSymbolName: face.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
            else { return true }
            let size = symbol.size
            symbol.draw(
                in: NSRect(
                    x: (side - size.width) / 2, y: (side - size.height) / 2,
                    width: size.width, height: size.height))
            return true
        }
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
    ///
    /// The one control whose job is to report whether the path works has to report a refusal too:
    /// a request added while macOS is denying this app is dropped in silence, which is the one
    /// answer this button must never give. So it asks first, and says where the switch is.
    func sendTest() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                let allowed = settings.authorizationStatus != .denied
                Task { @MainActor in allowed ? Self.scheduleTest() : Self.reportRefusal() }
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                granted, _ in
                Task { @MainActor in granted ? Self.scheduleTest() : Self.reportRefusal() }
            }
        }
    }

    private static func scheduleTest() {
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

    private static func reportRefusal() {
        MacDialogs.confirm(
            on: NSApp.keyWindow,
            title: Localized.text("macOS is not delivering notifications for Tailscode"),
            body: Localized.text(
                "Nothing this app raises will reach you until notifications are turned on for it "
                    + "in System Settings."),
            confirmLabel: Localized.text("Open Settings"), destructive: false
        ) {
            guard
                let url = URL(
                    string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

/// Both delegate methods take the completion-handler form, never `async`: the async variants
/// hand their compiler-generated completion to whatever concurrency thread the method resumed
/// on, and the system does app-lifecycle work inside that completion — the shape that crashed
/// the iOS client mid-foreground. The completion is invoked from the main thread, after the work.
extension MacNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        nonisolated(unsafe) let complete = completionHandler
        DispatchQueue.main.async { complete([.banner, .list, .sound]) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let payload = content.userInfo["permission"] as? String
        let profileID = content.userInfo["profileID"] as? String
        let sessionID = content.userInfo["sessionID"] as? String
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
                if let sessionID {
                    NSApp.activate(ignoringOtherApps: true)
                    MacNotifier.shared.onOpen?(sessionID)
                }
            }
            complete()
        }
    }

    /// The banner's own answer: rebuild the backend the request came from and respond by name,
    /// without pulling the window forward. Failure leaves the request standing — the inbox entry
    /// still knows about it and the chat can resolve it.
    private static func decide(
        payload: String?, profileID: String?, identifier: String, approve: Bool
    ) async {
        guard let payload,
            let permission = try? JSONDecoder().decode(
                PermissionRequest.self, from: Data(payload.utf8)),
            let profileID
        else { return }
        let backend = await MainActor.run { () -> (any CodingAgentBackend)? in
            guard
                let profile = ServerDirectory.shared.profiles.first(where: { $0.id == profileID })
            else { return nil }
            return ServerDirectory.shared.backend(for: profile)
        }
        guard let backend else { return }
        do {
            try await backend.respond(to: permission, decision: approve ? .once : .reject)
            ActivityInbox.withdraw([identifier])
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        } catch {
            NSLog("notification decision failed: %@", String(describing: error))
        }
    }
}
