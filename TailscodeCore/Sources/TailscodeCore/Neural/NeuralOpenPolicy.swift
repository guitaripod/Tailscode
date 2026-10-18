import Foundation

/// Which brain of a conversation is open, as a rule rather than as view state: the same answer on
/// every client, from the turns the conversation holds and what the person has chosen.
///
/// Every turn is a card until the person opens it, the latest and the running one included: there
/// is no "open the latest" rule and no setting for one. An open brain is the person's act (a
/// press on a card, a zone chip, Find landing on a step, a drive hook), opening one closes the
/// one that was open, so a conversation never holds two open brains, and the choice is kept for
/// the conversation: a new turn arriving never opens itself and never closes what the person
/// opened, so an older turn stays open until they close it or open another. A relaunch starts
/// with every brain closed because the choices are memory only.
///
/// Behaviour change from the earlier rule (the latest turn open by default, a choice valid only
/// while the turn it was made against was the latest): a conversation with no choices has no open
/// brain, and a choice no longer goes stale when a newer turn starts. `toggle` no longer writes
/// an entry for the latest turn.
public struct NeuralOpenPolicy: Sendable, Equatable {
    /// The conversation's turns, oldest first.
    public var turnIDs: [String]
    /// The newest turn. Nil for a conversation with none.
    public var latest: String?
    /// Whether the newest turn is mid-flight. The rule does not depend on it; it says whether the
    /// open brain is the live one.
    public var isRunning: Bool
    /// What the person chose, by turn id.
    public var choices: [String: Bool]

    public init(
        turnIDs: [String], latest: String? = nil, isRunning: Bool = false,
        choices: [String: Bool] = [:]
    ) {
        self.turnIDs = turnIDs
        self.latest = latest ?? turnIDs.last
        self.isRunning = isRunning
        self.choices = choices
    }

    public init(turns: [NeuralTurn], isRunning: Bool = false, choices: [String: Bool] = [:]) {
        self.init(turnIDs: turns.map(\.id), isRunning: isRunning, choices: choices)
    }

    public static let rowPrefix = "brain:"

    /// A turn with at least one step is a brain. Any other draws nothing and the client keeps its
    /// ordinary rows.
    public static func isBrain(turn: NeuralTurn) -> Bool { !turn.steps.isEmpty }

    /// The identity of a turn's brain row, stable across rebuilds.
    public static func rowID(turn: NeuralTurn) -> String { rowID(turnID: turn.id) }

    public static func rowID(turnID: String) -> String { rowPrefix + turnID }

    /// The turn a brain row stands for, nil for any other row id.
    public static func turnID(forRowID rowID: String) -> String? {
        guard rowID.hasPrefix(rowPrefix) else { return nil }
        let id = String(rowID.dropFirst(rowPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Whether the person has chosen anything about a turn this conversation holds.
    public var choicesAreCurrent: Bool {
        let known = Set(turnIDs)
        return choices.keys.contains { known.contains($0) }
    }

    /// The choices that still mean something: never one for a turn the conversation no longer
    /// holds.
    public var currentChoices: [String: Bool] {
        let known = Set(turnIDs)
        return choices.filter { known.contains($0.key) }
    }

    /// The one turn whose brain is open, nil until the person opens one or after they close it.
    /// Should a stored choice mark two turns open, the newest wins.
    public var openTurnID: String? {
        let current = currentChoices
        var open: String?
        for id in turnIDs where current[id] == true { open = id }
        return open
    }

    public func isOpen(turnID: String) -> Bool { openTurnID == turnID }

    /// Whether the open brain is the one still being written.
    public var openBrainIsLive: Bool { isRunning && openTurnID != nil && openTurnID == latest }

    /// The choices after the person presses a brain's chevron: it opens if it was closed and
    /// closes if it was open, and opening one closes the other.
    public func toggle(turnID: String) -> [String: Bool] {
        var next = currentChoices
        guard turnIDs.contains(turnID) else { return next }
        let wasOpen = openTurnID == turnID
        for (id, chosen) in next where chosen { next[id] = false }
        next[turnID] = !wasOpen
        return next
    }
}
