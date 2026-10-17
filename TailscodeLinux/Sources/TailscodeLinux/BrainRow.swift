import CodingAgentKit
import Foundation
import TailscodeCore

/// What a turn's brain row is: everything the row draws and nothing it does not. The widget under
/// it is kept while this value changes (a step arriving, a tool ending, a theme), so the value is
/// what the diff compares and the widget restates itself from it.
struct BrainRow: Hashable {
    let turn: NeuralTurn
    var open: Bool
    var showRows: Bool
    /// The words of the turn's answer once it has settled, which the provenance chips are read from.
    var answer: String
    var look: String

    var id: String { turn.id }

    func hash(into hasher: inout Hasher) {
        hasher.combine(turn.id)
    }
}

/// What the row builder needs to know about the brains, captured on the main loop whenever it
/// changes so the build never reads a pane from another thread.
struct BrainBuildSettings: Sendable, Equatable {
    var style: ActivityStyle = .lines
    var choices: [String: Bool] = [:]
    var rowsShown: Set<String> = []
    var look = ""
}

/// What the machine is waiting on for a turn, read from the state a row build starts from.
enum BrainAwaiting {
    static func read(_ state: ConversationState) -> NeuralAwaiting {
        NeuralAwaiting(
            approvals: Set(state.pendingPermissions.map(\.id)),
            answers: Set(state.pendingQuestions.map(\.id)),
            interrupted: state.interruption.map { [$0.turnID] } ?? [])
    }
}

/// The brains of one conversation, laid among its rows. Built per row build from the turns the
/// cache read, and holds the dictionaries a message's rows are filtered and anchored by. Turns that
/// did not change are carried over, so a streamed token costs the turn that is being written and a
/// pass over the turns' values, never a walk over the conversation's parts.
struct BrainPass {
    struct Record {
        var turn: NeuralTurn
        var anchor: String?
        var members: Set<String>
        var messages: Set<String>
    }

    var turns: [NeuralTurn] = []
    var rows: [String: BrainRow] = [:]
    var anchors: [String: String] = [:]
    var skip: [String: String] = [:]
    var messageTurns: [String: String] = [:]
    var emitted: Set<String> = []

    var isEmpty: Bool { rows.isEmpty }

    /// Rows for one message with the parts the brains consume taken out and the turn's brain put
    /// where its first part was. A message no brain touches passes through as it is.
    mutating func apply(to rows: [TranscriptRow], of message: ChatMessage) -> [TranscriptRow] {
        guard messageTurns[message.id] != nil else { return rows }
        let keys = message.parts.map { "\(message.id):\($0.id)" }
        var out: [TranscriptRow] = []
        out.reserveCapacity(rows.count + 1)
        var droppedLast = false
        for row in rows {
            let part = Self.origin(of: row.key, among: keys)
            if let part, let owner = anchors[part], !emitted.contains(owner),
                let brain = self.rows[owner]
            {
                emitted.insert(owner)
                out.append(TranscriptRow(key: NeuralOpenPolicy.rowID(turnID: owner), kind: .brain(brain)))
            }
            if let part, let owner = skip[part], self.rows[owner]?.showRows == false {
                droppedLast = true
                continue
            }
            if case .linkRail = row.kind, droppedLast { continue }
            droppedLast = false
            out.append(row)
        }
        let anchoredHere = keys.compactMap { anchors[$0] }
        for owner in anchoredHere where !emitted.contains(owner) {
            guard let brain = self.rows[owner] else { continue }
            emitted.insert(owner)
            out.append(TranscriptRow(key: NeuralOpenPolicy.rowID(turnID: owner), kind: .brain(brain)))
        }
        return out
    }

    /// The part a row was made from: the longest `messageID:partID` the row's key starts with.
    static func origin(of key: String, among parts: [String]) -> String? {
        var best: String?
        for part in parts where key == part || key.hasPrefix(part + ":") {
            if best == nil || part.count > best!.count { best = part }
        }
        return best
    }
}

/// A conversation's brains kept between builds: the turn cache, and what each turn's last reading
/// was, so only a turn that changed has its parts and anchor read again.
final class BrainLedger: @unchecked Sendable {
    private let cache = NeuralTurnCache()
    private var records: [String: BrainPass.Record] = [:]
    private var anchors: [String: String] = [:]
    private var skip: [String: String] = [:]
    private var messageTurns: [String: String] = [:]
    private(set) var policy: NeuralOpenPolicy?

    /// How many turns the ledger has read from their messages: the harness's proof that a token
    /// reads one turn.
    var turnPartitions: Int { cache.turnPartitions }
    var turnReuses: Int { cache.turnReuses }

    func reset() {
        cache.reset()
        records = [:]
        anchors = [:]
        skip = [:]
        messageTurns = [:]
        policy = nil
    }

    /// The pass for these messages, or nil when brains are off.
    func pass(
        messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting,
        settings: BrainBuildSettings
    ) -> BrainPass? {
        guard settings.style == .brain else {
            if !records.isEmpty { reset() }
            return nil
        }
        let turns = cache.partition(messages: messages, running: running, awaiting: awaiting)
            .filter(NeuralOpenPolicy.isBrain(turn:))
        let policy = NeuralOpenPolicy(
            turnIDs: turns.map(\.id), isRunning: running, choices: settings.choices)
        self.policy = policy
        let openID = policy.openTurnID
        var alive = Set<String>()
        for turn in turns {
            alive.insert(turn.id)
            if records[turn.id]?.turn == turn { continue }
            remove(turn.id)
            let plan = NeuralRowPlan(turns: [turn])
            let anchor = plan.anchors.keys.first
            let record = BrainPass.Record(
                turn: turn, anchor: anchor, members: plan.skip,
                messages: Set(turn.steps.map(\.messageID)))
            records[turn.id] = record
            if let anchor { anchors[anchor] = turn.id }
            for part in record.members { skip[part] = turn.id }
            for message in record.messages { messageTurns[message] = turn.id }
        }
        for stale in records.keys where !alive.contains(stale) { remove(stale) }
        var pass = BrainPass()
        pass.turns = turns
        pass.anchors = anchors
        pass.skip = skip
        pass.messageTurns = messageTurns
        for turn in turns {
            let isOpen = turn.id == openID
            pass.rows[turn.id] = BrainRow(
                turn: turn, open: isOpen, showRows: settings.rowsShown.contains(turn.id),
                answer: isOpen && turn.outcome != .running ? Self.answer(of: turn, in: messages) : "",
                look: settings.look)
        }
        return pass
    }

    private func remove(_ turnID: String) {
        guard let record = records.removeValue(forKey: turnID) else { return }
        if let anchor = record.anchor, anchors[anchor] == turnID { anchors[anchor] = nil }
        for part in record.members where skip[part] == turnID { skip[part] = nil }
        for message in record.messages where messageTurns[message] == turnID {
            messageTurns[message] = nil
        }
    }

    /// The text of the parts a turn ended on, in order.
    private static func answer(of turn: NeuralTurn, in messages: [ChatMessage]) -> String {
        guard !turn.answerPartIDs.isEmpty else { return "" }
        var words: [String] = []
        for id in turn.answerPartIDs {
            for message in messages.reversed() where id.hasPrefix(message.id + ":") {
                let partID = String(id.dropFirst(message.id.count + 1))
                if let part = message.parts.first(where: { $0.id == partID }),
                    case .text(let text) = part.kind
                {
                    words.append(AgentMarkup.strip(text).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                break
            }
        }
        return words.joined(separator: "\n\n")
    }
}
