import AppKit
import CodingAgentKit
import QuartzCore
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

/// The brain's state for one pane: the outline of every turn the conversation holds, the steps and
/// the model of each turn that somebody looked at, which of them is open and which list their old
/// rows.
///
/// The transcript is rebuilt on every streamed token, so nothing here may cost the size of the
/// conversation. `NeuralTurnCache` reads again only the turn whose messages changed, a turn is
/// told from the one held for it by its generation, and only a turn that really changed updates its
/// model and takes a new revision. The messages a turn's rows come from are found through a
/// dictionary kept in step with the turns, never by walking them.
///
/// A turn is placed from its outline alone, which is all a transcript needs to shape its rows; its
/// steps are read and its model, answer and prompt are made when a view, the share or Find asks for
/// the entry, except for the newest turn, which is made at once.
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

    /// What is made of a turn once somebody looks at it.
    private struct Made {
        var turn: NeuralTurn
        var model: NeuralBrainModel
        var answer: String
        var prompt: String?
    }

    /// A turn as the transcript places it. Kept apart from what is made of it, so reading a turn's
    /// placement copies no model.
    private struct Placed {
        var slot: NeuralTurnSlot
        var context: NeuralBrainContext
        var anchor: String?
        var anchorMessageID: String?
        var revision: Int

        var outline: NeuralTurnOutline { slot.outline }
    }

    private let cache = NeuralTurnCache()
    private var placed: [String: Placed] = [:]
    private var built: [String: Made] = [:]
    private var searchCache: [String: (slot: NeuralTurnSlot, text: String)] = [:]
    private var turnIDs: [String] = []
    private(set) var order: [String] = []
    private var messageTurn: [String: String] = [:]
    private var boardOwner: [String: String] = [:]
    private var arrival: [String] = []
    private var counter = 0

    private(set) var choices: [String: Bool] = [:]
    private(set) var rowsShown: Set<String> = []
    private(set) var openTurnID: String?
    private(set) var latestTurnID: String?
    private(set) var liveContext = NeuralBrainContext.none
    private(set) var chatContext = NeuralBrainContext.none
    private(set) var isRunning = false

    /// One number that changes whenever what the brain says about a message above the newest
    /// turn may have changed: a turn other than the newest was read, forgotten or evicted, the
    /// open brain or the newest turn's identity moved, a turn's old rows were listed or put away.
    /// The rows of everything before the newest question are final while it stands, so the
    /// transcript asks this one number instead of every message.
    private(set) var shapeEpoch = 0

    /// Seconds of the main thread's own time the store has spent reading turns and restating
    /// views, for the bench that says what the brain adds to a streamed token.
    private(set) var spent = 0.0
    /// Time a view spent restating itself, whichever road asked.
    func noteSpent(_ seconds: Double) {
        spent += seconds
        spentRestating += seconds
    }

    private(set) var spentReading = 0.0
    private(set) var spentRestating = 0.0
    private(set) var spentShaping = 0.0

    private func bumpShape() { shapeEpoch &+= 1 }

    /// Asked to rebuild the rows after a choice the person made: a brain opened or closed, the old
    /// rows listed or put away.
    var onChange: (() -> Void)?

    /// A zone a card's chip asked to open the brain diving into, by turn.
    var pendingDive: [String: NeuralZone] = [:]
    var pendingFind: [String: String] = [:]
    private var swapping: Set<String> = []

    /// Whether this turn's move is half of a swap (one brain closing as another opens), asked once
    /// as the move begins.
    func consumeSwap(_ turnID: String) -> Bool { swapping.remove(turnID) != nil }

    /// The pane hands these over: how tall the part of the transcript the reader sees is, whether
    /// the row is on screen, and the verbs a brain asks of the transcript.
    var viewportHeight: (() -> CGFloat?)?
    var isOnScreen: ((NSView) -> Bool)?
    var userToggled: (() -> Void)?
    var revealApproval: (() -> Void)?
    var replyQuote: ((String) -> Void)?
    var revealAnswerPart: ((String, String) -> Void)?
    var revealStepRow: ((String) -> Void)?

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
    func read(
        messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting, mayDefer: Bool = false
    ) {
        let begun = CACurrentMediaTime()
        defer {
            spent += CACurrentMediaTime() - begun
            spentReading += CACurrentMediaTime() - begun
        }
        guard isActive else {
            clear()
            return
        }
        isRunning = running
        if running, mayDefer, deferTailRead(messages: messages, awaiting: awaiting) { return }
        if let kept = settledPrefix(for: messages, awaiting: awaiting) {
            let stamp = Self.structure(of: kept.tailAssistants)
            let now = CACurrentMediaTime()
            tailStamp = stamp
            tailReadAt = now
            tailReads += 1
            defer { tailCost = CACurrentMediaTime() - now }
            tailTimer?.invalidate()
            tailTimer = nil
            guard
                let tail = NeuralTurns.partition(
                    messages: kept.tailAssistants, running: running, awaiting: awaiting
                ).first
            else {
                return readWhole(messages: messages, running: running, awaiting: awaiting)
            }
            counter += 1
            adopt(
                ids: kept.held.prefixIDs + [tail.id], keptOrder: kept.held.prefixBrainOrder,
                fresh: [
                    NeuralTurnSlot(
                        turn: tail, generation: counter, messages: kept.tailAssistants,
                        asked: messages[kept.held.messages.count])
                ], running: running, messages: messages)
            return
        }
        readWhole(messages: messages, running: running, awaiting: awaiting)
    }

    /// Whether a token that only lengthened words in the turn being written can wait for the
    /// timer: the same turn is held, its newest question is where it was, and no part, tool status
    /// or completion changed since it was last read, all found from the newest turn's own messages
    /// without comparing the conversation above it, which the caller has already found unchanged
    /// (`mayDefer`). The reading is then made when the timer fires.
    private func deferTailRead(messages: [ChatMessage], awaiting: NeuralAwaiting) -> Bool {
        guard let held = settled, held.awaiting == awaiting, let stamp = tailStamp,
            let cut = messages.lastIndex(where: { $0.role == .user }), cut == held.messages.count,
            CACurrentMediaTime() - tailReadAt < max(Self.tailInterval, tailCost * 5)
        else { return false }
        var assistants: [ChatMessage] = []
        for message in messages[cut...] where message.role == .assistant { assistants.append(message) }
        guard Self.structure(of: assistants) == stamp else { return false }
        scheduleTailRefresh()
        return true
    }

    /// How many times and how long the store read the whole conversation, for the bench.
    private(set) var wholeReads = 0
    private(set) var contextChanges = 0
    private(set) var restateCalls = 0
    private(set) var restateWork = 0
    private(set) var wholeCost = 0.0

    private func readWhole(messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting) {
        let begun = CACurrentMediaTime()
        wholeReads += 1
        defer { wholeCost += CACurrentMediaTime() - begun }
        let list = cache.partitionList(
            messages: messages, running: running, awaiting: awaiting,
            stablePrefix: verifiedPrefix(of: messages))
        let slots = (0..<list.count).map { list.slot(at: $0) }
        let ids = slots.map { $0.outline.id }
        adopt(ids: ids, keptOrder: nil, fresh: slots, running: running, messages: messages)
        remember(prefixOf: messages, ids: ids, awaiting: awaiting)
        tailStamp = nil
    }

    /// The least time between two readings of the turn being written when only words changed in
    /// it: a token that lengthens a note is not news to the brain for a few frames, and the
    /// reading is the one cost that grows with the turn. A step arriving, a tool changing status or
    /// a turn ending changes the structure and is read at once.
    static let tailInterval = 0.25
    private var tailStamp: Int?
    private var tailReadAt = 0.0
    private var tailCost = 0.0

    /// How many times the turn being written was read, which a streamed token of words must not
    /// make once for each token.
    private(set) var tailReads = 0
    private var tailTimer: Timer?

    /// What a run of messages is apart from the length of its words: how many parts, what each
    /// tool's status is, whether a message is complete. Equal stamps mean only words moved.
    private static func structure(of messages: [ChatMessage]) -> Int {
        var hasher = Hasher()
        hasher.combine(messages.count)
        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.parts.count)
            hasher.combine(message.isStreaming)
            hasher.combine(message.completedAt != nil)
            hasher.combine(message.error?.isEmpty)
            hasher.combine(message.finishReason?.isEmpty)
            for part in message.parts {
                hasher.combine(part.id)
                switch part.kind {
                case .tool(let call):
                    hasher.combine(call.id)
                    hasher.combine(call.status)
                    hasher.combine(call.output == nil)
                case .text: hasher.combine(0)
                case .reasoning: hasher.combine(1)
                default: hasher.combine(2)
                }
            }
        }
        return hasher.finalize()
    }

    private func scheduleTailRefresh() {
        guard tailTimer == nil else { return }
        tailTimer = Timer.scheduledTimer(
            withTimeInterval: max(Self.tailInterval, tailCost * 5), repeats: false
        ) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.tailTimer = nil
                self?.onChange?()
            }
        }
    }

    /// The conversation as it stood before its newest question, held so that a token arriving in the
    /// newest turn reads that turn alone and not every turn above it.
    private struct SettledPrefix {
        let messages: [ChatMessage]
        let ids: Set<String>
        let prefixIDs: [String]
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

    /// How many leading messages are exactly the ones the held prefix was made from, which the
    /// turn cache then reads no turn of: 0 when nothing is held or something above moved.
    private func verifiedPrefix(of messages: [ChatMessage]) -> Int {
        guard let held = settled, messages.count >= held.messages.count else { return 0 }
        for index in held.messages.indices where held.messages[index] != messages[index] { return 0 }
        return held.messages.count
    }

    private func remember(prefixOf messages: [ChatMessage], ids: [String], awaiting: NeuralAwaiting) {
        guard let cut = messages.lastIndex(where: { $0.role == .user }), cut > 0,
            let last = ids.last,
            messages[cut...].contains(where: { $0.role == .assistant && $0.id == last })
        else {
            settled = nil
            return
        }
        var messageIDs = Set<String>()
        messageIDs.reserveCapacity(cut)
        for message in messages[..<cut] { messageIDs.insert(message.id) }
        let prefix = Array(messages[..<cut])
        settled = SettledPrefix(
            messages: prefix, ids: messageIDs, prefixIDs: Array(ids.dropLast()),
            prefixBrainOrder: order.last == last ? Array(order.dropLast()) : order,
            awaiting: awaiting)
    }

    /// Brings the entries to the turns just read. `keptOrder` is the brains above the newest turn
    /// when only that one was read, and `fresh` the turns whose entries need looking at. A turn is
    /// placed from its outline; its steps are not read here, except for the newest turn's.
    private func adopt(
        ids: [String], keptOrder: [String]?, fresh: [NeuralTurnSlot], running: Bool,
        messages: [ChatMessage]
    ) {
        let before = (latestTurnID, openTurnID)
        latestTurnID = ids.last
        turnIDs = ids
        openTurnID = NeuralOpenPolicy(
            turnIDs: turnIDs, isRunning: running, choices: choices
        ).openTurnID
        if before.0 != latestTurnID || before.1 != openTurnID { bumpShape() }
        var ordered: [String] = keptOrder ?? []
        for slot in fresh where slot.outline.isBrain {
            let id = slot.outline.id
            ordered.append(id)
            let context = id == latestTurnID ? liveContext : chatContext
            if let held = placed[id] {
                let sameTurn =
                    held.slot === slot || (built[id].map { $0.turn == slot.turn } ?? false)
                if sameTurn, held.context == context {
                    placed[id]!.slot = slot
                    continue
                }
                if id != latestTurnID { bumpShape() }
                forget(held)
                placed[id]!.slot = slot
                placed[id]!.context = context
                place(&placed[id]!)
                if built[id] != nil {
                    let turn = slot.turn
                    built[id]!.model.update(turn: turn, context: context)
                    built[id]!.turn = turn
                    built[id]!.answer = Self.answerText(of: turn, in: slot.messages)
                }
                remember(placed[id]!, id: id)
            } else {
                var held = Placed(
                    slot: slot, context: context, anchor: nil, anchorMessageID: nil, revision: 0)
                place(&held)
                if id != latestTurnID { bumpShape() }
                placed[id] = held
                remember(held, id: id)
                arrival.append(id)
            }
            if id == latestTurnID { _ = made(id) }
        }
        order = ordered
        if arrival.count > Self.capacity { evict() }
    }

    /// What the transcript needs of a turn from its outline: where its row goes, which parts it
    /// consumes, which messages and board calls belong to it, and a new revision.
    private func place(_ held: inout Placed) {
        counter += 1
        held.revision = counter
        let outline = held.slot.outline
        held.anchor = outline.anchor
        held.anchorMessageID = outline.anchorMessageID
    }

    /// The steps, model, answer and prompt of a turn, made now if nothing has asked for them.
    @discardableResult
    private func made(_ turnID: String) -> Made? {
        if let made = built[turnID] { return made }
        guard let held = placed[turnID] else { return nil }
        let turn = held.slot.turn
        let made = Made(
            turn: turn, model: NeuralBrainModel(turn: turn, context: held.context),
            answer: Self.answerText(of: turn, in: held.slot.messages),
            prompt: Self.prompt(asked: held.slot.asked))
        built[turnID] = made
        return made
    }

    /// Holds the live turn's context: what the machine is doing, how full the window is, whether a
    /// call is open. A turn that is not the newest carries none of it, only the level the chat is
    /// on and the levels its model takes, which a turn whose messages recorded no effort wears so
    /// no head contradicts the composer's pill. Returns whether the model of any brain changed, so
    /// a caller restates only then.
    @discardableResult
    func setContext(_ context: NeuralBrainContext) -> Bool {
        let context = Self.settled(context, against: liveContext)
        var changed = adoptChatContext(of: context)
        guard context != liveContext else { return changed }
        contextChanges += 1
        liveContext = context
        guard let id = latestTurnID, placed[id] != nil, placed[id]!.context != context else {
            return changed
        }
        placed[id]!.context = context
        if let turn = built[id]?.turn {
            built[id]!.model.update(turn: turn, context: context)
        }
        changed = true
        return changed
    }

    /// The part of a context every turn of the chat shares, brought to the older brains the moment
    /// the person's level or the model's levels move: a pick in the dial restates every head, and
    /// a streamed token, which moves neither, costs one comparison.
    private func adoptChatContext(of context: NeuralBrainContext) -> Bool {
        let shared = NeuralBrainContext(effortOptions: context.effortOptions, effort: context.effort)
        guard shared != chatContext else { return false }
        chatContext = shared
        var changed = false
        for id in placed.keys where id != latestTurnID && placed[id]!.context != shared {
            placed[id]!.context = shared
            if let turn = built[id]?.turn {
                built[id]!.model.update(turn: turn, context: shared)
            }
            changed = true
        }
        if changed { bumpShape() }
        return changed
    }

    /// The context with its fill kept as it was while the fill has not moved by anything the head
    /// can show: the window's fill is estimated from the words so far and so changes by a few
    /// tokens at every token, but the head wears it as a share, and a share that has not moved a
    /// percent is not news to restate every view for.
    private static func settled(
        _ context: NeuralBrainContext, against held: NeuralBrainContext
    ) -> NeuralBrainContext {
        guard let old = held.fill, let new = context.fill, old.window == new.window,
            old.model == new.model, old.basis == new.basis, old.tone == new.tone,
            old.percent == new.percent, old.percent != nil || old.used / 1000 == new.used / 1000
        else { return context }
        var kept = context
        kept.fill = old
        return kept
    }

    func clear() {
        bumpShape()
        settled = nil
        tailStamp = nil
        tailTimer?.invalidate()
        tailTimer = nil
        restateTimer?.invalidate()
        restateTimer = nil
        guard !placed.isEmpty || !order.isEmpty else { return }
        placed = [:]
        built = [:]
        searchCache = [:]
        order = []
        messageTurn = [:]
        boardOwner = [:]
        arrival = []
        openTurnID = nil
        latestTurnID = nil
    }

    /// How many turns have their steps read and a model made, which is the newest and the ones that
    /// were looked at.
    var madeCount: Int { built.count }

    func entry(_ turnID: String) -> Entry? {
        guard let held = placed[turnID], let made = made(turnID) else { return nil }
        return Entry(
            turn: made.turn, model: made.model, context: held.context, anchor: held.anchor,
            anchorMessageID: held.anchorMessageID, messageIDs: Set(held.outline.messageIDs),
            boardKeys: Set(held.outline.boardPartIDs), answer: made.answer, prompt: made.prompt,
            revision: held.revision)
    }

    /// Changes one model in place and returns what the change answered. A hover, a pin, a replay.
    @discardableResult
    func withModel<Value>(
        _ turnID: String, _ body: (inout NeuralBrainModel) -> Value
    ) -> Value? {
        guard made(turnID) != nil else { return nil }
        return body(&built[turnID]!.model)
    }

    func model(_ turnID: String) -> NeuralBrainModel? {
        if let model = built[turnID]?.model { return model }
        return made(turnID)?.model
    }

    func isOpen(_ turnID: String) -> Bool { openTurnID == turnID }

    func row(forTurn turnID: String) -> TranscriptRow? {
        guard let held = placed[turnID] else { return nil }
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
        let before = NeuralOpenPolicy(turnIDs: turnIDs, isRunning: isRunning, choices: choices)
        swapping = []
        if let open = before.openTurnID, open != turnID { swapping = [open, turnID] }
        userToggled?()
        choices = before.toggle(turnID: turnID)
        openTurnID = NeuralOpenPolicy(
            turnIDs: turnIDs, isRunning: isRunning, choices: choices
        ).openTurnID
        bumpShape()
        onChange?()
    }

    /// Opens or closes one turn's brain when it is not already so; the person's choice either way.
    func setOpen(_ open: Bool, turnID: String) {
        guard isOpen(turnID) != open else { return }
        toggleOpen(turnID)
    }

    /// Find landed on this turn's brain: it opens, and the cursor goes to the first step that holds
    /// the words, which the account then shows with the match.
    func landFind(turnID: String, needle: String) {
        guard placed[turnID] != nil, !needle.isEmpty else { return }
        pendingFind[turnID] = needle
        if isOpen(turnID) {
            view(forTurn: turnID)?.applyPendingFind()
        } else {
            toggleOpen(turnID)
        }
    }

    /// The first step of a turn whose words hold `needle`, in the order the steps ran.
    func stepHolding(_ needle: String, turnID: String) -> String? {
        let lowered = needle.lowercased()
        return made(turnID)?.turn.steps.first { step in
            [step.title, step.detail, step.text, step.outputLines.joined(separator: " ")]
                .contains { $0.lowercased().contains(lowered) }
        }?.id
    }

    /// The menu's one verb: the open brain closes, and with none open the newest turn's opens.
    func toggleNewest() {
        if let open = openTurnID {
            toggleOpen(open)
        } else if let newest = order.last {
            toggleOpen(newest)
        }
    }

    func view(forTurn turnID: String) -> BrainRowView? {
        views.allObjects.first { $0.row.turnID == turnID }
    }

    /// The message and part the turn's answer starts in, for the account's answer item.
    func answerTarget(turnID: String) -> (messageID: String, part: String)? {
        guard let first = placed[turnID]?.slot.outline.answerPartIDs.first,
            let colon = first.firstIndex(of: ":")
        else { return nil }
        return (String(first[..<colon]), first)
    }

    /// Rows puts the steps' old rows inline under that turn's brain, and puts them away again.
    func toggleRows(_ turnID: String) {
        if rowsShown.contains(turnID) { rowsShown.remove(turnID) } else { rowsShown.insert(turnID) }
        bumpShape()
        onChange?()
    }

    func showsRows(_ turnID: String) -> Bool { rowsShown.contains(turnID) }

    func ownsMessage(_ messageID: String) -> Bool { messageTurn[messageID] != nil }

    /// The words find reads in a brain: every step's tool, argument, thought and printed lines.
    /// Made once for a turn as it stands, from its steps alone, and only for a turn find asks about.
    func searchText(turnID: String) -> String {
        guard let held = placed[turnID] else { return "" }
        if let hit = searchCache[turnID], hit.slot === held.slot { return hit.text }
        let text = held.slot.turn.steps.map { step in
            [step.title, step.detail, step.text, step.outputLines.joined(separator: " ")]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: " ")
        searchCache[turnID] = (held.slot, text)
        return text
    }

    /// The words of a turn if find has read them already, and nothing otherwise: what a keystroke
    /// reads while the sliced pass that reads the rest is still running.
    func indexedSearchText(turnID: String) -> String {
        guard let held = placed[turnID], let hit = searchCache[turnID], hit.slot === held.slot
        else { return "" }
        return hit.text
    }

    /// Reads the words of brains find has not read, newest first, until `budget` seconds are spent,
    /// and returns whether every brain has been read.
    func indexSearch(budget: TimeInterval) -> Bool {
        let deadline = CACurrentMediaTime() + budget
        for id in order.reversed() {
            guard let held = placed[id] else { continue }
            if let hit = searchCache[id], hit.slot === held.slot { continue }
            if CACurrentMediaTime() >= deadline { return false }
            _ = searchText(turnID: id)
        }
        return true
    }

    /// Brings every view up to the models, for a change the rows cannot carry: the machine's
    /// state, the window's fill, a call.
    func viewportMoved() {
        for view in views.allObjects { view.viewportMoved() }
    }

    /// The least time between two restatements of the views: one frame. Tokens that arrive inside
    /// it are one restatement, made when the frame is over.
    static let restateSpacing = 1.0 / 60
    private var restatedAt = 0.0
    private var restateTimer: Timer?

    /// Asks the views to restate themselves, at most once a frame. A row whose model did not move
    /// since it last restated does nothing.
    func restateViews() {
        let now = CACurrentMediaTime()
        let wait = Self.restateSpacing - (now - restatedAt)
        guard wait > 0 else {
            restateNow()
            return
        }
        guard restateTimer == nil else { return }
        restateTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.restateNow() }
        }
    }

    private func restateNow() {
        restateTimer?.invalidate()
        restateTimer = nil
        restatedAt = CACurrentMediaTime()
        restateCalls += 1
        for view in views.allObjects where view.refresh() { restateWork += 1 }
    }

    /// The newest head while its turn is running: its duration moves once a second with no state to
    /// carry it, so the pane's own second asks for it.
    func restateLive() {
        guard isRunning, let id = latestTurnID else { return }
        for view in views.allObjects where view.row.turnID == id { view.refresh(force: true) }
    }

    /// A pane that parks gives up every head it owns, and the process's textures with the last of
    /// them; unparked, the open brain draws again.
    func parkViews(_ parked: Bool) {
        for view in views.allObjects { view.setParked(parked) }
    }

    /// One number that changes when the way a message's rows are shaped changes: the turn it is in
    /// moved, or the person asked for its old rows.
    func stamp(forMessage messageID: String) -> Int? {
        guard let turnID = messageTurn[messageID], let held = placed[turnID] else { return nil }
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
        let begun = CACurrentMediaTime()
        defer { spent += CACurrentMediaTime() - begun }
        guard let turnID = messageTurn[message.id], let held = placed[turnID] else { return rows }
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
            if !listsRows, let part, held.outline.consumes(keys[part]) { continue }
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

    private func remember(_ held: Placed, id: String) {
        for message in held.outline.messageIDs { messageTurn[message] = id }
        for key in held.outline.boardPartIDs { boardOwner[key] = id }
    }

    private func forget(_ held: Placed) {
        let id = held.outline.id
        for message in held.outline.messageIDs where messageTurn[message] == id {
            messageTurn[message] = nil
        }
        for key in held.outline.boardPartIDs where boardOwner[key] == id { boardOwner[key] = nil }
    }

    private func evict() {
        let keep = Set(order)
        bumpShape()
        while arrival.count > Self.capacity {
            let oldest = arrival.removeFirst()
            guard !keep.contains(oldest), let held = placed[oldest] else { continue }
            forget(held)
            placed[oldest] = nil
            built[oldest] = nil
            searchCache[oldest] = nil
        }
    }

    /// The words of the message that began a turn: the question the poster quotes.
    private static func prompt(asked: ChatMessage?) -> String? {
        guard let asked else { return nil }
        let words = asked.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// The model of a turn as a picture should show it: at rest, with nothing hovered, pinned,
    /// pointed at or replaying.
    func restingModel(_ turnID: String) -> NeuralBrainModel? {
        guard var model = made(turnID)?.model else { return nil }
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
