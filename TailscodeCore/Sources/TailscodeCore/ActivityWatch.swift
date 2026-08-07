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

    init(
        profileID: String, sessionID: String, identifier: String, title: String, body: String,
        reason: Reason, permission: PermissionRequest? = nil
    ) {
        self.profileID = profileID
        self.sessionID = sessionID
        self.identifier = identifier
        self.title = title
        self.body = body
        self.reason = reason
        self.permission = permission
    }
}

/// One row of what the chat list already knows, reduced to the bit that can produce an edge.
public struct ActivityObservation: Sendable {
    public let profileID: String
    public let sessionID: String
    public let title: String
    public let isActive: Bool

    public init(profileID: String, sessionID: String, title: String, isActive: Bool) {
        self.profileID = profileID
        self.sessionID = sessionID
        self.title = title
        self.isActive = isActive
    }
}

/// Finds the moments worth a system notification in state the client already holds: a listing
/// row that stops being live, and the open conversation's turn end, permission ask, or question.
/// It only reports edges — the first look primes silently, so launching the app onto a pile of
/// finished sessions says nothing — and it never decides whether to actually notify: focus
/// gating belongs to the client, because only the client knows what the user is looking at.
public struct ActivityWatch: Sendable {
    private var listingActive: [String: Bool] = [:]
    private var listingPrimed = false
    private var openWasRunning: [String: Bool] = [:]
    private var notifiedPermissionIDs: Set<String> = []
    private var notifiedQuestionIDs: Set<String> = []

    public init() {}

    /// Turn-end edges across every session the list can see, except the open one — its own
    /// state stream reports faster and more precisely than a listing refresh ever can.
    public mutating func observeListing(
        _ rows: [ActivityObservation], openSessionID: String?
    ) -> [ActivityAlert] {
        var alerts: [ActivityAlert] = []
        var next: [String: Bool] = [:]
        for row in rows {
            let key = "\(row.profileID)/\(row.sessionID)"
            next[key] = row.isActive
            guard listingPrimed, row.sessionID != openSessionID,
                listingActive[key] == true, !row.isActive
            else { continue }
            alerts.append(
                ActivityAlert(
                    profileID: row.profileID, sessionID: row.sessionID,
                    identifier: "done:\(row.sessionID)",
                    title: row.title,
                    body: Localized.text("Your agent finished."),
                    reason: .turnEnded))
        }
        listingActive = next
        listingPrimed = true
        return alerts
    }

    /// Edges in the open conversation: the running turn ending, a new permission ask, a new
    /// question. Returns the alerts to raise and the identifiers of request notifications that
    /// stopped being true — an approval notice left standing after it was answered is a lie
    /// the user taps into and finds nothing.
    public mutating func observeConversation(
        profileID: String, sessionID: String, title: String, state: ConversationState
    ) -> (alerts: [ActivityAlert], withdrawals: [String]) {
        var alerts: [ActivityAlert] = []
        let isRunning = state.status == .running
        let key = "\(profileID)/\(sessionID)"
        if openWasRunning[key] == true, !isRunning {
            let failed = state.lastFailure != nil
            alerts.append(
                ActivityAlert(
                    profileID: profileID, sessionID: sessionID,
                    identifier: "done:\(sessionID)",
                    title: title,
                    body: failed
                        ? Localized.text("The turn failed.")
                        : Localized.text("Your agent finished."),
                    reason: failed ? .turnFailed : .turnEnded))
        }
        openWasRunning[key] = isRunning

        let permissionIDs = Set(state.pendingPermissions.map(\.id))
        for permission in state.pendingPermissions
        where !notifiedPermissionIDs.contains(permission.id) {
            notifiedPermissionIDs.insert(permission.id)
            let tool = permission.toolName ?? permission.title ?? Localized.text("a tool")
            alerts.append(
                ActivityAlert(
                    profileID: profileID, sessionID: sessionID,
                    identifier: "perm:\(permission.id)",
                    title: title,
                    body: Localized.text("Approval needed: %@", tool),
                    reason: .needsApproval, permission: permission))
        }

        let questions = state.pendingQuestions
        let questionIDs = Set(questions.map(\.id))
        for question in questions where !notifiedQuestionIDs.contains(question.id) {
            notifiedQuestionIDs.insert(question.id)
            let text = question.questions.first?.question ?? ""
            alerts.append(
                ActivityAlert(
                    profileID: profileID, sessionID: sessionID,
                    identifier: "question:\(question.id)",
                    title: title,
                    body: text.isEmpty
                        ? Localized.text("Your agent has a question.") : String(text.prefix(120)),
                    reason: .needsAnswer))
        }

        var withdrawals: [String] = []
        for id in notifiedPermissionIDs where !permissionIDs.contains(id) {
            withdrawals.append("perm:\(id)")
            notifiedPermissionIDs.remove(id)
        }
        for id in notifiedQuestionIDs where !questionIDs.contains(id) {
            withdrawals.append("question:\(id)")
            notifiedQuestionIDs.remove(id)
        }
        return (alerts, withdrawals)
    }
}
