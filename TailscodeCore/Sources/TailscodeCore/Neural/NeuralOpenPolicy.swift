import Foundation

/// Which brain of a conversation is open, as a rule rather than as view state: the same answer on
/// every client, from the turns the conversation holds and what the person has chosen.
///
/// The latest turn is open until a newer turn starts or the person closes it; opening another turn
/// closes the one that was open, so a conversation never holds two open brains; and a choice
/// outranks the default only while the turn it was made against is still the latest. A choice is
/// remembered as a dictionary of turn id to open or closed, and `toggle` always writes the latest
/// turn's own entry beside the one the person pressed. That entry is the proof of which turn was
/// the latest when the choice was made: when a newer turn starts it has no entry, every older
/// choice is stale, and only the default applies.
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

    /// Whether the person's choices still describe this conversation: they were made while the
    /// current latest turn was the latest.
    public var choicesAreCurrent: Bool {
        guard let latest else { return false }
        return choices[latest] != nil
    }

    /// The choices that still mean something: all of them while they are current, none once a
    /// newer turn has started, and never one for a turn the conversation no longer holds.
    public var currentChoices: [String: Bool] {
        guard choicesAreCurrent else { return [:] }
        let known = Set(turnIDs)
        return choices.filter { known.contains($0.key) }
    }

    /// The one turn whose brain is open, nil when the person closed it or the conversation is empty.
    public var openTurnID: String? {
        let current = currentChoices
        var open: String?
        for id in turnIDs where isChosenOpen(id, current: current) { open = id }
        return open
    }

    public func isOpen(turnID: String) -> Bool { openTurnID == turnID }

    /// Whether the open brain is the one still being written.
    public var openBrainIsLive: Bool { isRunning && openTurnID != nil && openTurnID == latest }

    /// The choices after the person presses a brain's chevron: it opens if it was closed and
    /// closes if it was open, opening one closes the other, and the latest turn always carries
    /// its own entry.
    public func toggle(turnID: String) -> [String: Bool] {
        var next = currentChoices
        guard turnIDs.contains(turnID) else { return next }
        let open = openTurnID
        if open == turnID {
            next[turnID] = false
        } else {
            if let open { next[open] = false }
            next[turnID] = true
        }
        if let latest, next[latest] == nil { next[latest] = false }
        return next
    }

    private func isChosenOpen(_ id: String, current: [String: Bool]) -> Bool {
        if id == latest { return current[id] ?? true }
        return current[id] ?? false
    }
}
