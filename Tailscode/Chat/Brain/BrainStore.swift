import CodingAgentKit
import Foundation
import QuartzCore
import TailscodeCore

/// What a transcript row needs to know about a turn's brain to be drawn and to be told apart from
/// its previous self. The model itself lives in the `BrainStore`; this is the value a row diffs by.
///
/// `stamp` is one integer for everything the model reads that a cell shows (the layout revision,
/// the state, the face, the meters), so a streamed word of an answer, which changes none of them,
/// leaves the row exactly as it was and the data source has nothing to do.
struct BrainRow: Hashable {
    let turnID: String
    let stamp: Int
    let isOpen: Bool
    let isLatest: Bool
    let showsRows: Bool
    let search: String
}

/// What the row builder reads of the brains: for each turn that is one, where its row goes and
/// which of its parts it consumes. The builder walks the messages once, finds each turn by the id
/// of its first assistant message, and asks here by part id, so nothing about a brain costs the
/// size of the conversation.
struct BrainLayout {
    struct Turn {
        let id: String
        let anchor: String?
        let members: Set<String>
        let row: BrainRow
    }

    /// The table a store keeps up to date in place, so a streamed token rewrites the entries of
    /// the turns it touched and not a dictionary of every turn.
    final class Table: @unchecked Sendable {
        fileprivate(set) var turns: [String: Turn] = [:]

        func set(_ turn: Turn) { turns[turn.id] = turn }

        func remove(_ id: String) { turns[id] = nil }

        func removeAll() { turns = [:] }
    }

    private let table: Table

    static let none = BrainLayout(table: Table())

    init(table: Table) {
        self.table = table
    }

    var isEmpty: Bool { table.turns.isEmpty }

    /// The brain of the turn whose first assistant message is `messageID`, if it has one.
    func turn(startingAt messageID: String) -> Turn? { table.turns[messageID] }

    func hides(_ partID: String, in turn: Turn) -> Bool {
        !turn.row.showsRows && turn.members.contains(partID)
    }
}

/// The brains of one conversation: the turns read from its messages, the model each open or
/// closed brain holds, what the person chose to open, and which turns list their old rows. One
/// lives per chat screen and is never shared, so a conversation shown in a second window keeps its
/// own open brain.
///
/// A transcript is built again for every state a conversation emits, which while a turn streams is
/// every token, so this does only what a change requires: the partition is read through
/// `NeuralTurnCache`, a model is touched only when its turn or its context is not what it held,
/// and a turn's row, anchor and search text are made once per change.
@MainActor
final class BrainStore {
    private struct Held {
        var turn: NeuralTurn
        var context: NeuralBrainContext
        var row: BrainRow
        var anchor: String?
        var open: Bool
        var showsRows: Bool
        var latest: Bool
    }

    private let cache = NeuralTurnCache(capacity: 4096)
    private var held: [String: Held] = [:]
    private var models: [String: NeuralBrainModel] = [:]
    private var choices: [String: Bool] = [:]
    private var listing: Set<String> = []
    private var turnIDs: [String] = []
    private var turnIndex: [String: Int] = [:]
    private var turnStarts: [Int] = []
    private var dirty: Set<String> = []
    private var shape: Shape?
    private var passes = 0
    private var currentOpen: String?
    private let table = BrainLayout.Table()
    private var running = false
    private var messages: [ChatMessage] = []
    private var answerCache: [String: (key: Int, text: String)] = [:]
    private var memories: [String: BrainLiveMemory] = [:]
    private var promptCache: [String: String] = [:]
    private var interactions: [String: BrainInteraction] = [:]

    /// Whether the brain is drawn at all: the person's style, and a machine that can draw it.
    static var isActive: Bool {
        ActivityStyleSetting.current == .brain && NeuralHeadView.isSupported
    }

    var count: Int { held.count }

    func model(for turnID: String) -> NeuralBrainModel? { models[turnID] }

    func isOpen(_ turnID: String) -> Bool { held[turnID]?.open ?? false }

    /// What a card remembers of a running turn between two renders: when anything last arrived,
    /// when each note was first seen, and when the turn settled.
    func memory(for turnID: String) -> BrainLiveMemory {
        if let kept = memories[turnID] { return kept }
        let made = BrainLiveMemory()
        memories[turnID] = made
        return made
    }

    /// What the person has done to an open brain that the model does not hold: the work lines
    /// they unfolded, the notes they expanded, where the account is scrolled.
    func interaction(for turnID: String) -> BrainInteraction {
        if let kept = interactions[turnID] { return kept }
        let made = BrainInteraction()
        interactions[turnID] = made
        return made
    }

    func showsRows(_ turnID: String) -> Bool { listing.contains(turnID) }

    var openTurnID: String? { currentOpen }

    var latestTurnID: String? { turnIDs.last }

    /// The first step of a turn whose name, argument, words or output holds `needle`: where Find
    /// lands inside a brain.
    func stepMatching(_ needle: String, in turnID: String) -> String? {
        let key = needle.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, let turn = held[turnID]?.turn else { return nil }
        func has(_ text: String) -> Bool {
            !text.isEmpty && text.range(of: key, options: .caseInsensitive) != nil
        }
        return turn.steps.first { step in
            has(step.title) || has(step.detail) || has(step.text)
                || step.outputLines.contains(where: has)
        }?.id
    }

    /// The part a turn's brain row goes before, for a check that compares two stores.
    func anchorID(of turnID: String) -> String? { held[turnID]?.anchor }

    /// The id of the nth brain, counting from one, for a debug launch.
    func turnID(atBrain number: Int) -> String? {
        let ids = turnIDs.filter { held[$0] != nil }
        return ids.indices.contains(number - 1) ? ids[number - 1] : nil
    }

    /// Everything about the conversation that, when it changes, can change every turn at once:
    /// whether a turn is running, what is awaited, and what an older turn is read against.
    private struct Shape: Equatable {
        var running: Bool
        var awaiting: NeuralAwaiting
        var base: NeuralBrainContext
    }

    private static let margin = 12
    private static let verifyEvery = 64

    /// Lets a cell change a model in place: a pin, a hover, a replay. The row's value is not
    /// touched, because nothing a row diffs by moved.
    func mutate(_ turnID: String, _ change: (inout NeuralBrainModel) -> Void) {
        guard var model = models[turnID] else { return }
        change(&model)
        models[turnID] = model
    }

    /// Reads a value out of a model that a change is also made to, in one go.
    func mutateReturning<T>(_ turnID: String, _ change: (inout NeuralBrainModel) -> T) -> T {
        var model = models[turnID] ?? NeuralBrainModel(turn: NeuralTurn(id: "-", steps: [], outcome: .settled))
        let value = change(&model)
        if models[turnID] != nil { models[turnID] = model }
        return value
    }

    /// What the person asked that started a turn: the user message before its first assistant
    /// message, in its own words.
    func promptText(for turnID: String) -> String? {
        if let hit = promptCache[turnID] { return hit.isEmpty ? nil : hit }
        guard let start = messages.firstIndex(where: { $0.id == turnID }) else { return nil }
        let words = messages[..<start].last { $0.role == .user }.map { message -> String in
            message.parts.compactMap { part -> String? in
                if case .text(let words) = part.kind { return words }
                return nil
            }.joined(separator: "\n")
        } ?? ""
        promptCache[turnID] = words
        return words.isEmpty ? nil : words
    }

    /// Opens a turn's brain, or closes it, the way the policy says: opening one closes the other.
    func toggle(_ turnID: String) {
        let policy = NeuralOpenPolicy(turnIDs: turnIDs, isRunning: running, choices: choices)
        choices = policy.toggle(turnID: turnID)
        dirty.insert(turnID)
        if let open = currentOpen { dirty.insert(open) }
    }

    func toggleRows(_ turnID: String) {
        if !listing.insert(turnID).inserted { listing.remove(turnID) }
        dirty.insert(turnID)
    }

    func forgetEverything() {
        cache.reset()
        held = [:]
        models = [:]
        choices = [:]
        listing = []
        turnIDs = []
        turnIndex = [:]
        turnStarts = []
        dirty = []
        shape = nil
        currentOpen = nil
        table.removeAll()
        messages = []
        answerCache = [:]
        memories = [:]
        interactions = [:]
        promptCache = [:]
    }

    /// Reads the conversation into brains and returns what the builder needs. `context` answers
    /// for a turn: the latest carries what the conversation is doing now, an older one only who
    /// answered. Style and device are decided by the caller through `isActive`.
    func prepare(
        messages all: [ChatMessage], running isRunning: Bool, awaiting: NeuralAwaiting,
        context: (_ turn: NeuralTurn, _ isLatest: Bool) -> NeuralBrainContext
    ) -> BrainLayout {
        passes += 1
        let overriding = BrainDebug.overridesOpen
        let verifying = passes % Self.verifyEvery == 0
        let prefix = verifying ? 0 : stablePrefix(of: all)
        let list = cache.partitionList(
            messages: all, running: isRunning, awaiting: awaiting, stablePrefix: prefix)
        let base = list.first.map { context($0, false) } ?? NeuralBrainContext()
        let next = Shape(running: isRunning, awaiting: awaiting, base: base)
        let sameShape = shape == next
        shape = next
        let previousCount = turnIDs.count
        var from = 0
        if sameShape, !overriding, prefix > 0 {
            from = min(untouchedTurns(prefix: prefix), previousCount - 1, list.count - 1)
            from = max(0, from)
            if from > 0, from <= turnIDs.count, list[from - 1].id != turnIDs[from - 1] { from = 0 }
        }
        messages = all
        running = isRunning
        let oldTail = Array(turnIDs[min(from, turnIDs.count)...])
        turnIDs.removeSubrange(min(from, turnIDs.count)...)
        turnStarts.removeSubrange(min(from, turnStarts.count)...)
        var cursor = from > 0 ? (turnStarts.last ?? 0) : 0
        for index in from..<list.count {
            let id = list[index].id
            turnIDs.append(id)
            turnIndex[id] = index
            var found = cursor
            while found < all.count, all[found].id != id { found += 1 }
            if found < all.count { cursor = found } else { found = cursor }
            turnStarts.append(found)
        }
        var tail = Set<String>()
        for index in from..<list.count { tail.insert(list[index].id) }
        for id in oldTail where !tail.contains(id) {
            purge(id)
            turnIndex[id] = nil
        }

        let latest = list.last?.id
        let open = resolveOpen(override: overriding ? BrainDebug.openOverride(
            policy: NeuralOpenPolicy(turnIDs: turnIDs, latest: latest, isRunning: isRunning, choices: choices),
            turns: list) : nil)
        if open != currentOpen {
            if let old = currentOpen { dirty.insert(old) }
            if let new = open { dirty.insert(new) }
            currentOpen = open
        }
        for index in from..<list.count {
            visit(list[index], isLatest: list[index].id == latest, open: open, context: context)
        }
        for id in dirty {
            guard let index = turnIndex[id], index < from, index < list.count, list[index].id == id else { continue }
            visit(list[index], isLatest: id == latest, open: open, context: context)
        }
        dirty.removeAll()
        return BrainLayout(table: table)
    }

    /// How many leading messages this conversation shares with the last one read, as far as the
    /// cheap evidence goes: the first message, and the one at the cut, are the same, and the cut
    /// leaves the newest few messages out, because those are the ones a stream grows. Every
    /// `verifyEvery` passes, and whenever a turn starts or ends, the whole list is read again.
    private func stablePrefix(of all: [ChatMessage]) -> Int {
        let before = messages
        let cut = before.count - Self.margin
        guard cut > 0, all.count >= cut, before[0].id == all[0].id,
            before[cut - 1].id == all[cut - 1].id, before[cut / 2].id == all[cut / 2].id
        else { return 0 }
        return cut
    }

    /// The turns that end before the first message a pass may have touched, which are read from
    /// the starts of the turns that follow them.
    private func untouchedTurns(prefix: Int) -> Int {
        var low = 0
        var high = turnStarts.count
        while low < high {
            let mid = (low + high) / 2
            if mid + 1 < turnStarts.count, turnStarts[mid + 1] <= prefix - 2 { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func resolveOpen(override: String?) -> String? {
        if let override { return override.isEmpty ? nil : override }
        var open: String?
        var newest = -1
        for (id, chosen) in choices where chosen {
            if let index = turnIndex[id], index > newest {
                newest = index
                open = id
            }
        }
        return open
    }

    private func purge(_ id: String) {
        held[id] = nil
        models[id] = nil
        answerCache[id] = nil
        memories[id] = nil
        interactions[id] = nil
        promptCache[id] = nil
        listing.remove(id)
        table.remove(id)
    }

    private func visit(
        _ turn: NeuralTurn, isLatest: Bool, open openID: String?,
        context: (_ turn: NeuralTurn, _ isLatest: Bool) -> NeuralBrainContext
    ) {
        guard NeuralOpenPolicy.isBrain(turn: turn) else {
            if held[turn.id] != nil { purge(turn.id) }
            return
        }
        BrainDebug.adopt(turn)
        let entry = refresh(
            turn, context: context(turn, isLatest), open: turn.id == openID, latest: isLatest)
        if isLatest || turn.outcome == .running || memories[turn.id] == nil, let model = models[turn.id] {
            memory(for: turn.id).note(model: model)
        }
        table.set(
            BrainLayout.Turn(
                id: turn.id, anchor: entry.anchor, members: turn.memberPartIDs, row: entry.row))
    }

    /// The words of a turn's final answer, for the chips that point at the steps behind them.
    func answerText(for turnID: String) -> String {
        guard let turn = held[turnID]?.turn, !turn.answerPartIDs.isEmpty else { return "" }
        let key = turn.answerPartIDs.hashValue
        if let hit = answerCache[turnID], hit.key == key { return hit.text }
        let wanted = Set(turn.answerPartIDs)
        var words: [String] = []
        for message in messages.reversed() {
            guard message.role == .assistant else { continue }
            for part in message.parts {
                guard wanted.contains("\(message.id):\(part.id)"), case .text(let text) = part.kind
                else { continue }
                words.append(text)
            }
            if message.id == turn.id { break }
        }
        let text = words.reversed().joined(separator: "\n\n")
        answerCache[turnID] = (key, text)
        return text
    }

    private func refresh(
        _ turn: NeuralTurn, context: NeuralBrainContext, open: Bool, latest: Bool
    ) -> Held {
        let rows = listing.contains(turn.id)
        if var entry = held[turn.id], var model = models[turn.id] {
            let changed = entry.turn != turn || entry.context != context
            if changed {
                model.update(turn: turn, context: context)
                models[turn.id] = model
            }
            guard changed || entry.open != open || entry.showsRows != rows || entry.latest != latest
            else { return entry }
            entry.turn = turn
            entry.context = context
            entry.open = open
            entry.showsRows = rows
            entry.latest = latest
            entry.row = Self.row(for: turn, model: model, open: open, latest: latest, rows: rows)
            if changed { entry.anchor = Self.anchor(of: turn) }
            held[turn.id] = entry
            return entry
        }
        let model = NeuralBrainModel(turn: turn, context: context)
        models[turn.id] = model
        let entry = Held(
            turn: turn, context: context,
            row: Self.row(for: turn, model: model, open: open, latest: latest, rows: rows),
            anchor: Self.anchor(of: turn), open: open, showsRows: rows, latest: latest)
        held[turn.id] = entry
        return entry
    }

    /// The part a turn's brain row goes before: its first member part, or its first step when
    /// every step is one the client also draws as a card.
    private static func anchor(of turn: NeuralTurn) -> String? {
        turn.steps.first { turn.memberPartIDs.contains($0.id) }?.id ?? turn.steps.first?.id
    }

    private static func row(
        for turn: NeuralTurn, model: NeuralBrainModel, open: Bool, latest: Bool, rows: Bool
    ) -> BrainRow {
        var hasher = Hasher()
        hasher.combine(model.revision)
        hasher.combine(turn.outcome)
        hasher.combine(model.state.label)
        hasher.combine(model.face)
        hasher.combine(model.meters)
        hasher.combine(model.context.activity?.spoken)
        hasher.combine(open)
        hasher.combine(latest)
        return BrainRow(
            turnID: turn.id, stamp: hasher.finalize(), isOpen: open, isLatest: latest,
            showsRows: rows, search: searchText(of: turn))
    }

    /// What in-conversation find reads of a brain: every step's name, argument and words, and the
    /// first lines of what it printed.
    static func searchText(of turn: NeuralTurn) -> String {
        var parts: [String] = []
        parts.reserveCapacity(turn.steps.count * 2)
        for step in turn.steps {
            parts.append(step.title)
            if !step.detail.isEmpty { parts.append(step.detail) }
            if !step.text.isEmpty { parts.append(step.text) }
            if !step.outputLines.isEmpty { parts.append(step.outputLines.joined(separator: " ")) }
        }
        return parts.joined(separator: " ")
    }
}

/// What a card remembers of a running turn between two renders, which a value-typed model cannot:
/// the moment anything last arrived (silence is counted from it), the moment each note was first
/// seen (a note holds the card's third line for four seconds from there), and when the turn
/// settled, which is what the settle move reads.
@MainActor
final class BrainLiveMemory {
    private(set) var lastActivity = BrainDebug.now
    var quoteArrivals: [String: Date] = [:]
    var settleClock = NeuralCardSettleClock()
    private var signature: Int?
    private var seeded = false

    func note(model: NeuralBrainModel, now: Date = BrainDebug.now, clock: TimeInterval = CACurrentMediaTime()) {
        let running = model.turn.outcome == .running
        settleClock.observe(running: running, now: clock)
        guard running else { return }
        var hasher = Hasher()
        hasher.combine(model.steps.count)
        if let last = model.steps.last {
            hasher.combine(last.text.utf8.count)
            hasher.combine(last.status)
            hasher.combine(last.outputLines.count)
            hasher.combine(last.call?.call.output?.utf8.count)
        }
        let next = hasher.finalize()
        if signature != next {
            signature = next
            lastActivity = now
        }
        if let quote = model.liveCard?.quote {
            if quoteArrivals[quote.stepID] == nil {
                quoteArrivals[quote.stepID] = seeded ? now : Date(timeIntervalSince1970: 0)
            }
        }
        seeded = true
    }

    func line(for live: NeuralLiveCard, now: Date, compact: Bool) -> NeuralLiveCard.Line {
        live.line(
            now: now, lastActivity: lastActivity,
            quoteArrivedAt: live.quote.flatMap { quoteArrivals[$0.stepID] }, compact: compact)
    }
}

/// What a person did to an open brain that the model does not hold. It lives with the store, so a
/// brain scrolled away and back is where it was left.
@MainActor
final class BrainInteraction {
    var unfolded = Set<String>()
    var expandedText = Set<String>()
    var rowCaps: [String: Int] = [:]
    var accountOffset: CGFloat = 0
    /// Where each step's reader of a whole file was scrolled to, so a card that is built again
    /// while the file is open does not send the reader back to its first line.
    var readerOffsets: [String: CGPoint] = [:]
    var askedExpanded = false
    var planExpanded: Bool?
    var openedAt: CFTimeInterval = 0
    var replayOnOpen = false
    /// A phone's step list was opened where it stands, past its first few rows.
    var listExpanded = false
    /// A zone the card's chip asked to open the brain diving into.
    var pendingDive: NeuralZone?
}
