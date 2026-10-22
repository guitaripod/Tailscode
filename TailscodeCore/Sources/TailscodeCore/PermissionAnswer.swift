import CodingAgentKit
import Foundation

/// Answering an approval from somewhere other than the chat that shows it: a notification button,
/// a banner. Whoever answers first settles it, so the second answer must find that out before it
/// asks the server again, and must tidy up after itself when it does.
///
/// The answer goes through the chat's own conversation when this process holds one — that is what
/// settles the card in the open chat in the same breath as the server hears it — and through the
/// backend alone only when nothing holds the chat.
public enum PermissionAnswer {
    /// Whether a request still waits on a person.
    public enum Standing: Sendable, Equatable {
        case pending
        /// The conversation has read its transcript and the request is not among those waiting:
        /// somebody answered it, or the turn moved on.
        case settled
        /// The conversation has not read the server yet, so absence says nothing.
        case unknown
    }

    public enum Outcome: Sendable, Equatable {
        case answered
        /// Somebody else had answered already; nothing was sent.
        case settled
    }

    public enum Failure: Error, Sendable {
        case noRoute
    }

    public static func standing(
        of permission: PermissionRequest, in state: ConversationState
    ) -> Standing {
        if state.pendingPermissions.contains(where: { $0.id == permission.id }) { return .pending }
        return state.hasLoadedTranscript ? .settled : .unknown
    }

    /// Answers `permission`, or finds it already answered. A request the open chat has settled is
    /// not sent again, and one that settles while the answer is in flight turns a failure into
    /// `settled` rather than into an error: the notice then withdraws instead of lingering over a
    /// question nobody can answer any more.
    public static func answer(
        _ permission: PermissionRequest, decision: PermissionDecision,
        through conversation: AgentConversation?, backend: (any CodingAgentBackend)?
    ) async throws -> Outcome {
        if let conversation {
            let before = standing(of: permission, in: await conversation.state)
            if before == .settled { return .settled }
            do {
                try await conversation.respond(to: permission, decision: decision)
                return .answered
            } catch {
                let after = standing(of: permission, in: await conversation.state)
                if before == .pending, after == .settled { return .settled }
                throw error
            }
        }
        guard let backend else { throw Failure.noRoute }
        try await backend.respond(to: permission, decision: decision)
        return .answered
    }
}
