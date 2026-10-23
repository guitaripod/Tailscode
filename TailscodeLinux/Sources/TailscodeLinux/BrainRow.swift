import CodingAgentKit
import Foundation
import TailscodeCore

/// What a turn's brain row is: everything the row draws and nothing it does not. The widget under
/// it is kept while this value changes (a step arriving, a tool ending, a theme), so the value is
/// what the diff compares and the widget restates itself from it.
struct BrainRow: Hashable {
    let slot: NeuralTurnSlot
    var open: Bool
    var showRows: Bool
    /// The words of the turn's answer once it has settled, which the provenance chips are read from.
    var answer: String
    var look: String
    /// The words of the message that began the turn, which the poster quotes; read once the turn
    /// has settled and is the one open.
    var prompt: String?

    var id: String { slot.outline.id }

    /// The turn read into steps, which reads them the first time a view asks.
    var turn: NeuralTurn { slot.turn }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (left: BrainRow, right: BrainRow) -> Bool {
        left.open == right.open && left.showRows == right.showRows && left.answer == right.answer
            && left.look == right.look && left.prompt == right.prompt
            && (left.slot === right.slot || left.slot.turn == right.slot.turn)
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
        var outline: NeuralTurnOutline
        var anchor: String?
        var members: Set<String>
        var messages: Set<String>
    }

    var turnIDs: [String] = []
    var rows: [String: BrainRow] = [:]
    var anchors: [String: String] = [:]
    var members: [String: Set<String>] = [:]
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
            if let part, let owner = messageTurns[message.id], members[owner]?.contains(part) == true,
                self.rows[owner]?.showRows == false
            {
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
    private var members: [String: Set<String>] = [:]
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
        members = [:]
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
        let list = cache.partitionList(messages: messages, running: running, awaiting: awaiting)
        let slots = Self.droppingLeadingPartial(
            (0..<list.count).map { list.slot(at: $0) }.filter { $0.outline.isBrain },
            messages: messages)
        let policy = NeuralOpenPolicy(
            turnIDs: slots.map { $0.outline.id }, isRunning: running, choices: settings.choices)
        self.policy = policy
        let openID = policy.openTurnID
        var alive = Set<String>()
        for slot in slots {
            let outline = slot.outline
            alive.insert(outline.id)
            if let held = records[outline.id], held.outline == outline { continue }
            remove(outline.id)
            let record = BrainPass.Record(
                outline: outline, anchor: outline.anchor, members: outline.memberPartIDs,
                messages: outline.memberMessageIDs)
            records[outline.id] = record
            if let anchor = outline.anchor { anchors[anchor] = outline.id }
            members[outline.id] = record.members
            for message in record.messages { messageTurns[message] = outline.id }
        }
        for stale in records.keys where !alive.contains(stale) { remove(stale) }
        var pass = BrainPass()
        pass.turnIDs = slots.map { $0.outline.id }
        pass.anchors = anchors
        pass.members = members
        pass.messageTurns = messageTurns
        for slot in slots {
            let outline = slot.outline
            let isOpen = outline.id == openID
            pass.rows[outline.id] = BrainRow(
                slot: slot, open: isOpen, showRows: settings.rowsShown.contains(outline.id),
                answer: isOpen && outline.outcome != .running
                    ? Self.answer(of: outline, in: messages) : "",
                look: settings.look,
                prompt: isOpen ? Self.prompt(before: outline.id, in: messages) : nil)
        }
        return pass
    }

    /// A window of the conversation that starts in the middle of a turn gives that turn the id of
    /// the first message it can see, and the id changes every time the window slides by a message,
    /// which destroyed and rebuilt its row at the top on every arrival. The leading partial turn
    /// keeps today's rows instead; every turn after it begins at a message the person wrote and
    /// has an id that stays.
    static func droppingLeadingPartial(
        _ turns: [NeuralTurnSlot], messages: [ChatMessage]
    ) -> [NeuralTurnSlot] {
        guard let first = messages.first, first.role != .user, let lead = turns.first,
            lead.outline.id == first.id
        else { return turns }
        return Array(turns.dropFirst())
    }

    private func remove(_ turnID: String) {
        guard let record = records.removeValue(forKey: turnID) else { return }
        if let anchor = record.anchor, anchors[anchor] == turnID { anchors[anchor] = nil }
        members[turnID] = nil
        for message in record.messages where messageTurns[message] == turnID {
            messageTurns[message] = nil
        }
    }

    /// The words of the user message that began a turn: what the poster quotes.
    private static func prompt(before turnID: String, in messages: [ChatMessage]) -> String? {
        guard let first = messages.lastIndex(where: { $0.id == turnID }),
            let asked = messages[..<first].last(where: { $0.role == .user })
        else { return nil }
        let words = asked.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// The text of the parts a turn ended on, in order.
    private static func answer(of turn: NeuralTurnOutline, in messages: [ChatMessage]) -> String {
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
