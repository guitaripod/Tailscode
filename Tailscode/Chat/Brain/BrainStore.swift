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
}

/// What the row builder reads of the brains: for each turn that is one, where its row goes and
/// which of its parts it consumes. The builder walks the messages once, finds each turn by the id
/// of its first assistant message, and asks here by part id, so nothing about a brain costs the
/// size of the conversation.
struct BrainLayout {
    struct Turn {
        let id: String
        let anchor: String?
        let anchorMessageID: String?
        let outline: NeuralTurnOutline
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
        !turn.row.showsRows && turn.outline.consumes(partID)
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
///
/// Opening a chat pays for the outline of each turn and nothing more: where its row goes, which
/// parts it consumes and a stamp that says whether it changed. A turn's steps are read and its
/// model made the first time something asks for the model (a card being configured, Find landing,
/// a share), except for the newest turn and a running one, which are made at once because the
/// chat's status, its haptics and its Live Activity read them. A turn that nobody looks at never
/// costs more than its outline.
@MainActor
final class BrainStore {
    private struct Held {
        var generation: Int
        var context: NeuralBrainContext
        var row: BrainRow
        var anchor: String?
        var open: Bool
        var showsRows: Bool
        var latest: Bool
    }

    private let cache = NeuralTurnCache(capacity: 4096)
    private var turns = NeuralTurnList()
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
    private var searchCache: [String: (generation: Int, text: String)] = [:]
    private var memories: [String: BrainLiveMemory] = [:]
    private var promptCache: [String: String] = [:]
    private var interactions: [String: BrainInteraction] = [:]
    private var contextFor: ((_ isLatest: Bool) -> NeuralBrainContext)?

    /// Whether the brain is drawn at all: the person's style, and a machine that can draw it.
    static var isActive: Bool {
        ActivityStyleSetting.current == .brain && NeuralHeadView.isSupported
    }

    var count: Int { held.count }

    /// How many turns have a model made, which is the turns somebody looked at and the live one.
    var realisedCount: Int { models.count }

    /// The model of a turn, made now if nothing has asked for it yet.
    func model(for turnID: String) -> NeuralBrainModel? {
        if let made = models[turnID] { return made }
        return realise(turnID)
    }

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

    /// The turn read into steps, which reads them now if nothing has.
    private func turn(for turnID: String) -> NeuralTurn? {
        guard held[turnID] != nil, let index = turnIndex[turnID], index < turns.count,
            turns.outline(at: index).id == turnID
        else { return nil }
        return turns[index]
    }

    /// The first step of a turn whose name, argument, words or output holds `needle`: where Find
    /// lands inside a brain.
    func stepMatching(_ needle: String, in turnID: String) -> String? {
        let key = needle.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, let turn = turn(for: turnID) else { return nil }
        func has(_ text: String) -> Bool {
            !text.isEmpty && text.range(of: key, options: .caseInsensitive) != nil
        }
        return turn.steps.first { step in
            has(step.title) || has(step.detail) || has(step.text)
                || step.outputLines.contains(where: has)
        }?.id
    }

    /// What in-conversation find reads of a brain: every step's name, argument and words, and the
    /// first lines of what it printed. Made once for a turn as it stands, and only for a turn Find
    /// has asked about.
    func searchText(for turnID: String) -> String {
        guard let index = turnIndex[turnID], index < turns.count,
            turns.outline(at: index).id == turnID
        else { return "" }
        let generation = turns.generation(at: index)
        if let hit = searchCache[turnID], hit.generation == generation { return hit.text }
        let text = Self.searchText(of: turns[index])
        searchCache[turnID] = (generation, text)
        return text
    }

    /// The search text of a turn if Find has read it already, and nothing otherwise: what a
    /// keystroke reads while the sliced pass that reads the rest is still running.
    func indexedSearchText(for turnID: String) -> String {
        guard let index = turnIndex[turnID], index < turns.count,
            let hit = searchCache[turnID], hit.generation == turns.generation(at: index)
        else { return "" }
        return hit.text
    }

    /// Reads the search text of brains Find has not read, newest first, until `budget` seconds are
    /// spent, and returns whether every brain has been read.
    func indexSearch(budget: TimeInterval, clock: () -> CFTimeInterval = CACurrentMediaTime) -> Bool {
        let deadline = clock() + budget
        var index = turns.count - 1
        while index >= 0 {
            let outline = turns.outline(at: index)
            if outline.isBrain, searchCache[outline.id]?.generation != turns.generation(at: index) {
                if clock() >= deadline { return false }
                _ = searchText(for: outline.id)
            }
            index -= 1
        }
        return true
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
        guard var made = model(for: turnID) else { return }
        change(&made)
        models[turnID] = made
    }

    /// Reads a value out of a model that a change is also made to, in one go.
    func mutateReturning<T>(_ turnID: String, _ change: (inout NeuralBrainModel) -> T) -> T {
        var made =
            model(for: turnID)
            ?? NeuralBrainModel(turn: NeuralTurn(id: "-", steps: [], outcome: .settled))
        let value = change(&made)
        if models[turnID] != nil { models[turnID] = made }
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
        turns = NeuralTurnList()
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
        searchCache = [:]
        memories = [:]
        interactions = [:]
        promptCache = [:]
        contextFor = nil
    }

    /// Reads the conversation into brains and returns what the builder needs. `context` answers
    /// for a turn: the latest carries what the conversation is doing now, an older one only who
    /// answered. Style and device are decided by the caller through `isActive`.
    func prepare(
        messages all: [ChatMessage], running isRunning: Bool, awaiting: NeuralAwaiting,
        context: @escaping (_ isLatest: Bool) -> NeuralBrainContext
    ) -> BrainLayout {
        let began = CACurrentMediaTime()
        defer {
            BrainDebug.note("prepare", since: began, detail: "turns=\(turns.count) realised=\(models.count)")
        }
        passes += 1
        contextFor = context
        let overriding = BrainDebug.overridesOpen
        let verifying = passes % Self.verifyEvery == 0
        let prefix = verifying ? 0 : stablePrefix(of: all)
        let list = cache.partitionList(
            messages: all, running: isRunning, awaiting: awaiting, stablePrefix: prefix)
        turns = list
        let base = list.isEmpty ? NeuralBrainContext() : context(false)
        let next = Shape(running: isRunning, awaiting: awaiting, base: base)
        let sameShape = shape == next
        shape = next
        let previousCount = turnIDs.count
        var from = 0
        if sameShape, !overriding, prefix > 0 {
            from = min(untouchedTurns(prefix: prefix), previousCount - 1, list.count - 1)
            from = max(0, from)
            if from > 0, from <= turnIDs.count, list.outline(at: from - 1).id != turnIDs[from - 1] {
                from = 0
            }
        }
        messages = all
        running = isRunning
        let oldTail = Array(turnIDs[min(from, turnIDs.count)...])
        turnIDs.removeSubrange(min(from, turnIDs.count)...)
        turnStarts.removeSubrange(min(from, turnStarts.count)...)
        var cursor = from > 0 ? (turnStarts.last ?? 0) : 0
        for index in from..<list.count {
            let id = list.outline(at: index).id
            turnIDs.append(id)
            turnIndex[id] = index
            var found = cursor
            while found < all.count, all[found].id != id { found += 1 }
            if found < all.count { cursor = found } else { found = cursor }
            turnStarts.append(found)
        }
        var tail = Set<String>()
        for index in from..<list.count { tail.insert(list.outline(at: index).id) }
        for id in oldTail where !tail.contains(id) {
            purge(id)
            turnIndex[id] = nil
        }

        let latest = list.isEmpty ? nil : list.outline(at: list.count - 1).id
        let open = resolveOpen(override: overriding ? BrainDebug.openOverride(
            policy: NeuralOpenPolicy(turnIDs: turnIDs, latest: latest, isRunning: isRunning, choices: choices),
            turns: list) : nil)
        if open != currentOpen {
            if let old = currentOpen { dirty.insert(old) }
            if let new = open { dirty.insert(new) }
            currentOpen = open
        }
        for index in from..<list.count {
            visit(index, in: list, isLatest: index == list.count - 1, open: open, context: context)
        }
        for id in dirty {
            guard let index = turnIndex[id], index < from, index < list.count,
                list.outline(at: index).id == id
            else { continue }
            visit(index, in: list, isLatest: id == latest, open: open, context: context)
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
        searchCache[id] = nil
        memories[id] = nil
        interactions[id] = nil
        promptCache[id] = nil
        listing.remove(id)
        table.remove(id)
    }

    /// Whether a turn's model must exist now: the newest turn and a running one are read by the
    /// chat's status, its haptics and its Live Activity whether or not a card is on screen.
    private func isLive(_ outline: NeuralTurnOutline, latest: Bool) -> Bool {
        latest || outline.outcome == .running
    }

    private func visit(
        _ index: Int, in list: NeuralTurnList, isLatest: Bool, open openID: String?,
        context: (_ isLatest: Bool) -> NeuralBrainContext
    ) {
        let outline = list.outline(at: index)
        guard outline.isBrain else {
            if held[outline.id] != nil { purge(outline.id) }
            return
        }
        let id = outline.id
        let live = isLive(outline, latest: isLatest)
        let entry: Held
        if live || models[id] != nil {
            let turn = list[index]
            if isLatest { BrainDebug.adopt(turn) }
            entry = refresh(
                turn, outline: outline, generation: list.generation(at: index),
                context: context(isLatest), open: id == openID, latest: isLatest)
        } else {
            entry = place(
                outline, generation: list.generation(at: index), context: context(isLatest),
                open: id == openID, latest: isLatest)
        }
        if live || memories[id] == nil, let model = models[id] {
            memory(for: id).note(model: model)
        }
        table.set(
            BrainLayout.Turn(
                id: id, anchor: entry.anchor, anchorMessageID: outline.anchorMessageID,
                outline: outline, row: entry.row))
    }

    /// The words of a turn's final answer, for the chips that point at the steps behind them.
    func answerText(for turnID: String) -> String {
        guard let turn = turn(for: turnID), !turn.answerPartIDs.isEmpty else { return "" }
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

    /// Makes the model of a turn nobody has asked for yet, against the context its row was last
    /// stamped with.
    private func realise(_ turnID: String) -> NeuralBrainModel? {
        let began = CACurrentMediaTime()
        defer { BrainDebug.note("realise", since: began, detail: "steps=\(models[turnID]?.steps.count ?? 0)") }
        guard let entry = held[turnID], let turn = turn(for: turnID) else { return nil }
        let made = NeuralBrainModel(turn: turn, context: entry.context)
        models[turnID] = made
        if memories[turnID] == nil { memory(for: turnID).note(model: made) }
        return made
    }

    /// A turn whose model exists: brought to the turn and context as they now stand, and its row
    /// stamped from the model when the turn is live and from its outline when it is not.
    private func refresh(
        _ turn: NeuralTurn, outline: NeuralTurnOutline, generation: Int,
        context: NeuralBrainContext, open: Bool, latest: Bool
    ) -> Held {
        let rows = listing.contains(turn.id)
        var model: NeuralBrainModel
        if let made = models[turn.id] {
            model = made
        } else {
            model = NeuralBrainModel(turn: turn, context: context)
            models[turn.id] = model
        }
        if var entry = held[turn.id] {
            let changed = entry.generation != generation || entry.context != context
            if changed {
                model.update(turn: turn, context: context)
                models[turn.id] = model
            }
            guard changed || entry.open != open || entry.showsRows != rows || entry.latest != latest
            else { return entry }
            entry.generation = generation
            entry.context = context
            entry.open = open
            entry.showsRows = rows
            entry.latest = latest
            entry.row = Self.row(
                outline, generation: generation, context: context, open: open, latest: latest,
                rows: rows, model: model)
            if changed { entry.anchor = outline.anchor }
            held[turn.id] = entry
            return entry
        }
        let entry = Held(
            generation: generation, context: context,
            row: Self.row(
                outline, generation: generation, context: context, open: open, latest: latest,
                rows: rows, model: model),
            anchor: outline.anchor, open: open, showsRows: rows, latest: latest)
        held[turn.id] = entry
        return entry
    }

    /// A turn nobody has looked at: only its outline, its context and its place in the chat.
    private func place(
        _ outline: NeuralTurnOutline, generation: Int, context: NeuralBrainContext, open: Bool,
        latest: Bool
    ) -> Held {
        let rows = listing.contains(outline.id)
        if var entry = held[outline.id] {
            guard entry.generation != generation || entry.context != context || entry.open != open
                || entry.showsRows != rows || entry.latest != latest
            else { return entry }
            entry.generation = generation
            entry.context = context
            entry.open = open
            entry.showsRows = rows
            entry.latest = latest
            entry.anchor = outline.anchor
            entry.row = Self.row(
                outline, generation: generation, context: context, open: open, latest: latest,
                rows: rows, model: nil)
            held[outline.id] = entry
            return entry
        }
        let entry = Held(
            generation: generation, context: context,
            row: Self.row(
                outline, generation: generation, context: context, open: open, latest: latest,
                rows: rows, model: nil),
            anchor: outline.anchor, open: open, showsRows: rows, latest: latest)
        held[outline.id] = entry
        return entry
    }

    /// The row a transcript diffs by. A live turn is told from its previous self by what its model
    /// shows (the layout revision, the state, the face, the meters); any other turn by which turn
    /// it is and the context it is drawn against, because a settled turn cannot change without the
    /// conversation handing back a different turn, and a different turn has a different
    /// generation. The two are never mixed for one turn, so reading a model for the first time
    /// leaves its row as it was.
    private static func row(
        _ outline: NeuralTurnOutline, generation: Int, context: NeuralBrainContext, open: Bool,
        latest: Bool, rows: Bool, model: NeuralBrainModel?
    ) -> BrainRow {
        var hasher = Hasher()
        if latest || outline.outcome == .running, let model {
            hasher.combine(model.revision)
            hasher.combine(model.turn.outcome)
            hasher.combine(model.state.label)
            hasher.combine(model.face)
            hasher.combine(model.meters)
            hasher.combine(model.context.activity?.spoken)
        } else {
            hasher.combine(generation)
            hasher.combine(outline.outcome)
            hasher.combine(outline.modelID)
            hasher.combine(outline.effort)
            hasher.combine(context.providerID)
            hasher.combine(context.effortOptions)
            hasher.combine(context.effort)
            hasher.combine(context.face)
        }
        hasher.combine(open)
        hasher.combine(latest)
        return BrainRow(
            turnID: outline.id, stamp: hasher.finalize(), isOpen: open, isLatest: latest,
            showsRows: rows)
    }

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
