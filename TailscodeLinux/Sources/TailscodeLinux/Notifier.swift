import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The app tapping your shoulder. Raised only for the edges `ActivityWatch` finds and only while
/// the window is not the thing being looked at. The desktop daemon gets a painted face, the same
/// one the chat's badge raises, or the picture the turn handed back when this device already has
/// it, a sound, and words worth reading before the window is: how long the turn took and how much
/// it did, the first of what it answered, the command that wants approving, the question asked.
/// What can be answered from the notice is: an approval's own buttons, a question's options, a
/// reply that starts the next turn, and a tap that opens the chat.
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
    private var onReply: (@Sendable (String, String, String, String) -> Void)?
    private var onAnswer: (@Sendable (String, QuestionRequest, [[String]], String) -> Void)?
    private var daemonID: [String: UInt32] = [:]
    private var standing: [UInt32: Standing] = [:]
    private let serversLock = NSLock()
    private var serverNames: [String: String] = [:]

    /// Everything an approval button needs to answer from outside the window.
    private struct DecisionPayload: Codable {
        let profileID: String
        let identifier: String
        let approve: Bool
        let permission: PermissionRequest
    }

    /// What a notice that is still up can be answered with, kept by the daemon's number for it.
    private struct Standing {
        let identifier: String
        let profileID: String?
        let sessionID: String?
        let decision: DecisionPayload?
        let question: QuestionRequest?
        let choices: [String]
        let retryPrompt: String?
        let rich: Bool
        let isTest: Bool
    }

    /// One notice as the desktop is told about it.
    private struct Outgoing {
        var title: String
        var headline: String?
        var facts: [String] = []
        var lines: [String]
        var face: AlertFace
        var picture: Data?
        var identifier: String
        var profileID: String?
        var sessionID: String?
        var origin: String?
        var decision: DecisionPayload?
        var question: QuestionRequest?
        var choices: [String] = []
        var replyPlaceholder: String?
        var retryPrompt: String?
        var rich = false
        var isTest = false
        var sound: String
        var category: String
        var resident: Bool
        var timeout: Int32
        var urgency: UInt8
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

    /// Names a server for the notices it raises, so a stack says which machine each came from.
    /// Any thread.
    func noteServer(profileID: String, name: String) {
        serversLock.lock()
        serverNames[profileID] = name
        serversLock.unlock()
    }

    private func origin(for profileID: String?) -> String? {
        guard let profileID else { return nil }
        serversLock.lock()
        defer { serversLock.unlock() }
        return serverNames[profileID]
    }

    /// Registers `app.open-session` and `app.permission-decision` and remembers the application,
    /// so a daemon that cannot take an image still routes a tap, and the freedesktop daemon's own
    /// buttons and reply field land in the same handlers.
    func attach(
        app: UnsafeMutablePointer<AdwApplication>, onOpen: @escaping @Sendable (String) -> Void,
        onDecision: @escaping @Sendable (String, PermissionRequest, Bool, String) -> Void,
        onReply: @escaping @Sendable (String, String, String, String) -> Void,
        onAnswer: @escaping @Sendable (String, QuestionRequest, [[String]], String) -> Void
    ) {
        self.onOpen = onOpen
        self.onDecision = onDecision
        self.onReply = onReply
        self.onAnswer = onAnswer
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
        tailscode_desktop_notify_listen(
            Self.actionInvoked, Self.noticeClosed, Self.noticeReplied, nil)
    }

    private static let actionInvoked: @convention(c) (
        UInt32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { id, action, _ in
        let key = action.map { String(cString: $0) } ?? ""
        Gtk.onMain { Notifier.shared.handle(id: id, action: key) }
    }

    private static let noticeReplied: @convention(c) (
        UInt32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { id, text, _ in
        let words = text.map { String(cString: $0) } ?? ""
        Gtk.onMain { Notifier.shared.handle(id: id, reply: words) }
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
        case Self.retryActionID:
            guard let profileID = notice.profileID, let sessionID = notice.sessionID,
                let prompt = notice.retryPrompt
            else { return }
            onReply?(profileID, sessionID, prompt, notice.identifier)
        case let choice where choice.hasPrefix(Self.choicePrefix):
            guard let index = Int(choice.dropFirst(Self.choicePrefix.count)),
                notice.choices.indices.contains(index), let question = notice.question,
                let profileID = notice.profileID
            else { return }
            onAnswer?(profileID, question, [[notice.choices[index]]], notice.identifier)
        default:
            if let sessionID = notice.sessionID, !sessionID.isEmpty { onOpen?(sessionID) }
        }
    }

    /// Words typed into the notice's reply field: the answer to the question it asks, or the next
    /// message of the chat it is about. The preferences' test notice has no chat to send to, so it
    /// shows the words back in a notice of their own, which is the whole path proved.
    private func handle(id: UInt32, reply: String) {
        let words = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let notice = standing[id] else { return }
        if notice.isTest {
            raiseEcho(words)
        } else if let question = notice.question, let profileID = notice.profileID {
            onAnswer?(profileID, question, [[words]], notice.identifier)
        } else if let profileID = notice.profileID, let sessionID = notice.sessionID {
            onReply?(profileID, sessionID, words, notice.identifier)
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

    /// Turn-end edges across the listing, skipping the open session: its own stream reports it.
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
    /// keeps it until someone looks. An alert that knows less than the notice already standing for
    /// the same event (a listing's "finished" after the conversation's own) is dropped rather
    /// than allowed to replace it.
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
            if alert.notice == nil, standingIsRich(alert.identifier) { continue }
            let shot = (alert.reason == .turnEnded || alert.reason == .turnFailed) ? picture : nil
            publish(outgoing(alert, picture: shot))
            raised.append(alert)
        }
        ActivityInbox.record(raised)
    }

    private func standingIsRich(_ identifier: String) -> Bool {
        guard let id = daemonID[identifier] else { return false }
        return standing[id]?.rich ?? false
    }

    private func outgoing(_ alert: ActivityAlert, picture: Data?) -> Outgoing {
        let waits = alert.reason == .needsApproval || alert.reason == .needsAnswer
        let notice = alert.notice
        let decision = alert.permission.map {
            DecisionPayload(
                profileID: alert.profileID, identifier: alert.identifier, approve: true,
                permission: $0)
        }
        return Outgoing(
            title: alert.title, headline: notice?.headline, facts: notice?.facts ?? [],
            lines: notice?.rest ?? [alert.body],
            face: alert.reason.face, picture: picture, identifier: alert.identifier,
            profileID: alert.profileID, sessionID: alert.sessionID,
            origin: origin(for: alert.profileID), decision: decision, question: alert.question,
            choices: notice?.choices ?? [], replyPlaceholder: notice?.replyPlaceholder,
            retryPrompt: notice?.retryPrompt, rich: notice != nil,
            sound: NotificationPlate.sound(alert.reason),
            category: NotificationPlate.category(alert.reason), resident: waits,
            timeout: waits ? 0 : -1, urgency: waits ? 2 : 1)
    }

    /// A delegate run's notice, under the same switches a conversation's alerts answer to: a wait
    /// for a person is an approval, an end is a finished turn, and never while a window of this
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
            Outgoing(
                title: notice.title, lines: [notice.body], face: face, picture: nil,
                identifier: identifier, sound: NotificationPlate.sound(notice.kind),
                category: NotificationPlate.category(notice.kind), resident: waits,
                timeout: waits ? 0 : -1, urgency: waits ? 2 : 1))
    }

    private func publish(_ notice: Outgoing) {
        let image = NotificationPlate.imagePath(
            face: notice.face, picture: notice.picture,
            name: NotificationPlate.nextName(notice.identifier))
        let words = NotificationPlate.wording(
            headline: notice.headline, facts: notice.facts, lines: notice.lines)
        let actions = Self.actions(for: notice)
        let replaces = daemonID[notice.identifier] ?? 0
        let id: UInt32
        if actions.isEmpty {
            id = tailscode_desktop_notify(
                notice.title, words.markup, words.plain, image, notice.sound, notice.category,
                DesktopIntegration.appID, notice.origin, notice.urgency, notice.resident ? 1 : 0,
                notice.timeout, replaces, nil, 0, notice.replyPlaceholder)
        } else {
            id = notificationCStrings(actions) { pointers in
                tailscode_desktop_notify(
                    notice.title, words.markup, words.plain, image, notice.sound, notice.category,
                    DesktopIntegration.appID, notice.origin, notice.urgency,
                    notice.resident ? 1 : 0, notice.timeout, replaces, pointers,
                    Int32(actions.count), notice.replyPlaceholder)
            }
        }
        if id != 0 {
            if replaces != 0 { standing[replaces] = nil }
            daemonID[notice.identifier] = id
            standing[id] = Standing(
                identifier: notice.identifier, profileID: notice.profileID,
                sessionID: notice.sessionID, decision: notice.decision, question: notice.question,
                choices: notice.choices, retryPrompt: notice.retryPrompt, rich: notice.rich,
                isTest: notice.isTest)
            if let app = application { g_application_withdraw_notification(app, notice.identifier) }
            return
        }
        sendFallback(notice, body: words.plain, imagePath: image)
    }

    private static let retryActionID = "retry"
    private static let choicePrefix = "choice:"

    /// The buttons and the reply field, as the daemon is told of them: key, label, key, label.
    private static func actions(for notice: Outgoing) -> [String] {
        var actions: [String] = []
        if let sessionID = notice.sessionID, !sessionID.isEmpty {
            actions += ["default", Localized.text("Open")]
        }
        if notice.decision != nil {
            for action in notice.face.category.actions {
                actions += [action.id, action.title]
            }
        }
        for (index, label) in notice.choices.enumerated() {
            actions += ["\(choicePrefix)\(index)", label]
        }
        if notice.retryPrompt != nil {
            actions += [retryActionID, Localized.text("Try again")]
        }
        if notice.replyPlaceholder != nil {
            actions += ["inline-reply", Localized.text("Reply")]
        }
        return actions
    }

    private func sendFallback(_ notice: Outgoing, body: String, imagePath: String?) {
        guard let app = application else { return }
        if let previous = daemonID.removeValue(forKey: notice.identifier) {
            standing[previous] = nil
            tailscode_desktop_notify_close(previous)
        }
        let gnotification = g_notification_new(notice.title)
        g_notification_set_body(gnotification, body)
        if let imagePath, let file = g_file_new_for_path(imagePath),
            let icon = g_file_icon_new(file)
        {
            g_notification_set_icon(gnotification, op(UnsafeMutableRawPointer(icon)))
            g_object_unref(UnsafeMutableRawPointer(icon))
            g_object_unref(UnsafeMutableRawPointer(file))
        } else if let icon = g_themed_icon_new(notice.face.themedIcon) {
            g_notification_set_icon(gnotification, op(UnsafeMutableRawPointer(icon)))
            g_object_unref(UnsafeMutableRawPointer(icon))
        }
        if notice.resident { g_notification_set_priority(gnotification, G_NOTIFICATION_PRIORITY_HIGH) }
        if let sessionID = notice.sessionID, !sessionID.isEmpty {
            g_notification_set_default_action_and_target_value(
                gnotification, "app.open-session", g_variant_new_string(sessionID))
        }
        if let decision = notice.decision {
            for action in notice.face.category.actions {
                let payload = DecisionPayload(
                    profileID: decision.profileID, identifier: decision.identifier,
                    approve: action.id == AlertCategory.approveActionID,
                    permission: decision.permission)
                guard let encoded = try? JSONEncoder().encode(payload) else { continue }
                g_notification_add_button_with_target_value(
                    gnotification, action.title, "app.permission-decision",
                    g_variant_new_string(String(decoding: encoded, as: UTF8.self)))
            }
        }
        g_application_send_notification(app, notice.identifier, gnotification)
        g_object_unref(gnotification.map { UnsafeMutableRawPointer($0) })
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

    /// What went wrong when words typed into a notice could not be sent, with the words, so the
    /// person has them back to send again.
    func reportUnsent(title: String, words: String) {
        publish(
            Outgoing(
                title: title, headline: Localized.text("Couldn't send"), lines: [words],
                face: .turnFailed, picture: nil, identifier: "unsent", sound: "dialog-warning",
                category: "device.error", resident: false, timeout: -1, urgency: 1))
    }

    /// The words typed into the test notice, shown back: proof that a reply made it from the
    /// desktop's field to this app.
    private func raiseEcho(_ words: String) {
        publish(
            Outgoing(
                title: "Tailscode", lines: [words], face: .turnEnded, picture: nil,
                identifier: "test-reply", sound: NotificationPlate.sound(.turnEnded),
                category: NotificationPlate.category(.turnEnded), resident: false, timeout: -1,
                urgency: 1))
    }

    /// Proves the whole delivery path from Preferences (daemon, face, sound, body, the reply
    /// field), which is otherwise only observable by backgrounding the window and waiting for a
    /// real turn.
    func sendTest() {
        let reading = NoticeReading(
            headline: NoticeReader.sentence(Localized.text("finished")),
            facts: ["12s", Localized.text("%lld tools", 3), "+24 −6"],
            excerpt: Localized.text(
                "Notifications are working. This is what a finished turn looks like."),
            replyPlaceholder: Localized.text("Message your agent…"))
        publish(
            Outgoing(
                title: "Tailscode", headline: reading.headline, facts: reading.facts,
                lines: reading.rest, face: .turnEnded, picture: nil, identifier: "test",
                replyPlaceholder: reading.replyPlaceholder, isTest: true,
                sound: NotificationPlate.sound(.turnEnded),
                category: NotificationPlate.category(.turnEnded), resident: false, timeout: -1,
                urgency: 1))
    }

    private var application: UnsafeMutablePointer<GApplication>? {
        guard let raw = UnsafeMutableRawPointer(bitPattern: appBits) else { return nil }
        return ptr(raw)
    }
}
