import CodingAgentKit
import MidgarCore
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
        case turnComplete, approval, question, usage, runningLow

        var isEnabled: Bool {
            switch self {
            case .turnComplete: return AppPreferences.notifyTurnComplete
            case .approval, .question: return AppPreferences.notifyApprovals
            case .usage: return AppPreferences.notifyUsageWarnings
            case .runningLow: return AppPreferences.notifyRunningLow
            }
        }

        var face: AlertFace {
            switch self {
            case .turnComplete: return .turnEnded
            case .approval: return .needsApproval
            case .question: return .needsAnswer
            case .usage, .runningLow: return .usage
            }
        }

        func wireKind(activity: MissedActivity.Reason?) -> NoticeWire.Kind {
            switch self {
            case .turnComplete: return activity == .turnFailed ? .failed : .done
            case .approval: return .approval
            case .question: return .question
            case .usage, .runningLow: return .usage
            }
        }

        /// Where a tap lands when the notice is not about one conversation. A quota warning names
        /// no session, and a notification whose tap does nothing at all is worse than none — the
        /// thing it is about has a screen, so it opens it.
        var route: String? {
            switch self {
            case .usage, .runningLow: return "usage"
            case .turnComplete, .approval, .question: return nil
            }
        }
    }

    /// Tells the system what each kind of notification is and which buttons it carries, from the
    /// one catalog the app, its notification service and its long look all read: a finished turn
    /// takes a reply, a failed one can be tried again, an approval wears Approve and Deny, and a
    /// question wears its own options.
    static func registerCategories() {
        NoticeCategories.register()
    }

    /// Whether this launch is a scripted one — the demo, the usage board, or a DEBUG driver that
    /// sends for itself — where a question about notifications would land on a screen nobody is
    /// there to answer.
    private static var isScriptedRun: Bool {
        if CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--usage") {
            return true
        }
        #if DEBUG
            let env = ProcessInfo.processInfo.environment
            return env["TAILSCODE_AUTOSEND"] != nil || env["TAILSCODE_OPEN_SESSION"] != nil
                || env["TAILSCODE_NEW_CHAT"] != nil
        #else
            return false
        #endif
    }

    /// Asks, in the app's own words, whether alerts are wanted — the one moment the system prompt
    /// is spent, and only after a real turn has finished so the person has seen what there is to
    /// be alerted about. Nothing is marked as asked unless the question is actually put, so a turn
    /// that ends while the app is behind a sheet or in the background leaves the next one to ask.
    static func offerAfterFirstTurn(from presenter: UIViewController) {
        guard !isScriptedRun else { return }
        Task { @MainActor in
            let answerPending = await authorizationStatus() == .notDetermined
            guard
                NotificationPrimer.shouldOffer(
                    systemAnswerPending: answerPending,
                    isDemo: ConnectionController.shared.isDemoMode),
                UIApplication.shared.applicationState == .active,
                presenter.viewIfLoaded?.window != nil,
                presenter.presentedViewController == nil
            else { return }
            NotificationPrimer.markOffered()
            MidgarLog.info(
                "notification pre-prompt shown after first completed turn", category: .lifecycle)
            let alert = UIAlertController(
                title: NotificationPrimer.title, message: NotificationPrimer.body,
                preferredStyle: .alert)
            alert.addAction(
                UIAlertAction(title: NotificationPrimer.declineAction, style: .cancel) { _ in
                    MidgarLog.info("notification pre-prompt declined", category: .lifecycle)
                })
            let accept = UIAlertAction(title: NotificationPrimer.acceptAction, style: .default) { _ in
                Task { @MainActor in await requestAuthorization(source: "pre-prompt") }
            }
            alert.addAction(accept)
            alert.preferredAction = accept
            presenter.present(alert, animated: true)
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The explicit ask from the Settings row, for a user who reached the app's
    /// notification controls without ever having seen the system prompt.
    @discardableResult
    static func requestAuthorization(source: String = "settings") async -> Bool {
        MidgarLog.info("notification authorization requested from \(source)", category: .lifecycle)
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
        for identifier in identifiers { NoticeSlots.release(identifier: identifier) }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Takes a notice down from Notification Center and nothing else: the Missed list still holds
    /// it, which is the point of a notice that lost its place to another.
    static func removeDelivered(_ identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Opening a conversation answers every notice about it, in both places a notice lives.
    ///
    /// The inbox alone is not enough now that it adopts what Notification Center kept: a banner
    /// left standing after the chat has been read is a notice about nothing, and the next adoption
    /// pass would file it all over again.
    static func clearNotices(sessionID: String) {
        ActivityInbox.clear(sessionID: sessionID)
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered.filter {
                $0.request.content.userInfo["sessionID"] as? String == sessionID
            }.map(\.request.identifier)
            guard !identifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    /// Emptying the list answers every notice in it, in both places a notice lives.
    ///
    /// The list is only half of where a notice is kept. `adoptDelivered` files whatever Notification
    /// Center is still holding, and it runs on every load — so a Clear that emptied the list alone
    /// was undone by the next poll seconds later, with the original timestamps, which reads as the
    /// same entries coming back by themselves. The horizon in `ActivityInbox` makes the dismissal
    /// stick even against an adoption already in flight; this takes the banners themselves back, so
    /// Notification Center agrees with the list about what has been dealt with.
    static func clearAllNotices() {
        ActivityInbox.clearAll()
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered.filter {
                ($0.request.content.userInfo["sessionID"] as? String)?.isEmpty == false
            }.map(\.request.identifier)
            guard !identifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    /// Adopts what Notification Center is still holding.
    ///
    /// The inbox is written by whoever raises a notice, which works for every notice this app
    /// raises and for none of the ones it doesn't: a bridge pushes the end of a turn to a phone
    /// whose app is not running, and there is nobody here to write it down — the banner arrives,
    /// the list stays empty, and Missed silently misses the very thing it exists for. Notification
    /// Center kept the notice, though, so it is read back and adopted the moment the app is
    /// looking again. A push carries no profile, so each is placed by the session it names; one
    /// whose session this device cannot see yet is left in Notification Center for the next pass
    /// rather than filed under a server it might not belong to.
    ///
    /// The bridge's own turn-end notice is given the identifier the local one would have had, so
    /// the same turn cannot be listed twice by two machines that both noticed it.
    static func adoptDelivered(
        profileForSession: (String) -> String?, liveSessionIDs: Set<String> = []
    ) async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        var adopted: [MissedActivity] = []
        for notice in delivered {
            let content = notice.request.content
            guard let sessionID = content.userInfo["sessionID"] as? String, !sessionID.isEmpty,
                let profileID = profileForSession(sessionID)
            else { continue }
            let raised = notice.request.identifier
            let fromServer = notice.request.trigger is UNPushNotificationTrigger
            adopted.append(
                MissedActivity(
                    identifier: fromServer ? "done:\(sessionID)" : raised,
                    profileID: profileID, sessionID: sessionID, title: content.title,
                    body: content.body,
                    reason: fromServer
                        ? reason(of: NoticeWire(userInfo: content.userInfo))
                        : reason(forIdentifier: raised),
                    at: notice.date))
        }
        ActivityInbox.record(adopted, liveSessionIDs: liveSessionIDs)
    }

    /// What a pushed notice was about, read from the notice it carries; one from a bridge that
    /// predates notices is a turn that ended.
    private static func reason(of wire: NoticeWire?) -> MissedActivity.Reason {
        switch wire?.kind {
        case .failed?: return .turnFailed
        case .approval?: return .needsApproval
        case .question?: return .needsAnswer
        default: return .turnEnded
        }
    }

    /// What a delivered notice was about, read from the name it was raised under — the only thing
    /// a notification carries that says which of the four it is.
    private static func reason(forIdentifier identifier: String) -> MissedActivity.Reason {
        if identifier.hasPrefix("perm:") { return .needsApproval }
        if identifier.hasPrefix("question:") { return .needsAnswer }
        return .turnEnded
    }

    /// - Parameters:
    ///   - permission: the request an approval is about, carried whole so the notification's own
    ///     Approve and Deny buttons can answer it without opening the app.
    ///   - question: the question a notice asks, carried whole so its options and its reply field
    ///     can answer it from outside the app.
    ///   - notice: what the notice has to say beyond `body`: how long the turn took, what it did,
    ///     the first of what it answered. Absent, the notice is `body` under the kind's own face.
    ///   - picture: what the turn drew, when this device already has the bytes, worn with the
    ///     face in its corner in place of the face alone.
    ///   - activity: what happened in the session, when the notice is about one. A notice raised
    ///     is also a notice that can be missed — a banner lasts seconds whether or not anybody was
    ///     looking — so anything named here is written into `ActivityInbox` by the same decision
    ///     that banners it: suppressed by preference means never raised, so never missed.
    static func notify(
        kind: Kind, title: String, body: String, identifier: String, sessionID: String? = nil,
        profileID: String? = nil, permission: PermissionRequest? = nil,
        question: QuestionRequest? = nil, notice: NoticeWire? = nil, picture: Data? = nil,
        activity: MissedActivity.Reason? = nil
    ) {
        guard kind.isEnabled else {
            MidgarLog.info(
                "notification suppressed by preference: \(identifier)", category: .lifecycle)
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
        let wire = notice ?? NoticeWire(kind: kind.wireKind(activity: activity))
        var category: String?
        if wire.kind != .usage && (sessionID == nil || (wire.kind == .approval && permission == nil)) {
            category = NoticeActionID.plainCategory
        } else if wire.kind == .question,
            let claim = NoticeCategories.claimSlot(
                identifier: identifier, reading: NoticeWords.reading(wire))
        {
            category = claim.category
            if let evicted = claim.evicted { removeDelivered([evicted]) }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        NoticeContent.dress(
            content, as: wire, title: title, sessionID: sessionID, profileID: profileID,
            category: category, withFace: picture == nil)
        if notice == nil {
            content.subtitle = ""
            content.body = body
        }
        var userInfo = content.userInfo
        if let route = kind.route { userInfo["route"] = route }
        if let permission, let encoded = try? JSONEncoder().encode(permission) {
            userInfo["permission"] = String(decoding: encoded, as: UTF8.self)
        }
        if let question, let encoded = try? JSONEncoder().encode(question) {
            userInfo["question"] = String(decoding: encoded, as: UTF8.self)
        }
        content.userInfo = userInfo
        if let picture, let attachment = NoticeFace.attachment(
            picture: picture, presentation: NoticePresentation.of(wire.kind), glyph: wire.glyph)
        {
            content.attachments = [attachment]
        }
        let pending = ActivityInbox.all().count
        if pending > 0 { content.badge = NSNumber(value: pending) }
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Keeps the app icon's badge and the app group's copy of it equal to what the Missed list
    /// holds, which is what the notification service counts up from when it badges a push.
    static func syncBadge() {
        let count = ActivityInbox.all().count
        NoticeBadge.set(count)
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    /// Puts a notice on the moment a spent window reopens.
    ///
    /// Scheduled ahead rather than raised when it happens, because the whole point of the wait is
    /// that nobody is watching: a phone the system never wakes still tells its owner the window
    /// opened and what the app is doing about it. Withdrawn the instant the plan is — a
    /// notification for a wait somebody ended is the app talking about a decision it no longer
    /// holds.
    static func scheduleResumeNotice(_ plan: ResumePlan) {
        let identifier = resumeIdentifier(plan.id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let seconds = plan.remaining()
        guard seconds > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = ResumeReading.notificationTitle(plan)
        content.body = ResumeReading.notificationBody(plan)
        content.sound = .default
        content.categoryIdentifier = AlertFace.usage.category.rawValue
        content.threadIdentifier = plan.sessionID
        content.userInfo = ["sessionID": plan.sessionID, "profileID": plan.profileID]
        center.add(
            UNNotificationRequest(
                identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: seconds, repeats: false)))
    }

    static func withdrawResumeNotice(_ row: UUID) {
        let identifier = resumeIdentifier(row)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private static func resumeIdentifier(_ row: UUID) -> String { "resume:\(row.uuidString)" }

    /// Proves the whole delivery path end to end from Settings — authorization,
    /// presentation, sound, the face, the long look and the buttons — which is otherwise only
    /// observable by waiting for a real turn to finish while the app is backgrounded. The short
    /// delay is what lets it banner over a foreground app.
    static func sendTest(_ sample: NoticeSample = .finished) {
        let center = UNUserNotificationCenter.current()
        let identifier = "test:\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        var category: String?
        if sample.wire.kind == .question,
            let claim = NoticeCategories.claimSlot(
                identifier: identifier, reading: NoticeWords.reading(sample.wire))
        {
            category = claim.category
            if let evicted = claim.evicted { removeDelivered([evicted]) }
        }
        NoticeContent.dress(
            content, as: sample.wire, title: sample.title, sessionID: nil, profileID: nil,
            category: category)
        var userInfo = content.userInfo
        userInfo["test"] = true
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        center.add(request)
        MidgarLog.info("test notification scheduled: \(sample)", category: .lifecycle)
    }
}

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
        let userInfo = notification.request.content.userInfo
        let sessionID = userInfo["sessionID"] as? String
        let waitsOnYou = NoticeWire(userInfo: userInfo).map { $0.kind == .question || $0.kind == .approval } ?? false
        nonisolated(unsafe) let complete = completionHandler
        DispatchQueue.main.async {
            guard isPush else {
                complete([.banner, .list, .sound])
                return
            }
            let isActive = UIApplication.shared.applicationState == .active
            guard isActive else {
                complete([.banner, .list, .sound])
                return
            }
            let beingRead = sessionID.map { AppActivityController.shared.isBeingRead($0) } ?? false
            complete(waitsOnYou && !beingRead ? [.banner, .list, .sound] : [.list])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let payload = content.userInfo["permission"] as? String
        let questionJSON = content.userInfo["question"] as? String
        let wire = NoticeWire(userInfo: content.userInfo)
        let profileID = content.userInfo["profileID"] as? String
        let sessionID = content.userInfo["sessionID"] as? String
        let route = content.userInfo["route"] as? String
        let isTest = content.userInfo["test"] as? Bool ?? false
        let title = content.title
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        nonisolated(unsafe) let complete = completionHandler
        Task { @MainActor in
            switch action {
            case NoticeActionID.approve, NoticeActionID.deny:
                await Self.decide(
                    payload: payload, profileID: profileID, identifier: identifier,
                    approve: action == NoticeActionID.approve)
            case NoticeActionID.reply, NoticeActionID.retry:
                let words =
                    action == NoticeActionID.retry
                    ? wire?.prompt : typed?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let words, !words.isEmpty, let sessionID {
                    await NoticeReplies.send(
                        words, sessionID: sessionID, profileID: profileID, identifier: identifier,
                        title: title)
                } else if isTest, let words, !words.isEmpty {
                    Self.echo(words)
                } else if action == NoticeActionID.retry,
                    let url = Self.destination(route: route, sessionID: sessionID)
                {
                    PendingRoute.deliver(url)
                }
            case NoticeActionID.answer:
                let words = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !words.isEmpty, let sessionID {
                    await NoticeReplies.answer(
                        [[words]], question: Self.question(questionJSON), asked: wire?.text,
                        sessionID: sessionID, profileID: profileID, identifier: identifier,
                        title: title)
                } else if isTest, !words.isEmpty {
                    Self.echo(words)
                }
            default:
                if let index = NoticeActionID.choiceIndex(action), let wire, let sessionID {
                    let choices = NoticeWords.reading(wire).choices
                    if choices.indices.contains(index) {
                        await NoticeReplies.answer(
                            [[choices[index]]], question: Self.question(questionJSON),
                            asked: wire.text, sessionID: sessionID, profileID: profileID,
                            identifier: identifier, title: title)
                    }
                } else if let url = Self.destination(route: route, sessionID: sessionID) {
                    PendingRoute.deliver(url)
                }
            }
            complete()
        }
    }

    @MainActor
    private static func question(_ json: String?) -> QuestionRequest? {
        json.flatMap { try? JSONDecoder().decode(QuestionRequest.self, from: Data($0.utf8)) }
    }

    /// The words typed into a test notice, shown back, which proves the whole trip from the Lock
    /// Screen's field to this app.
    @MainActor
    private static func echo(_ words: String) {
        let content = UNMutableNotificationContent()
        content.title = "Tailscode"
        content.body = words
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "test-reply:\(UUID().uuidString)", content: content, trigger: nil))
    }

    private static func destination(route: String?, sessionID: String?) -> URL? {
        if let route, let url = URL(string: "tailscode://\(route)") { return url }
        guard let sessionID else { return nil }
        return SceneRouting.sessionURL(sessionID)
    }

    /// The lock-screen answer. A chat this process is holding answers through its own
    /// conversation, so the open chat's card settles with the server; otherwise the backend the
    /// request came from is rebuilt and responds by name. A request somebody already answered is
    /// not asked again, and its notice goes. Failure leaves the request standing — the inbox
    /// entry and the in-app banner still know about it, and resolving it from inside the chat
    /// stays possible.
    @MainActor
    private static func decide(
        payload: String?, profileID: String?, identifier: String, approve: Bool
    ) async {
        guard let payload,
            let permission = try? JSONDecoder().decode(
                PermissionRequest.self, from: Data(payload.utf8)),
            let profileID
        else {
            MidgarLog.error("notification decision: no stored payload", category: .session)
            return
        }
        let decision: PermissionDecision = approve ? .once : .reject
        let held = SessionActivity.shared.retainedViewModel(
            for: permission.sessionID, contextID: profileID)
        let backend = ConnectionController.shared.profiles.first(where: { $0.id == profileID })
            .flatMap { ConnectionController.shared.makeBackend(for: $0) }
        guard held != nil || backend != nil else {
            MidgarLog.error(
                "notification decision: no backend for stored payload", category: .session)
            return
        }
        do {
            let outcome: PermissionAnswer.Outcome
            if let held {
                outcome = try await held.answerFromNotice(permission, decision: decision)
            } else {
                outcome = try await PermissionAnswer.answer(
                    permission, decision: decision, through: nil, backend: backend)
            }
            NotificationManager.withdraw(identifiers: [identifier])
            MidgarLog.info(
                "notification decision \(approve ? "approved" : "denied") (\(outcome)): \(permission.id)", category: .session)
        } catch {
            MidgarLog.error("notification decision failed: \(error)", category: .session)
        }
    }
}
