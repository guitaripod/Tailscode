import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The app tapping your shoulder. Raised only for the edges `ActivityWatch` finds and only while
/// the window is not the thing being looked at. The desktop daemon gets a painted face, the same
/// one the chat's badge raises and captioned with the kind, or the picture the turn handed back
/// when this device already has it, plus a sound, because a themed icon cannot say which of four
/// notices a stack is. Tapping one activates the open, and an approval's own buttons answer it.
/// Touched only from the GLib main context, like every other piece of window state here.
final class Notifier: @unchecked Sendable {
    static let shared = Notifier()

    private var appBits: UInt = 0
    private var watch = ActivityWatch()
    /// The watch is read from the main loop for listings and from the conversation hub's stream
    /// task for conversations, so its state is held under a lock; delivery always hops to main.
    private let watchLock = NSLock()
    private var onOpen: (@Sendable (String) -> Void)?
    private var onDecision: (@Sendable (String, PermissionRequest, Bool, String) -> Void)?
    private var daemonID: [String: UInt32] = [:]
    private var standing: [UInt32: Standing] = [:]

    /// Everything an approval button needs to answer from outside the window.
    private struct DecisionPayload: Codable {
        let profileID: String
        let identifier: String
        let approve: Bool
        let permission: PermissionRequest
    }

    private struct Standing {
        let identifier: String
        let sessionID: String?
        let decision: DecisionPayload?
    }

    static var notifyTurnComplete: Bool {
        UserDefaults.standard.object(forKey: "pref.notify.turnComplete") as? Bool ?? true
    }

    static var notifyNeedsYou: Bool {
        UserDefaults.standard.object(forKey: "pref.notify.approvals") as? Bool ?? true
    }

    static func setNotifyTurnComplete(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "pref.notify.turnComplete")
        SettingsFile.capture()
    }

    static func setNotifyNeedsYou(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "pref.notify.approvals")
        SettingsFile.capture()
    }

    /// Registers `app.open-session` and `app.permission-decision` and remembers the application,
    /// so a daemon that cannot take an image still routes a tap, and the freedesktop daemon's own
    /// buttons land in the same handlers.
    func attach(
        app: UnsafeMutablePointer<AdwApplication>, onOpen: @escaping @Sendable (String) -> Void,
        onDecision: @escaping @Sendable (String, PermissionRequest, Bool, String) -> Void
    ) {
        self.onOpen = onOpen
        self.onDecision = onDecision
        let raw = UnsafeMutableRawPointer(app)
        appBits = UInt(bitPattern: raw)
        addStringAction(app: raw, name: "open-session") { value in
            Gtk.onMain { onOpen(value) }
        }
        addStringAction(app: raw, name: "permission-decision") { value in
            guard let payload = try? JSONDecoder().decode(
                DecisionPayload.self, from: Data(value.utf8))
            else { return }
            Gtk.onMain {
                onDecision(
                    payload.profileID, payload.permission, payload.approve, payload.identifier)
            }
        }
        tailscode_desktop_notify_listen(Self.actionInvoked, Self.noticeClosed, nil)
    }

    private static let actionInvoked: @convention(c) (
        UInt32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { id, action, _ in
        let key = action.map { String(cString: $0) } ?? ""
        Gtk.onMain { Notifier.shared.handle(id: id, action: key) }
    }

    private static let noticeClosed: @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Void = {
        id, _ in
        Gtk.onMain { Notifier.shared.forget(id: id) }
    }

    /// The daemon numbers every app's notices from one counter, so a notice that is gone must not
    /// stay here: a later tap on somebody else's notice that reuses the number would open this
    /// one's chat, and the next alert for the same chat would ask to replace a notice that no
    /// longer exists.
    private func forget(id: UInt32) {
        guard let notice = standing.removeValue(forKey: id) else { return }
        if daemonID[notice.identifier] == id { daemonID[notice.identifier] = nil }
    }

    private func handle(id: UInt32, action: String) {
        guard let notice = standing[id] else { return }
        switch action {
        case AlertCategory.approveActionID, AlertCategory.denyActionID:
            guard let decision = notice.decision else { return }
            onDecision?(
                decision.profileID, decision.permission,
                action == AlertCategory.approveActionID, decision.identifier)
        default:
            if let sessionID = notice.sessionID, !sessionID.isEmpty { onOpen?(sessionID) }
        }
    }

    private func addStringAction(
        app: UnsafeMutableRawPointer, name: String, handle: @escaping @Sendable (String) -> Void
    ) {
        let type = g_variant_type_new("s")
        defer { g_variant_type_free(type) }
        guard let action = g_simple_action_new(name, type) else { return }
        let handler = Unmanaged.passRetained(StringBox(handle)).toOpaque()
        let callback:
            @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = {
                _, parameter, raw in
                guard let raw, let parameter else { return }
                guard let cString = g_variant_get_string(parameter, nil) else { return }
                let value = String(cString: cString)
                Unmanaged<StringBox>.fromOpaque(raw).takeUnretainedValue().handle(value)
            }
        tailscode_connect(
            UnsafeMutableRawPointer(action), "activate",
            unsafeBitCast(callback, to: GCallback.self), handler)
        g_action_map_add_action(op(app), op(UnsafeMutableRawPointer(action)))
    }

    private final class StringBox: @unchecked Sendable {
        let handle: @Sendable (String) -> Void
        init(_ handle: @escaping @Sendable (String) -> Void) { self.handle = handle }
    }

    /// Turn-end edges across the listing, skipping the open session — its own stream reports it.
    func observeListing(_ rows: [ActivityObservation], openSessionID: String?, windowActive: Bool)
    {
        watchLock.lock()
        let alerts = watch.observeListing(rows, openSessionID: openSessionID)
        watchLock.unlock()
        deliver(alerts, windowActive: windowActive)
    }

    func observeConversation(
        profileID: String, sessionID: String, title: String, state: ConversationState,
        windowActive: Bool
    ) {
        watchLock.lock()
        let (alerts, withdrawals) = watch.observeConversation(
            profileID: profileID, sessionID: sessionID, title: title, state: state)
        watchLock.unlock()
        withdraw(withdrawals)
        deliver(alerts, picture: NotificationPlate.cachedPicture(in: state), windowActive: windowActive)
    }

    /// The same edges, from any thread: the conversation hub calls this once per state per
    /// conversation, and only a state that raised or withdrew something reaches the main loop,
    /// where whether a window of this app is the one being looked at is read at delivery.
    func observeConversationAnywhere(
        profileID: String, sessionID: String, title: String, state: ConversationState
    ) {
        watchLock.lock()
        let (alerts, withdrawals) = watch.observeConversation(
            profileID: profileID, sessionID: sessionID, title: title, state: state)
        watchLock.unlock()
        guard !alerts.isEmpty || !withdrawals.isEmpty else { return }
        let picture = NotificationPlate.cachedPicture(in: state)
        Gtk.onMain { [self] in
            withdraw(withdrawals)
            deliver(alerts, picture: picture, windowActive: Self.anyWindowActive)
        }
    }

    /// Raised and written down in one step: a notice nobody happened to be at the screen for is
    /// the whole event lost otherwise, so what goes to the desktop also goes to the list that
    /// keeps it until someone looks.
    private func deliver(_ alerts: [ActivityAlert], picture: Data? = nil, windowActive: Bool) {
        guard !windowActive else { return }
        var raised: [ActivityAlert] = []
        for alert in alerts {
            switch alert.reason {
            case .turnEnded, .turnFailed:
                guard Self.notifyTurnComplete else { continue }
            case .needsApproval, .needsAnswer:
                guard Self.notifyNeedsYou else { continue }
            }
            let shot = (alert.reason == .turnEnded || alert.reason == .turnFailed) ? picture : nil
            send(alert, picture: shot)
            raised.append(alert)
        }
        ActivityInbox.record(raised)
    }

    private func send(_ alert: ActivityAlert, picture: Data?) {
        let face = alert.reason.face
        let decision = alert.permission.map {
            DecisionPayload(
                profileID: alert.profileID, identifier: alert.identifier, approve: true,
                permission: $0)
        }
        let waits = alert.reason == .needsApproval || alert.reason == .needsAnswer
        publish(
            title: alert.title, body: alert.body, face: face,
            kind: NotificationPlate.kindWord(alert.reason), picture: picture,
            identifier: alert.identifier, sessionID: alert.sessionID, decision: decision,
            sound: NotificationPlate.sound(alert.reason),
            category: NotificationPlate.category(alert.reason),
            resident: waits, timeout: waits ? 0 : -1, urgency: waits ? 2 : 1)
    }

    /// A delegate run's notice, under the same switches a conversation's alerts answer to: a wait
    /// for a person is an approval, an end is a finished turn — and never while a window of this
    /// app is the active one, because the person is looking at it.
    func raiseDelegate(_ notice: DelegateNotice, identifier: String) {
        guard !Self.anyWindowActive else { return }
        switch notice.kind {
        case .asks: guard Self.notifyNeedsYou else { return }
        case .passed, .failed: guard Self.notifyTurnComplete else { return }
        }
        let face: AlertFace = notice.kind == .asks ? .needsApproval : notice.kind == .failed
            ? .turnFailed : .turnEnded
        let waits = notice.kind == .asks
        publish(
            title: notice.title, body: notice.body, face: face,
            kind: NotificationPlate.kindWord(notice.kind), picture: nil,
            identifier: identifier, sessionID: nil, decision: nil,
            sound: NotificationPlate.sound(notice.kind),
            category: NotificationPlate.category(notice.kind),
            resident: waits, timeout: waits ? 0 : -1, urgency: waits ? 2 : 1)
    }

    private func publish(
        title: String, body: String, face: AlertFace, kind: String, picture: Data?,
        identifier: String, sessionID: String?, decision: DecisionPayload?, sound: String,
        category: String, resident: Bool, timeout: Int32, urgency: UInt8
    ) {
        let image = NotificationPlate.imagePath(
            face: face, caption: kind, picture: picture,
            name: NotificationPlate.nextName(identifier))
        let words = NotificationPlate.wording(body: body)
        var actions: [String] = []
        if let sessionID, !sessionID.isEmpty {
            actions += ["default", Localized.text("Open")]
        }
        if decision != nil {
            for action in face.category.actions {
                actions += [action.id, action.title]
            }
        }
        let replaces = daemonID[identifier] ?? 0
        let id: UInt32
        if actions.isEmpty {
            id = tailscode_desktop_notify(
                title, words.markup, words.plain, image, sound, category, DesktopIntegration.appID,
                urgency, resident ? 1 : 0, timeout, replaces, nil, 0)
        } else {
            id = notificationCStrings(actions) { pointers in
                tailscode_desktop_notify(
                    title, words.markup, words.plain, image, sound, category,
                    DesktopIntegration.appID, urgency, resident ? 1 : 0, timeout, replaces,
                    pointers, Int32(actions.count))
            }
        }
        if id != 0 {
            if replaces != 0 { standing[replaces] = nil }
            daemonID[identifier] = id
            standing[id] = Standing(
                identifier: identifier, sessionID: sessionID, decision: decision)
            if let app = application { g_application_withdraw_notification(app, identifier) }
            return
        }
        sendFallback(
            title: title, body: body, face: face, identifier: identifier, sessionID: sessionID,
            decision: decision, imagePath: image, urgent: resident)
    }

    private func sendFallback(
        title: String, body: String, face: AlertFace, identifier: String, sessionID: String?,
        decision: DecisionPayload?, imagePath: String?, urgent: Bool
    ) {
        guard let app = application else { return }
        if let previous = daemonID.removeValue(forKey: identifier) {
            standing[previous] = nil
            tailscode_desktop_notify_close(previous)
        }
        let notification = g_notification_new(title)
        g_notification_set_body(notification, body)
        if let imagePath, let file = g_file_new_for_path(imagePath),
            let icon = g_file_icon_new(file)
        {
            g_notification_set_icon(notification, op(UnsafeMutableRawPointer(icon)))
            g_object_unref(UnsafeMutableRawPointer(icon))
            g_object_unref(UnsafeMutableRawPointer(file))
        } else if let icon = g_themed_icon_new(face.themedIcon) {
            g_notification_set_icon(notification, op(UnsafeMutableRawPointer(icon)))
            g_object_unref(UnsafeMutableRawPointer(icon))
        }
        if urgent { g_notification_set_priority(notification, G_NOTIFICATION_PRIORITY_HIGH) }
        if let sessionID, !sessionID.isEmpty {
            g_notification_set_default_action_and_target_value(
                notification, "app.open-session", g_variant_new_string(sessionID))
        }
        if let decision {
            for action in face.category.actions {
                let payload = DecisionPayload(
                    profileID: decision.profileID, identifier: decision.identifier,
                    approve: action.id == AlertCategory.approveActionID,
                    permission: decision.permission)
                guard let encoded = try? JSONEncoder().encode(payload) else { continue }
                g_notification_add_button_with_target_value(
                    notification, action.title, "app.permission-decision",
                    g_variant_new_string(String(decoding: encoded, as: UTF8.self)))
            }
        }
        g_application_send_notification(app, identifier, notification)
        g_object_unref(notification.map { UnsafeMutableRawPointer($0) })
    }

    private static var anyWindowActive: Bool {
        guard let list = gtk_window_list_toplevels() else { return false }
        defer { g_list_free(list) }
        var node: UnsafeMutablePointer<GList>? = list
        while let current = node {
            if let raw = current.pointee.data, gtk_window_is_active(ptr(raw)) != 0 { return true }
            node = current.pointee.next
        }
        return false
    }

    /// An approval or question notice left standing after it was answered is a lie the user
    /// taps into and finds nothing.
    func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        ActivityInbox.withdraw(identifiers)
        for identifier in identifiers {
            if let id = daemonID.removeValue(forKey: identifier) {
                standing[id] = nil
                tailscode_desktop_notify_close(id)
            }
        }
        guard let app = application else { return }
        for identifier in identifiers {
            g_application_withdraw_notification(app, identifier)
        }
    }

    /// Proves the whole delivery path from Preferences — daemon, face, sound, body — which is
    /// otherwise only observable by backgrounding the window and waiting for a real turn.
    func sendTest() {
        publish(
            title: "Tailscode",
            body: Localized.text(
                "Notifications are working. This is what a finished turn looks like."),
            face: .turnEnded, kind: NotificationPlate.kindWord(ActivityAlert.Reason.turnEnded),
            picture: nil, identifier: "test", sessionID: nil, decision: nil,
            sound: NotificationPlate.sound(ActivityAlert.Reason.turnEnded),
            category: NotificationPlate.category(ActivityAlert.Reason.turnEnded),
            resident: false, timeout: -1, urgency: 1)
    }

    private var application: UnsafeMutablePointer<GApplication>? {
        guard let raw = UnsafeMutableRawPointer(bitPattern: appBits) else { return nil }
        return ptr(raw)
    }
}
