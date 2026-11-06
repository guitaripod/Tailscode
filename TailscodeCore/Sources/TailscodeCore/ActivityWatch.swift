import CodingAgentKit
import Foundation

/// One shoulder tap worth raising: which session, why, and the words the system notification
/// should say. The identifier is stable per event so a repeat render cannot stack duplicates,
/// and so an answered request can be withdrawn by name.
public struct ActivityAlert: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case turnEnded
        case turnFailed
        case needsApproval
        case needsAnswer
    }

    public let profileID: String
    public let sessionID: String
    public let identifier: String
    public let title: String
    public let body: String
    public let reason: Reason
    /// The request an approval alert is about, carried whole so a client that can put buttons on
    /// a notification can answer it from there — the tap needs the same object the in-app sheet
    /// would have been given.
    public let permission: PermissionRequest?
    /// The question a needs-an-answer alert is about, carried whole for the same reason: a client
    /// that can put its answers on the notification can send them from there.
    public let question: QuestionRequest?
    /// What the alert has to say beyond `body`, read from the conversation it came from. Nil from
    /// a listing, which knows a session stopped being live and nothing more.
    public let notice: NoticeReading?

    init(
        profileID: String, sessionID: String, identifier: String, title: String, body: String,
        reason: Reason, permission: PermissionRequest? = nil, question: QuestionRequest? = nil,
        notice: NoticeReading? = nil
    ) {
        self.profileID = profileID
        self.sessionID = sessionID
        self.identifier = identifier
        self.title = title
        self.body = body
        self.reason = reason
        self.permission = permission
        self.question = question
        self.notice = notice
    }
}

/// One row of what the chat list already knows, reduced to what can say whether work goes on.
public struct ActivityObservation: Sendable {
    public let profileID: String
    public let sessionID: String
    public let title: String
    public let isActive: Bool
    /// When the server last saw the conversation move, which is what a read mark is weighed
    /// against. Nil from a caller that does not know, and a row with no moment is never judged read.
    public let updatedAt: Date?
    /// Background tasks and working agents the listing says the session still holds. A row whose
    /// own turn closed while its agents work is not a chat that finished.
    public let carried: Int

    public init(
        profileID: String, sessionID: String, title: String, isActive: Bool,
        updatedAt: Date? = nil, carried: Int = 0
    ) {
        self.profileID = profileID
        self.sessionID = sessionID
        self.title = title
        self.isActive = isActive
        self.updatedAt = updatedAt
        self.carried = carried
    }

    /// A listed session as the watch reads it: open, or holding agents or background work.
    public init(profileID: String, session: AgentSession, title: String) {
        self.init(
            profileID: profileID, sessionID: session.id, title: title,
            isActive: session.isActive == true, updatedAt: session.updatedAt,
            carried: (session.backgroundWork?.tasks ?? 0) + (session.activeAgents ?? 0))
    }
}

/// Finds the moments worth a system notification in state the client already holds, and decides
/// which of them the person asked for (`rules`).
///
/// Asks are edges: a new approval or question is raised the moment it is seen, and withdrawn the
/// moment it stops being true. Finished work is not an edge. A turn closing is folded into
/// `WorkSettle`, and the work is over only once nothing is running, carried or queued for the
/// grace — `due(at:)` hands those over, and the client calls it at `nextDue`. A person who wants
/// every turn gets each one as it closes instead.
///
/// Two witnesses can speak about one session: the conversation a client streams, and the listing
/// it polls. The conversation is the authority while it is fresh; the listing fills in what a
/// stream cannot see (another device's agents) and stands alone for the sessions nobody streams.
/// The first look primes silently, so launching onto a pile of finished sessions says nothing,
/// and focus gating belongs to the client, because only the client knows what is being looked at.
public struct ActivityWatch: Sendable {
    public var rules: NoticeRules

    /// How long a listing reading counts for: a poll that stopped arriving is not a witness.
    static let listingTrust: TimeInterval = 90
    /// How long a streamed conversation counts for after its last state. A stream reports every
    /// change, so silence is a long quiet tool or a stream that was let go of.
    static let conversationTrust: TimeInterval = 20 * 60

    private struct Witness: Sendable {
        var reading: WorkSettle.Reading
        var at: Date
    }

    private struct Witnesses: Sendable {
        var conversation: Witness?
        var listing: Witness?
    }

    /// What an ending will say when it is raised: the chat's name and, from a conversation, the
    /// notice read off its last turn.
    private struct Copy: Sendable {
        var profileID: String
        var sessionID: String
        var title: String
        var notice: NoticeWire?
    }

    private var settle = WorkSettle()
    private var witnesses: [String: Witnesses] = [:]
    private var copies: [String: Copy] = [:]
    private var notifiedPermissionIDs: [String: Set<String>] = [:]
    private var notifiedQuestionIDs: [String: Set<String>] = [:]

    public init(rules: NoticeRules = .standard) {
        self.rules = rules
    }

    /// Work in every session the list can see. A session somebody streams is read from its
    /// stream, which reports faster and more precisely than a refresh can; its row only adds the
    /// agents and background work the stream cannot see.
    public mutating func observeListing(
        _ rows: [ActivityObservation], at now: Date = Date()
    ) -> [ActivityAlert] {
        var alerts: [ActivityAlert] = []
        for row in rows {
            let key = Self.key(row.profileID, row.sessionID)
            witnesses[key, default: Witnesses()].listing = Witness(
                reading: WorkSettle.Reading(running: row.isActive, carried: row.carried), at: now)
            if copies[key] == nil {
                copies[key] = Copy(
                    profileID: row.profileID, sessionID: row.sessionID, title: row.title)
            } else {
                copies[key]?.title = row.title
            }
            alerts += fold(key, at: now)
        }
        return alerts
    }

    /// Edges in a streamed conversation: a new permission ask or question, the turn closing, and
    /// the work it belongs to going on or stopping. Returns the alerts to raise now and the
    /// identifiers of request notices that stopped being true — an approval notice left standing
    /// after it was answered is a lie the user taps into and finds nothing.
    ///
    /// Every set here is per conversation. A desktop watches more than one at once, and one shared
    /// set means every observation of chat A reads chat B's still-pending approval as answered: it
    /// withdraws the notice, forgets it, and raises it again the next time B is looked at — a
    /// banner on a loop over a request nobody touched.
    ///
    /// - Parameter heldQueue: messages this device is holding to send into the conversation, which
    ///   start a turn as surely as the server's own queue does.
    public mutating func observeConversation(
        profileID: String, sessionID: String, title: String, state: ConversationState,
        heldQueue: Int = 0, at now: Date = Date()
    ) -> (alerts: [ActivityAlert], withdrawals: [String]) {
        let key = Self.key(profileID, sessionID)
        var alerts: [ActivityAlert] = []
        var copy = copies[key] ?? Copy(profileID: profileID, sessionID: sessionID, title: title)
        copy.title = title
        if state.status != .unknown {
            var seen = witnesses[key] ?? Witnesses()
            let reading = WorkSettle.Reading(state, heldQueue: heldQueue)
            let wasRunning = seen.conversation?.reading.running ?? false
            seen.conversation = Witness(reading: reading, at: now)
            witnesses[key] = seen
            if wasRunning, !reading.running {
                copy.notice =
                    reading.failed
                    ? NoticeReader.wire(turnFailed: state) : NoticeReader.wire(turnEnded: state)
            }
        }
        copies[key] = copy
        if state.status != .unknown { alerts += fold(key, at: now) }

        let permissionIDs = Set(state.pendingPermissions.map(\.id))
        for permission in state.pendingPermissions
        where !(notifiedPermissionIDs[key]?.contains(permission.id) ?? false) {
            notifiedPermissionIDs[key, default: []].insert(permission.id)
            guard rules.admitsAsk(sessionID: sessionID) else { continue }
            let tool = permission.toolName ?? permission.title ?? Localized.text("a tool")
            alerts.append(
                ActivityAlert(
                    profileID: profileID, sessionID: sessionID,
                    identifier: "perm:\(permission.id)",
                    title: title,
                    body: Localized.text("Approval needed: %@", tool),
                    reason: .needsApproval, permission: permission,
                    notice: NoticeReader.approval(permission, in: state)))
        }

        let questions = state.pendingQuestions
        let questionIDs = Set(questions.map(\.id))
        for question in questions where !(notifiedQuestionIDs[key]?.contains(question.id) ?? false) {
            notifiedQuestionIDs[key, default: []].insert(question.id)
            guard rules.admitsAsk(sessionID: sessionID) else { continue }
            let text = question.questions.first?.question ?? ""
            alerts.append(
                ActivityAlert(
                    profileID: profileID, sessionID: sessionID,
                    identifier: "question:\(question.id)",
                    title: title,
                    body: text.isEmpty
                        ? Localized.text("Your agent has a question.") : String(text.prefix(120)),
                    reason: .needsAnswer, question: question,
                    notice: NoticeReader.question(question)))
        }

        var withdrawals: [String] = []
        for id in notifiedPermissionIDs[key] ?? [] where !permissionIDs.contains(id) {
            withdrawals.append("perm:\(id)")
            notifiedPermissionIDs[key]?.remove(id)
        }
        for id in notifiedQuestionIDs[key] ?? [] where !questionIDs.contains(id) {
            withdrawals.append("question:\(id)")
            notifiedQuestionIDs[key]?.remove(id)
        }
        return (alerts, withdrawals)
    }

    /// Finished work whose grace ran out with nothing starting again, as the alerts the person
    /// asked for. Called at `nextDue`; calling it early or late is harmless.
    public mutating func due(at now: Date = Date()) -> [ActivityAlert] {
        var alerts: [ActivityAlert] = []
        for ending in settle.due(at: now) {
            guard rules.finish != .everyTurn,
                now.timeIntervalSince(ending.ended) <= WorkSettle.grace + Self.lateness,
                let alert = alert(for: ending)
            else { continue }
            alerts.append(alert)
        }
        return alerts
    }

    /// How late an ending may still be raised. One that was owed while the person had finished
    /// work switched off, or while nothing was asking, is history by the time anybody asks again.
    static let lateness: TimeInterval = 60

    /// When the next stretch of work falls due, or nil when nothing is settling.
    public var nextDue: Date? {
        switch rules.finish {
        case .never, .everyTurn: return nil
        case .settled, .failures: return settle.nextDue
        }
    }

    /// Lets go of a conversation a client stopped streaming: the listing speaks for it again.
    public mutating func releaseConversation(profileID: String, sessionID: String) {
        witnesses[Self.key(profileID, sessionID)]?.conversation = nil
    }

    /// One reading out of the witnesses that are still worth hearing, fed to the settle.
    private mutating func fold(_ key: String, at now: Date) -> [ActivityAlert] {
        guard let reading = merged(key, at: now) else { return [] }
        let change = settle.observe(key, reading, at: now)
        guard rules.finish == .everyTurn, let ended = change.turnEnded else { return [] }
        return alert(for: ended).map { [$0] } ?? []
    }

    private func merged(_ key: String, at now: Date) -> WorkSettle.Reading? {
        guard let seen = witnesses[key] else { return nil }
        let listing = seen.listing.flatMap {
            now.timeIntervalSince($0.at) <= Self.listingTrust ? $0.reading : nil
        }
        if let conversation = seen.conversation,
            now.timeIntervalSince(conversation.at) <= Self.conversationTrust
        {
            var reading = conversation.reading
            reading.carried = max(reading.carried, listing?.carried ?? 0)
            return reading
        }
        return listing
    }

    /// The alert for an ending, read from what the conversation last said. The notice is spent
    /// by it: work a later listing sees end has no turn of its own to quote.
    private mutating func alert(for ending: WorkSettle.Ending) -> ActivityAlert? {
        guard let copy = copies[ending.key] else { return nil }
        copies[ending.key]?.notice = nil
        guard rules.admits(failed: ending.failed, length: ending.length, sessionID: copy.sessionID)
        else { return nil }
        var notice = copy.notice
        if notice?.kind == .failed, !ending.failed { notice = nil }
        if ending.failed, notice?.kind != .failed { notice = NoticeWire(kind: .failed) }
        notice?.seconds = Int(ending.length.rounded())
        return ActivityAlert(
            profileID: copy.profileID, sessionID: copy.sessionID,
            identifier: "done:\(copy.sessionID)",
            title: copy.title,
            body: ending.failed
                ? Localized.text("The turn failed.") : Localized.text("Your agent finished."),
            reason: ending.failed ? .turnFailed : .turnEnded,
            notice: notice.map(NoticeWords.reading))
    }

    private static func key(_ profileID: String, _ sessionID: String) -> String {
        "\(profileID)/\(sessionID)"
    }
}
