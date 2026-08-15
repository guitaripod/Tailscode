import CodingAgentKit
import Foundation

/// What a device currently believes a conversation has cost, and which conversation that is.
///
/// A per-turn account is a fact about the conversation, not about the device that happened to run
/// it. The panel used to be one expression — the server's report, or else whatever transcript this
/// process had in memory at that instant — evaluated once when a chat opened. On the machine that
/// started the session both halves were true; on any other, the transcript had not arrived yet, the
/// derivation returned nothing, and nothing ever asked again. So the turn-by-turn chart existed on
/// exactly one desk.
///
/// Two rules fix that, and both are about what may *not* be written:
/// - A poll that came back with nothing changes nothing. A 404, a dropped connection or a request
///   that raced a restart is not news that the money is gone.
/// - A reading belongs to one session id. Panes are reused across chats, so a reading that outlived
///   its conversation would show one chat's money under another's name — a worse bug than the
///   silence it replaced.
public struct SpendReading: Sendable, Equatable {
    private var session: String = ""
    private var reported: SessionSpend?
    private var derived: SessionSpend?
    private var signature: String = ""

    public init() {}

    /// The server's own account when there is one, else what this device could work out. A server
    /// that reads the CLI's transcript knows about turns run from a terminal and knows the token
    /// tiers; a transcript summed here knows neither, so it never outranks a report.
    public var value: SessionSpend? { reported ?? derived }

    /// - Returns: whether ``value`` changed, so a client repaints only when there is something new.
    @discardableResult
    public mutating func note(report: SessionSpendReport?, for sessionID: String) -> Bool {
        adopt(sessionID)
        guard let report else { return false }
        let before = value
        reported = SessionSpend(report: report)
        return before != value
    }

    /// The fallback account, for a backend that prices its own messages but has no spend route.
    /// Recomputed only when the transcript actually moved: this is asked on every state emission,
    /// which during a turn is tens of times a second.
    @discardableResult
    public mutating func note(messages: [ChatMessage], for sessionID: String) -> Bool {
        adopt(sessionID)
        guard reported == nil else { return false }
        let fresh = Self.signature(of: messages)
        guard fresh != signature else { return false }
        signature = fresh
        guard let recomputed = SessionSpend(messages: messages) else { return false }
        let before = value
        derived = recomputed
        return before != value
    }

    /// A pane pointed at another conversation is holding another conversation's money. Forgetting
    /// happens here rather than in each client's `open`, so it cannot be forgotten in one of them.
    private mutating func adopt(_ sessionID: String) {
        guard session != sessionID else { return }
        session = sessionID
        reported = nil
        derived = nil
        signature = ""
    }

    private static func signature(of messages: [ChatMessage]) -> String {
        guard let last = messages.last else { return "0" }
        return "\(messages.count)/\(last.id)/\(last.completedAt?.timeIntervalSince1970 ?? 0)"
    }
}
