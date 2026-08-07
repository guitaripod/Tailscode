import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The app tapping your shoulder: GNotification over the session bus, raised only for the edges
/// `ActivityWatch` finds and only while the window is not the thing being looked at. Tapping one
/// activates `app.open-session`, which lands back in the window as an ordinary open. Touched
/// only from the GLib main context, like every other piece of window state here.
final class Notifier: @unchecked Sendable {
    static let shared = Notifier()

    private var appBits: UInt = 0
    private var watch = ActivityWatch()

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

    /// Registers `app.open-session` and remembers the application, so alerts can be sent and
    /// their taps routed. The variadic C setter cannot be called from Swift; the `_value`
    /// variant with an explicit GVariant does the same job.
    func attach(
        app: UnsafeMutablePointer<AdwApplication>, onOpen: @escaping @Sendable (String) -> Void
    ) {
        let raw = UnsafeMutableRawPointer(app)
        appBits = UInt(bitPattern: raw)
        let type = g_variant_type_new("s")
        defer { g_variant_type_free(type) }
        guard let action = g_simple_action_new("open-session", type) else { return }
        let handler = Unmanaged.passRetained(OpenBox(onOpen)).toOpaque()
        let callback:
            @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = {
                _, parameter, raw in
                guard let raw, let parameter else { return }
                guard let cString = g_variant_get_string(parameter, nil) else { return }
                let sessionID = String(cString: cString)
                let open = Unmanaged<OpenBox>.fromOpaque(raw).takeUnretainedValue().open
                Gtk.onMain { open(sessionID) }
            }
        tailscode_connect(
            UnsafeMutableRawPointer(action), "activate",
            unsafeBitCast(callback, to: GCallback.self), handler)
        g_action_map_add_action(op(raw), op(UnsafeMutableRawPointer(action)))
    }

    private final class OpenBox: @unchecked Sendable {
        let open: @Sendable (String) -> Void
        init(_ open: @escaping @Sendable (String) -> Void) { self.open = open }
    }

    /// Turn-end edges across the listing, skipping the open session — its own stream reports it.
    func observeListing(_ rows: [ActivityObservation], openSessionID: String?, windowActive: Bool)
    {
        let alerts = watch.observeListing(rows, openSessionID: openSessionID)
        deliver(alerts, windowActive: windowActive)
    }

    func observeConversation(
        profileID: String, sessionID: String, title: String, state: ConversationState,
        windowActive: Bool
    ) {
        let (alerts, withdrawals) = watch.observeConversation(
            profileID: profileID, sessionID: sessionID, title: title, state: state)
        withdraw(withdrawals)
        deliver(alerts, windowActive: windowActive)
    }

    /// Raised and written down in one step: a notice nobody happened to be at the screen for is
    /// the whole event lost otherwise, so what goes to the desktop also goes to the list that
    /// keeps it until someone looks.
    private func deliver(_ alerts: [ActivityAlert], windowActive: Bool) {
        guard !windowActive else { return }
        var raised: [ActivityAlert] = []
        for alert in alerts {
            switch alert.reason {
            case .turnEnded:
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
        guard let app = application else { return }
        let notification = g_notification_new(alert.title)
        g_notification_set_body(notification, alert.body)
        if alert.reason != .turnEnded {
            g_notification_set_priority(notification, G_NOTIFICATION_PRIORITY_HIGH)
        }
        let target = g_variant_new_string(alert.sessionID)
        g_notification_set_default_action_and_target_value(
            notification, "app.open-session", target)
        g_application_send_notification(app, alert.identifier, notification)
        g_object_unref(notification.map { UnsafeMutableRawPointer($0) })
    }

    /// An approval or question notice left standing after it was answered is a lie the user
    /// taps into and finds nothing.
    func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        ActivityInbox.withdraw(identifiers)
        guard let app = application else { return }
        for identifier in identifiers {
            g_application_withdraw_notification(app, identifier)
        }
    }

    /// Proves the whole delivery path from Preferences — daemon, priority, body — which is
    /// otherwise only observable by backgrounding the window and waiting for a real turn.
    func sendTest() {
        guard let app = application else { return }
        let notification = g_notification_new("Tailscode")
        g_notification_set_body(
            notification,
            Localized.text("Notifications are working. This is what a finished turn looks like."))
        g_application_send_notification(app, "test", notification)
        g_object_unref(notification.map { UnsafeMutableRawPointer($0) })
    }

    private var application: UnsafeMutablePointer<GApplication>? {
        guard let raw = UnsafeMutableRawPointer(bitPattern: appBits) else { return nil }
        return ptr(raw)
    }
}
