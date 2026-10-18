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

    private let turns: [String: Turn]

    static let none = BrainLayout(turns: [:])

    init(turns: [String: Turn]) {
        self.turns = turns
    }

    var isEmpty: Bool { turns.isEmpty }

    /// The brain of the turn whose first assistant message is `messageID`, if it has one.
    func turn(startingAt messageID: String) -> Turn? { turns[messageID] }

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

    var openTurnID: String? { held.first { $0.value.open }?.key }

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

    /// The id of the nth brain, counting from one, for a debug launch.
    func turnID(atBrain number: Int) -> String? {
        let ids = turnIDs.filter { held[$0] != nil }
        return ids.indices.contains(number - 1) ? ids[number - 1] : nil
    }

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
    }

    func toggleRows(_ turnID: String) {
        if !listing.insert(turnID).inserted { listing.remove(turnID) }
    }

    func forgetEverything() {
        cache.reset()
        held = [:]
        models = [:]
        choices = [:]
        listing = []
        turnIDs = []
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
        messages = all
        running = isRunning
        let turns = cache.partition(messages: all, running: isRunning, awaiting: awaiting)
        turnIDs = turns.map(\.id)
        let policy = NeuralOpenPolicy(turnIDs: turnIDs, isRunning: isRunning, choices: choices)
        let open = BrainDebug.openOverride(policy: policy, turns: turns) ?? policy.openTurnID
        var layout: [String: BrainLayout.Turn] = [:]
        var alive = Set<String>()
        let latest = turns.last?.id
        for turn in turns where NeuralOpenPolicy.isBrain(turn: turn) {
            alive.insert(turn.id)
            let isLatest = turn.id == latest
            let ctx = context(turn, isLatest)
            let entry = refresh(turn, context: ctx, open: turn.id == open, latest: isLatest)
            if isLatest || turn.outcome == .running || memories[turn.id] == nil, let model = models[turn.id] {
                memory(for: turn.id).note(model: model)
            }
            layout[turn.id] = BrainLayout.Turn(
                id: turn.id, anchor: entry.anchor, members: turn.memberPartIDs, row: entry.row)
        }
        for id in held.keys where !alive.contains(id) {
            held[id] = nil
            models[id] = nil
            answerCache[id] = nil
            memories[id] = nil
            interactions[id] = nil
            promptCache[id] = nil
        }
        listing.formIntersection(alive)
        return BrainLayout(turns: layout)
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
    private(set) var lastActivity = Date()
    var quoteArrivals: [String: Date] = [:]
    var settleClock = NeuralCardSettleClock()
    private var signature: Int?
    private var seeded = false

    func note(model: NeuralBrainModel, now: Date = Date(), clock: TimeInterval = CACurrentMediaTime()) {
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
    var askedExpanded = false
    var planExpanded: Bool?
    var openedAt: CFTimeInterval = 0
    var replayOnOpen = false
    /// A zone the card's chip asked to open the brain diving into.
    var pendingDive: NeuralZone?
}
