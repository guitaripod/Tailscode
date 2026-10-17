import AppKit
import CodingAgentKit
import TailscodeCore

/// What a brain row is as a value, so the transcript's keyed diff can tell a brain that changed
/// from one that did not without reading a model. The turn is the identity; whether it is open,
/// whether it lists its old rows and the revision of what the store holds for it are what repaint
/// it, and the view is restated in place rather than rebuilt, because the head it holds is the one
/// expensive thing in the row.
struct BrainRow: Hashable {
    let turnID: String
    let isOpen: Bool
    let showsRows: Bool
    let revision: Int
}

/// Whether the brain can be drawn on this Mac at all, and whether the person wants it. Any answer
/// of no leaves the transcript exactly as it was before the brain existed.
@MainActor
enum MacBrain {
    /// A GPU that takes the head's texture format, the shaders, and the textures in the bundle.
    static var isAvailable: Bool { NeuralHeadView.isSupported && assetsPresent }

    static var assetsPresent: Bool { assetsExist }

    private static let assetsExist: Bool = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("ntex", isDirectory: true)
        else { return false }
        return FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("chassis.ntex").path)
    }()

    /// A harness holds the brain off to prove the Lines style gives today's rows.
    nonisolated(unsafe) static var forcedStyle: ActivityStyle?

    static var style: ActivityStyle { forcedStyle ?? ActivityStyleSetting.current }

    static var isEnabled: Bool { NeuralRowPlan.isEnabled(style: style) && isAvailable }
}

/// The brain's state for one pane: the turns the conversation holds read into steps, a model for
/// each turn that is a brain, which of them is open and which list their old rows.
///
/// The transcript is rebuilt on every streamed token, so nothing here may cost the size of the
/// conversation. `NeuralTurnCache` reads again only the turn whose messages changed, a turn is
/// compared with the one held for it (arrays share their storage, so an unchanged turn compares
/// in a pointer test), and only a turn that really changed updates its model and takes a new
/// revision. The messages a turn's rows come from are found through a dictionary kept in step
/// with the turns, never by walking them.
@MainActor
final class BrainStore {
    struct Entry {
        var turn: NeuralTurn
        var model: NeuralBrainModel
        var context: NeuralBrainContext
        var anchor: String?
        var anchorMessageID: String?
        var messageIDs: Set<String>
        var boardKeys: Set<String>
        var answer: String
        var prompt: String?
        var revision: Int
    }

    private let cache = NeuralTurnCache()
    private(set) var entries: [String: Entry] = [:]
    private(set) var order: [String] = []
    private var messageTurn: [String: String] = [:]
    private var boardOwner: [String: String] = [:]
    private var arrival: [String] = []
    private var counter = 0

    private(set) var choices: [String: Bool] = [:]
    private(set) var rowsShown: Set<String> = []
    private(set) var openTurnID: String?
    private(set) var latestTurnID: String?
    private var turnIDs: [String] = []
    private(set) var liveContext = NeuralBrainContext.none
    private(set) var isRunning = false

    /// Asked to rebuild the rows after a choice the person made: a brain opened or closed, the old
    /// rows listed or put away.
    var onChange: (() -> Void)?

    /// The views that stand for a turn, weakly, so the store can restate them, park their heads
    /// when the pane parks and release the textures when the last one closes.
    let views = NSHashTable<BrainRowView>.weakObjects()

    /// The most turns the store keeps models for. A pane that has shown a day of chats keeps the
    /// newest, never the day.
    static let capacity = 400

    /// How many turns the store has read from their messages, for the harness that proves a
    /// streamed token reads one turn and never the conversation.
    var partitions: Int { cache.turnPartitions }

    /// How the store reads a conversation: false leaves every row where it was.
    var isActive: Bool { MacBrain.isEnabled }

    /// Reads the conversation's turns, brings each model to its turn and forgets nothing the open
    /// pages still hold. Returns nothing: the builder asks the store what to do per message.
    func read(messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting) {
        guard isActive else {
            clear()
            return
        }
        isRunning = running
        if let kept = settledPrefix(for: messages, awaiting: awaiting),
            let tail = NeuralTurns.partition(
                messages: kept.tailAssistants, running: running, awaiting: awaiting
            ).first
        {
            adopt(
                turns: kept.held.prefixTurns + [tail], keptOrder: kept.held.prefixBrainOrder,
                fresh: [tail], running: running, messages: messages)
            return
        }
        let turns = cache.partition(messages: messages, running: running, awaiting: awaiting)
        adopt(turns: turns, keptOrder: nil, fresh: turns, running: running, messages: messages)
        remember(prefixOf: messages, turns: turns, awaiting: awaiting)
    }

    /// The conversation as it stood before its newest question, held so that a token arriving in the
    /// newest turn reads that turn alone and not every turn above it.
    private struct SettledPrefix {
        let messages: [ChatMessage]
        let ids: Set<String>
        let prefixTurns: [NeuralTurn]
        let prefixBrainOrder: [String]
        let awaiting: NeuralAwaiting
    }

    private var settled: SettledPrefix?

    /// The held prefix when every message above the newest question is the message it was and the
    /// newest turn brings nothing the prefix already held; with the newest turn's own assistant
    /// messages, which are all that need reading.
    private func settledPrefix(
        for messages: [ChatMessage], awaiting: NeuralAwaiting
    ) -> (held: SettledPrefix, tailAssistants: [ChatMessage])? {
        guard let held = settled, held.awaiting == awaiting,
            let cut = messages.lastIndex(where: { $0.role == .user }), cut == held.messages.count
        else { return nil }
        for index in 0..<cut where held.messages[index] != messages[index] { return nil }
        var seen = Set<String>()
        var assistants: [ChatMessage] = []
        for message in messages[cut...] where message.role == .assistant {
            guard !held.ids.contains(message.id), seen.insert(message.id).inserted else { return nil }
            assistants.append(message)
        }
        return assistants.isEmpty ? nil : (held, assistants)
    }

    private func remember(prefixOf messages: [ChatMessage], turns: [NeuralTurn], awaiting: NeuralAwaiting) {
        guard let cut = messages.lastIndex(where: { $0.role == .user }), cut > 0,
            let last = turns.last,
            messages[cut...].contains(where: { $0.role == .assistant && $0.id == last.id })
        else {
            settled = nil
            return
        }
        var ids = Set<String>()
        ids.reserveCapacity(cut)
        for message in messages[..<cut] { ids.insert(message.id) }
        let prefix = Array(messages[..<cut])
        settled = SettledPrefix(
            messages: prefix, ids: ids, prefixTurns: Array(turns.dropLast()),
            prefixBrainOrder: order.last == last.id ? Array(order.dropLast()) : order,
            awaiting: awaiting)
    }

    /// Brings the entries to the turns just read. `keptOrder` is the brains above the newest turn
    /// when only that one was read, and `fresh` the turns whose entries need looking at.
    private func adopt(
        turns: [NeuralTurn], keptOrder: [String]?, fresh: [NeuralTurn], running: Bool,
        messages: [ChatMessage]
    ) {
        latestTurnID = turns.last?.id
        turnIDs = turns.map(\.id)
        openTurnID = NeuralOpenPolicy(
            turnIDs: turnIDs, isRunning: running, choices: choices
        ).openTurnID
        var ordered: [String] = keptOrder ?? []
        for turn in fresh where NeuralOpenPolicy.isBrain(turn: turn) {
            ordered.append(turn.id)
            let context = turn.id == latestTurnID ? liveContext : NeuralBrainContext.none
            if entries[turn.id] != nil {
                guard entries[turn.id]!.turn != turn || entries[turn.id]!.context != context else {
                    continue
                }
                forget(entries[turn.id]!)
                entries[turn.id]!.model.update(turn: turn, context: context)
                entries[turn.id]!.turn = turn
                entries[turn.id]!.context = context
                finish(&entries[turn.id]!, messages: messages)
                remember(entries[turn.id]!, id: turn.id)
            } else {
                var made = Entry(
                    turn: turn, model: NeuralBrainModel(turn: turn, context: context),
                    context: context, anchor: nil, anchorMessageID: nil, messageIDs: [],
                    boardKeys: [], answer: "", prompt: Self.prompt(before: turn, in: messages),
                    revision: 0)
                finish(&made, messages: messages)
                entries[turn.id] = made
                remember(made, id: turn.id)
                arrival.append(turn.id)
            }
        }
        order = ordered
        if arrival.count > Self.capacity { evict() }
    }

    /// Holds the live turn's context: what the machine is doing, how full the window is, whether a
    /// call is open. A turn that is not the newest carries none of it. Returns whether the model
    /// of the newest brain changed, so a caller restates only then.
    @discardableResult
    func setContext(_ context: NeuralBrainContext) -> Bool {
        guard context != liveContext else { return false }
        liveContext = context
        guard let id = latestTurnID, entries[id] != nil, entries[id]!.context != context else {
            return false
        }
        let turn = entries[id]!.turn
        entries[id]!.model.update(turn: turn, context: context)
        entries[id]!.context = context
        return true
    }

    func clear() {
        settled = nil
        guard !entries.isEmpty || !order.isEmpty else { return }
        entries = [:]
        order = []
        messageTurn = [:]
        boardOwner = [:]
        arrival = []
        openTurnID = nil
        latestTurnID = nil
    }

    func entry(_ turnID: String) -> Entry? { entries[turnID] }

    /// Changes one model in place and returns what the change answered. A hover, a pin, a replay.
    @discardableResult
    func withModel<Value>(
        _ turnID: String, _ body: (inout NeuralBrainModel) -> Value
    ) -> Value? {
        guard entries[turnID] != nil else { return nil }
        return body(&entries[turnID]!.model)
    }

    func model(_ turnID: String) -> NeuralBrainModel? { entries[turnID]?.model }

    func isOpen(_ turnID: String) -> Bool { openTurnID == turnID }

    func row(forTurn turnID: String) -> TranscriptRow? {
        guard let held = entries[turnID] else { return nil }
        return TranscriptRow(
            key: NeuralOpenPolicy.rowID(turnID: turnID),
            kind: .brain(
                BrainRow(
                    turnID: turnID, isOpen: isOpen(turnID), showsRows: rowsShown.contains(turnID),
                    revision: held.revision)))
    }

    /// The person pressed a brain's line: it opens if it was closed and closes if it was open, and
    /// opening one closes the other. The choice is remembered for as long as the pane lives.
    func toggleOpen(_ turnID: String) {
        guard latestTurnID != nil else { return }
        choices = NeuralOpenPolicy(
            turnIDs: turnIDs, isRunning: isRunning, choices: choices
        ).toggle(turnID: turnID)
        openTurnID = NeuralOpenPolicy(
            turnIDs: turnIDs, isRunning: isRunning, choices: choices
        ).openTurnID
        onChange?()
    }

    /// Rows puts the steps' old rows inline under that turn's brain, and puts them away again.
    func toggleRows(_ turnID: String) {
        if rowsShown.contains(turnID) { rowsShown.remove(turnID) } else { rowsShown.insert(turnID) }
        onChange?()
    }

    func showsRows(_ turnID: String) -> Bool { rowsShown.contains(turnID) }

    func ownsMessage(_ messageID: String) -> Bool { messageTurn[messageID] != nil }

    /// The words find reads in a brain: every step's tool, argument, thought and printed lines.
    func searchText(turnID: String) -> String {
        guard let held = entries[turnID] else { return "" }
        return held.turn.steps.map { step in
            [step.title, step.detail, step.text, step.outputLines.joined(separator: " ")]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: " ")
    }

    /// Brings every view up to the models, for a change the rows cannot carry: the machine's
    /// state, the window's fill, a call.
    func restateViews() {
        for view in views.allObjects { view.refresh() }
    }

    /// The newest head while its turn is running: its duration moves once a second with no state to
    /// carry it, so the pane's own second asks for it.
    func restateLive() {
        guard isRunning, let id = latestTurnID else { return }
        for view in views.allObjects where view.row.turnID == id { view.refresh() }
    }

    /// A pane that parks gives up every head it owns, and the process's textures with the last of
    /// them; unparked, the open brain draws again.
    func parkViews(_ parked: Bool) {
        for view in views.allObjects { view.setParked(parked) }
    }

    /// One number that changes when the way a message's rows are shaped changes: the turn it is in
    /// moved, or the person asked for its old rows.
    func stamp(forMessage messageID: String) -> Int? {
        guard let turnID = messageTurn[messageID], let held = entries[turnID] else { return nil }
        var hasher = Hasher()
        hasher.combine(turnID)
        hasher.combine(held.revision)
        hasher.combine(rowsShown.contains(turnID))
        hasher.combine(openTurnID == turnID)
        return hasher.finalize()
    }

    /// A message's folded rows with the brain's turn applied: the rows the brain consumes go, and
    /// the brain's own row stands where the turn's first step was. Card rows (an agent, a workflow,
    /// a board, a question) stay, each at its own place.
    func shape(_ rows: [TranscriptRow], of message: ChatMessage) -> [TranscriptRow] {
        guard let turnID = messageTurn[message.id], let held = entries[turnID] else { return rows }
        let listsRows = rowsShown.contains(turnID)
        let needsBrain = held.anchorMessageID == message.id
        guard needsBrain || !listsRows else { return rows }
        let keys = message.parts.map { "\(message.id):\($0.id)" }
        let anchorIndex = needsBrain ? held.anchor.flatMap { keys.firstIndex(of: $0) } : nil
        var shaped: [TranscriptRow] = []
        shaped.reserveCapacity(rows.count + 1)
        var placed = !needsBrain
        for row in rows {
            let part = Self.partIndex(of: row.key, among: keys)
            if !placed, let anchorIndex, let part, part >= anchorIndex {
                if let brain = self.row(forTurn: turnID) { shaped.append(brain) }
                placed = true
            }
            if !listsRows, let part, held.turn.memberPartIDs.contains(keys[part]) { continue }
            shaped.append(row)
        }
        if !placed, let brain = self.row(forTurn: turnID) { shaped.append(brain) }
        return shaped
    }

    /// Whether a one-line tool row is an earlier call on the task board, whose steps belong to the
    /// brain: the board card keeps the last call, and the others are nodes.
    func isSupersededBoardCall(_ key: String) -> Bool {
        guard let owner = boardOwner[key] else { return false }
        return !rowsShown.contains(owner)
    }

    /// The index of the part a row was folded from, when it was folded from one: a row's key is
    /// its part's key alone or with a suffix after a colon (a paragraph, a rail).
    static func partIndex(of rowKey: String, among partKeys: [String]) -> Int? {
        let row = rowKey.utf8
        for (index, key) in partKeys.enumerated() {
            let part = key.utf8
            guard row.count >= part.count, row.starts(with: part) else { continue }
            if row.count == part.count { return index }
            let next = row[row.index(row.startIndex, offsetBy: part.count)]
            if next == UInt8(ascii: ":") { return index }
        }
        return nil
    }

    /// The question or approval that waits on the person, read from the state as the pane holds
    /// it: the latest call the machine reports waiting is marked on its node.
    static func awaiting(for state: ConversationState) -> NeuralAwaiting {
        var awaiting = NeuralAwaiting()
        let assistant = state.messages.last(where: { $0.role == .assistant })
        let tail = state.messages.suffix(4).filter { $0.role == .assistant }
        var running: [ToolCall] = []
        for message in tail {
            for part in message.parts {
                guard case .tool(let call) = part.kind else { continue }
                if call.isAwaitingAnswer { awaiting.answers.insert(call.id) }
                if call.status == .running || call.status == .pending { running.append(call) }
            }
        }
        for permission in state.pendingPermissions {
            let named = running.last { call in
                guard let tool = permission.toolName else { return false }
                return call.name.caseInsensitiveCompare(tool) == .orderedSame
                    && !awaiting.approvals.contains(call.id)
            }
            if let call = named ?? running.last(where: { !awaiting.approvals.contains($0.id) }) {
                awaiting.approvals.insert(call.id)
            }
        }
        for question in state.pendingQuestions { awaiting.answers.insert(question.id) }
        if state.interruption != nil, let assistant { awaiting.interrupted.insert(assistant.id) }
        return awaiting
    }

    private func finish(_ held: inout Entry, messages: [ChatMessage]) {
        counter += 1
        held.revision = counter
        let turn = held.turn
        held.anchor =
            turn.steps.first(where: { turn.memberPartIDs.contains($0.id) })?.id ?? turn.steps.first?.id
        held.anchorMessageID = held.anchor.flatMap { id in
            turn.steps.first(where: { $0.id == id })?.messageID
        }
        held.messageIDs = Set(turn.steps.map(\.messageID))
        held.boardKeys = Set(
            turn.steps.filter { $0.isCard && $0.zone == .think && TaskBoard.isBoardCall($0.title) }
                .map(\.id))
        held.answer = Self.answerText(of: turn, in: messages)
    }

    private func remember(_ held: Entry, id: String) {
        for message in held.messageIDs { messageTurn[message] = id }
        for key in held.boardKeys { boardOwner[key] = id }
    }

    private func forget(_ held: Entry) {
        for message in held.messageIDs where messageTurn[message] == held.turn.id {
            messageTurn[message] = nil
        }
        for key in held.boardKeys where boardOwner[key] == held.turn.id { boardOwner[key] = nil }
    }

    private func evict() {
        let keep = Set(order)
        while arrival.count > Self.capacity {
            let oldest = arrival.removeFirst()
            guard !keep.contains(oldest), let held = entries[oldest] else { continue }
            forget(held)
            entries[oldest] = nil
        }
    }

    /// The words of the message that began a turn: the question the poster quotes.
    private static func prompt(before turn: NeuralTurn, in messages: [ChatMessage]) -> String? {
        guard let first = messages.firstIndex(where: { $0.id == turn.id }) else { return nil }
        guard let asked = messages[..<first].last(where: { $0.role == .user }) else { return nil }
        let words = asked.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// The model of a turn as a picture should show it: at rest, with nothing hovered, pinned,
    /// pointed at or replaying.
    func restingModel(_ turnID: String) -> NeuralBrainModel? {
        guard var model = entries[turnID]?.model else { return nil }
        model.stopReplay()
        model.clearSelection()
        model.setProvenance(token: nil)
        model.setDiving(false)
        return model
    }

    /// The answer's words, from the turn's trailing text parts, for the provenance chips.
    private static func answerText(of turn: NeuralTurn, in messages: [ChatMessage]) -> String {
        guard !turn.answerPartIDs.isEmpty else { return "" }
        let wanted = Set(turn.answerPartIDs)
        var pieces: [String] = []
        for message in messages.reversed() {
            var inMessage: [String] = []
            for part in message.parts {
                guard wanted.contains("\(message.id):\(part.id)"), case .text(let words) = part.kind
                else { continue }
                inMessage.append(words)
            }
            pieces.insert(contentsOf: inMessage, at: 0)
            if pieces.count >= wanted.count { break }
        }
        return pieces.joined(separator: "\n\n")
    }
}
