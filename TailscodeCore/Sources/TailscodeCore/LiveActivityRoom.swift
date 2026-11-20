import CodingAgentKit
import Foundation

/// Which standing card gives way when iOS refuses another because the app already keeps as many
/// as it allows (five on the phones measured).
///
/// The person's own card comes first: a turn they sent, or one running in the chat they have on
/// screen, is `asked`, and a card the app opened by itself for a turn elsewhere — or that a server
/// started — is `followed`. An ending that has stood longest gives way to anything, one that waits
/// on the person last among endings; a followed card still running gives way only to an asked one,
/// the one that moved least recently first, and never while it waits on the person. An asked card
/// that is still running never gives way.
public enum LiveActivityRoom {
    public enum Claim: String, Sendable {
        case asked
        case followed
    }

    public struct Standing: Sendable, Equatable {
        public let sessionID: String
        public let claim: Claim
        public let endedAt: Date?
        public let movedAt: Date
        public let waitsOnYou: Bool

        public init(
            sessionID: String, claim: Claim, endedAt: Date?, movedAt: Date, waitsOnYou: Bool = false
        ) {
            self.sessionID = sessionID
            self.claim = claim
            self.endedAt = endedAt
            self.movedAt = movedAt
            self.waitsOnYou = waitsOnYou
        }
    }

    /// The conversation whose card goes so a card with `claim` can stand, or nil when nothing
    /// standing may give way to it.
    public static func yielding(_ standing: [Standing], to claim: Claim) -> String? {
        let endings = standing.compactMap { card in card.endedAt.map { (card, $0) } }
        if let ending = endings.min(by: { lhs, rhs in
            lhs.0.waitsOnYou != rhs.0.waitsOnYou ? !lhs.0.waitsOnYou : lhs.1 < rhs.1
        }) {
            return ending.0.sessionID
        }
        guard claim == .asked else { return nil }
        return standing
            .filter { $0.endedAt == nil && $0.claim == .followed && !$0.waitsOnYou }
            .min { $0.movedAt < $1.movedAt }?
            .sessionID
    }

    /// Whether the listing itself still says the conversation's turn is running: the server's own
    /// word where it gives one (claude-bridge says whether the turn is open, whatever agents or
    /// background work also run), and otherwise active with no work carried in the background and
    /// no agents out. A view model this device holds can still say running a moment after the turn
    /// ended, so a card is opened by itself only when the listing agrees; one opened on that
    /// moment is read or settled within the second and leaves an ended card behind.
    public static func listedRunning(_ session: AgentSession) -> Bool {
        if let turnOpen = session.turnOpen { return turnOpen }
        return session.isActive == true && (session.backgroundWork?.tasks ?? 0) == 0
            && (session.activeAgents ?? 0) == 0
    }
}
