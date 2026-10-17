import CodingAgentKit
import Foundation

/// The agent's turn told in its own words, in order, with the work it did folded into the story:
/// what the right side of an open brain is. Items are the notes it wrote between its calls (said),
/// its thinking (thought), the steps between two utterances folded to one line of work, what it
/// is waiting on you for (ask, pinned first), and the final message (answer).
///
/// An item is addressed by a stable id derived from its first step, so a streamed token changes
/// only the last item and a client's row for every other one stays the same row. The cursor can
/// sit on an utterance because a said or thought step is a step like any other: `item(containing:)`
/// finds the item a step id belongs to, so the list row, the account item and the head's SAY node
/// are one thing.
public struct NeuralAccount: Sendable, Equatable {
    /// A run of the same zone in a work line: its mark and how many times.
    public struct Cluster: Sendable, Equatable {
        public let zone: NeuralZone
        public let count: Int
        /// How many of them failed.
        public let failed: Int
    }

    /// A failure a later step cleared.
    public struct Retry: Sendable, Equatable {
        public let failedStepID: String
        public let retryStepID: String
        /// One-based, the retry's.
        public let number: Int
        /// "retried at 11".
        public let label: String
    }

    /// A file a work line changed.
    public struct Change: Sendable, Equatable {
        public let stepID: String
        public let path: String
        public let directory: String
        public let fileName: String
        public let shortDirectory: String
        public let added: Int
        public let removed: Int
        public let tally: String?
    }

    /// A note the agent wrote between its calls.
    public struct Said: Identifiable, Sendable, Equatable {
        public let id: String
        public let stepID: String
        /// One-based place in the turn.
        public let number: Int
        /// The model's family name: "Fable".
        public let speaker: String
        public let family: ModelTint.Family?
        /// The message's clock, "21:46:11".
        public let clock: String?
        /// The words, whole.
        public let text: String
        /// The speaker and clock are written above this one: it is the first, or the speaker or
        /// the gap changed.
        public let showsSpeaker: Bool
        public let lineCount: Int
        /// The lines shown before "Show all".
        public let collapsedLines: Int

        public var hasMore: Bool { lineCount > collapsedLines }
    }

    /// The agent's thinking: muted, one line, unfolded on request.
    public struct Thought: Identifiable, Sendable, Equatable {
        public let id: String
        public let stepID: String
        public let number: Int
        public let firstLine: String
        public let text: String
        public let lineCount: Int

        /// There is more to show than the one line.
        public var canUnfold: Bool { lineCount > 1 || text.count > firstLine.count }
    }

    /// The steps between two utterances, folded to one line.
    public struct Work: Identifiable, Sendable, Equatable {
        public let id: String
        public let stepIDs: [String]
        /// One-based, in order: the chips that set the cursor.
        public let numbers: [Int]
        /// The zone marks of what ran, in order, a run of one zone being one mark with a count.
        public let clusters: [Cluster]
        public let failureCount: Int
        public let firstFailedStepID: String?
        public let retries: [Retry]
        public let changes: [Change]
        public let added: Int
        public let removed: Int
        /// "+5 \u{2212}2" for what the work wrote.
        public let tally: String?
        /// The one line, from the reading: "Ran 3 commands, read 2 files."
        public let words: String
    }

    /// What the agent is waiting on you for, in its own words.
    public struct Ask: Identifiable, Sendable, Equatable {
        public let id: String
        public let stepID: String
        public let number: Int
        public let isApproval: Bool
        /// "Waiting for your approval", "Waiting for your answer".
        public let sentence: String
        /// "Go to approval", "Go to question": scrolls to the card that carries the real ask.
        public let actionLabel: String
        /// The command it wants to run, or the question it asks.
        public let subject: String
        public let subjectKind: NeuralReadout.Subject.Kind
        /// The reason that came right before it.
        public let why: NeuralReadout.Why?
        /// The options a question offers.
        public let options: [String]
    }

    /// The final message.
    public struct Answer: Identifiable, Sendable, Equatable {
        public let id: String
        /// "Then it answered".
        public let label: String
        /// The first line of the final text, when the client passed it.
        public let firstLine: String?
    }

    public enum Item: Identifiable, Sendable, Equatable {
        case said(Said)
        case thought(Thought)
        case work(Work)
        case ask(Ask)
        case answer(Answer)

        public var id: String {
            switch self {
            case .said(let said): return said.id
            case .thought(let thought): return thought.id
            case .work(let work): return work.id
            case .ask(let ask): return ask.id
            case .answer(let answer): return answer.id
            }
        }

        /// The steps the item stands for: what its chips set the cursor to.
        public var stepIDs: [String] {
            switch self {
            case .said(let said): return [said.stepID]
            case .thought(let thought): return [thought.stepID]
            case .work(let work): return work.stepIDs
            case .ask(let ask): return [ask.stepID]
            case .answer: return []
            }
        }

        public var isUtterance: Bool {
            switch self {
            case .said, .thought: return true
            case .work, .ask, .answer: return false
            }
        }
    }

    /// How long a note's first lines are shown before "Show all".
    public static let saidCollapsedLines = 6
    /// A pause this long between two notes writes the speaker again.
    public static let speakerGap: TimeInterval = 60
    public static let idPrefixSaid = "said:"
    public static let idPrefixThought = "thought:"
    public static let idPrefixWork = "work:"
    public static let idPrefixAsk = "ask:"
    public static let idPrefixAnswer = "answer:"

    /// The items in order, with the ask first when one is pending.
    public let items: [Item]
    /// An approval or a question is waiting: it leads the items.
    public let needsYou: Bool
    /// The final message, nil while the turn runs.
    public let answer: Answer?
    /// The model that spoke, as the account names it.
    public let speaker: String
    /// How many notes the agent wrote.
    public let utteranceCount: Int
    /// How many times it thought aloud.
    public let thoughtCount: Int
    /// The model's revision this was read at.
    public let revision: Int

    private let owner: [String: Int]
    private let stepIndex: [String: Int]
    private let saidOrder: [(index: Int, itemIndex: Int)]

    public static func == (lhs: NeuralAccount, rhs: NeuralAccount) -> Bool {
        lhs.items == rhs.items && lhs.needsYou == rhs.needsYou && lhs.answer == rhs.answer
            && lhs.speaker == rhs.speaker && lhs.revision == rhs.revision
    }

    /// Reads the turn into its account. Clocks are the messages' own in `tz`; `now` is accepted so
    /// a caller passes the same arguments as the readout's, and nothing is read from it. `answer`
    /// is the final message's text, which the model does not hold.
    public static func make(
        model: NeuralBrainModel, now: Date = Date(), tz: TimeZone = .current, answer: String? = nil
    ) -> NeuralAccount {
        let steps = model.steps
        let turn = model.turn
        let speaker = speakerName(modelID: turn.modelID, providerID: model.context.providerID)
        let family = turn.modelID.flatMap {
            ModelTint.family($0, providerID: model.context.providerID)
        }
        var items: [Item] = []
        var pending: [Int] = []
        var owner: [String: Int] = [:]
        var order: [(index: Int, itemIndex: Int)] = []
        var thoughts = 0
        var previousSaid: (speaker: String, at: Date?)?
        let builder = NeuralReadoutBuilder(model: model, now: now, tz: tz, answer: nil)

        func flush() {
            guard !pending.isEmpty else { return }
            let work = makeWork(pending, steps: steps)
            for id in work.stepIDs { owner[id] = items.count }
            items.append(.work(work))
            pending = []
        }

        for (index, step) in steps.enumerated() {
            if NeuralReading.isThought(step) {
                flush()
                thoughts += 1
                let lines = NeuralReadoutText.rawLineCount(step.text)
                owner[step.id] = items.count
                items.append(
                    .thought(
                        Thought(
                            id: idPrefixThought + step.id, stepID: step.id, number: index + 1,
                            firstLine: NeuralReadoutText.oneLine(
                                NeuralReadoutText.firstLine(step.text), limit: 160),
                            text: step.text, lineCount: max(lines, 1))))
            } else if NeuralReading.isNote(step) {
                flush()
                let lines = NeuralReadoutText.rawLineCount(step.text)
                let shows =
                    previousSaid == nil || previousSaid?.speaker != speaker
                    || gapBetween(previousSaid?.at, step.at) >= speakerGap
                previousSaid = (speaker, step.at)
                owner[step.id] = items.count
                order.append((index, items.count))
                items.append(
                    .said(
                        Said(
                            id: idPrefixSaid + step.id, stepID: step.id, number: index + 1,
                            speaker: speaker, family: family,
                            clock: step.at.map { NeuralReading.clock($0, timeZone: tz) },
                            text: step.text, showsSpeaker: shows, lineCount: max(lines, 1),
                            collapsedLines: saidCollapsedLines)))
            } else {
                pending.append(index)
            }
        }
        flush()

        var shown = answerItem(turn: turn, text: answer)
        if turn.outcome == .running { shown = nil }
        if let shown { items.append(.answer(shown)) }

        var needsYou = false
        if let waiting = NeuralReadout.waitingStep(in: steps), let at = model.indexOf(waiting.id) {
            needsYou = true
            items.insert(.ask(makeAsk(waiting, at: at, builder: builder)), at: 0)
            for key in owner.keys { owner[key] = owner[key].map { $0 + 1 } }
            order = order.map { ($0.index, $0.itemIndex + 1) }
        }
        var indices: [String: Int] = [:]
        for (index, step) in steps.enumerated() { indices[step.id] = index }
        return NeuralAccount(
            items: items, needsYou: needsYou, answer: shown, speaker: speaker,
            utteranceCount: order.count, thoughtCount: thoughts, revision: model.revision,
            owner: owner, stepIndex: indices, saidOrder: order)
    }

    private init(
        items: [Item], needsYou: Bool, answer: Answer?, speaker: String, utteranceCount: Int,
        thoughtCount: Int, revision: Int, owner: [String: Int], stepIndex: [String: Int],
        saidOrder: [(index: Int, itemIndex: Int)]
    ) {
        self.items = items
        self.needsYou = needsYou
        self.answer = answer
        self.speaker = speaker
        self.utteranceCount = utteranceCount
        self.thoughtCount = thoughtCount
        self.revision = revision
        self.owner = owner
        self.stepIndex = stepIndex
        self.saidOrder = saidOrder
    }

    private static func gapBetween(_ a: Date?, _ b: Date?) -> TimeInterval {
        guard let a, let b else { return 0 }
        return abs(b.timeIntervalSince(a))
    }

    // MARK: Reading

    /// What the account calls the model that spoke: the family's name, else the model's own id
    /// without its door, else "Agent".
    public static func speakerName(modelID: String?, providerID: String? = nil) -> String {
        guard let modelID, !modelID.isEmpty else { return Localized.text("Agent") }
        if let family = ModelTint.family(modelID, providerID: providerID) {
            return familyName(family)
        }
        let tail = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return tail.isEmpty ? Localized.text("Agent") : tail
    }

    private static func familyName(_ family: ModelTint.Family) -> String {
        switch family {
        case .gpt: return "GPT"
        case .glm: return "GLM"
        case .deepseek: return "DeepSeek"
        case .minimax: return "MiniMax"
        case .kimi: return "Kimi"
        default: return family.rawValue.prefix(1).uppercased() + family.rawValue.dropFirst()
        }
    }

    /// The first note the agent wrote, if it wrote any.
    public static func firstSaid(in steps: [NeuralStep]) -> NeuralStep? {
        steps.first { NeuralReading.isNote($0) }
    }

    private static func makeWork(_ indices: [Int], steps: [NeuralStep]) -> Work {
        let members = indices.map { steps[$0] }
        var clusters: [Cluster] = []
        var failures = 0
        var firstFailed: String?
        for step in members {
            let failed = step.status == .failed
            if failed {
                failures += 1
                if firstFailed == nil { firstFailed = step.id }
            }
            if let last = clusters.last, last.zone == step.zone {
                clusters[clusters.count - 1] = Cluster(
                    zone: last.zone, count: last.count + 1, failed: last.failed + (failed ? 1 : 0))
            } else {
                clusters.append(Cluster(zone: step.zone, count: 1, failed: failed ? 1 : 0))
            }
        }
        var retries: [Retry] = []
        for index in indices {
            let step = steps[index]
            guard step.status == .failed, step.recovered, step.tieIsCommand, let key = step.tieKey,
                let later = steps[(index + 1)...].first(where: {
                    $0.tieIsCommand && $0.tieKey == key && $0.status == .ok
                })
            else { continue }
            retries.append(
                Retry(
                    failedStepID: step.id, retryStepID: later.id, number: later.index + 1,
                    label: NeuralReading.retriedAt(later.index + 1)))
        }
        var order: [String] = []
        var changed: [String: (id: String, added: Int, removed: Int)] = [:]
        for step in members where step.zone == .act && step.status == .ok {
            guard let path = step.tieKey ?? (step.detail.isEmpty ? nil : step.detail) else {
                continue
            }
            var entry = changed[path] ?? (step.id, 0, 0)
            if changed[path] == nil { order.append(path) }
            entry.added += step.added ?? 0
            entry.removed += step.removed ?? 0
            changed[path] = entry
        }
        let changes = order.compactMap { path -> Change? in
            guard let entry = changed[path] else { return nil }
            let parts = NeuralReadoutText.split(path: path)
            return Change(
                stepID: entry.id, path: path, directory: parts.directory, fileName: parts.file,
                shortDirectory: NeuralReadoutText.shortDirectory(parts.directory),
                added: entry.added, removed: entry.removed,
                tally: NeuralReading.tally(entry.added, entry.removed))
        }
        let added = changes.reduce(0) { $0 + $1.added }
        let removed = changes.reduce(0) { $0 + $1.removed }
        return Work(
            id: idPrefixWork + members[0].id, stepIDs: members.map(\.id),
            numbers: indices.map { $0 + 1 }, clusters: clusters, failureCount: failures,
            firstFailedStepID: firstFailed, retries: retries, changes: changes, added: added,
            removed: removed, tally: NeuralReading.tally(added, removed), words: words(members))
    }

    /// "Ran 3 commands, read 2 files": the work's clauses as one sentence, from the reading.
    private static func words(_ members: [NeuralStep]) -> String {
        let census = NeuralReading.Census(members)
        let parts = NeuralNoticeLine.clauseParts(NeuralNoticeCounts(census, steps: members.count))
        guard !parts.isEmpty else {
            return NeuralNoticeLine.countText(tools: census.tools, steps: members.count)
        }
        let joined = parts.dropFirst().reduce(parts[0]) { Localized.text("%1$@, %2$@", $0, $1) }
        let capital = joined.prefix(1).uppercased() + joined.dropFirst()
        return Localized.text("%@.", capital)
    }

    private static func makeAsk(
        _ step: NeuralStep, at index: Int, builder: NeuralReadoutBuilder
    ) -> Ask {
        let approval = step.status == .waitingApproval
        var subject = NeuralReadoutBuilder.subject(of: step)
        var options: [String] = []
        if let call = step.call?.call, call.summaryKind == .question,
            let request = QuestionRequest(toolCall: call, sessionID: ""),
            let question = request.questions.first
        {
            options = question.options.map(\.label)
            if !question.question.isEmpty {
                subject = NeuralReadout.Subject(
                    kind: subject.kind, title: subject.title, primary: question.question,
                    secondary: nil, directory: nil, fileName: nil, lineCount: subject.lineCount,
                    collapsedLines: subject.collapsedLines, copyText: nil)
            }
        }
        return Ask(
            id: idPrefixAsk + step.id, stepID: step.id, number: index + 1, isApproval: approval,
            sentence: NeuralReading.ask(for: step.status),
            actionLabel: approval
                ? NeuralReading.goToApprovalLabel : NeuralReading.goToQuestionLabel,
            subject: subject.primary, subjectKind: subject.kind, why: builder.why(at: index),
            options: options)
    }

    private static func answerItem(turn: NeuralTurn, text: String?) -> Answer? {
        let first = text.map { NeuralReadoutText.firstLine($0) }.flatMap {
            $0.isEmpty ? nil : NeuralReadoutText.capped($0, limit: 200).text
        }
        guard !turn.answerPartIDs.isEmpty || first != nil else { return nil }
        return Answer(
            id: idPrefixAnswer + turn.id, label: NeuralReading.thenItAnswered, firstLine: first)
    }

    // MARK: Walking

    /// The item a step belongs to, in the story: a said or thought item for its own step, the work
    /// line for a step of work. A step waiting on you is also the `ask`, which `askItem` returns.
    public func item(containing stepID: String) -> Item? {
        owner[stepID].map { items[$0] }
    }

    /// The pinned ask, when there is one.
    public var askItem: Ask? {
        if case .ask(let ask)? = items.first { return ask }
        return nil
    }

    /// The items in the order they read: the ask is pinned above the story and is not part of it.
    public var story: [Item] {
        items.filter {
            if case .ask = $0 { return false }
            return true
        }
    }

    /// The position of an item among the story.
    public func position(of itemID: String) -> Int? {
        story.firstIndex { $0.id == itemID }
    }

    public func nextItem(after itemID: String) -> Item? {
        let list = story
        guard let at = list.firstIndex(where: { $0.id == itemID }), at + 1 < list.count else {
            return nil
        }
        return list[at + 1]
    }

    public func previousItem(before itemID: String) -> Item? {
        let list = story
        guard let at = list.firstIndex(where: { $0.id == itemID }), at > 0 else { return nil }
        return list[at - 1]
    }

    /// The first note after `stepID` in the turn; the first of all for nil. Never wraps.
    public func nextSaid(after stepID: String?) -> Said? {
        let from = stepID.flatMap { stepIndex[$0] } ?? -1
        return saidOrder.first { $0.index > from }.flatMap(said(at:))
    }

    /// The last note before `stepID`; the last of all for nil. Never wraps.
    public func previousSaid(before stepID: String?) -> Said? {
        let from = stepID.flatMap { stepIndex[$0] } ?? Int.max
        return saidOrder.last { $0.index < from }.flatMap(said(at:))
    }

    private func said(at pair: (index: Int, itemIndex: Int)) -> Said? {
        if case .said(let said) = items[pair.itemIndex] { return said }
        return nil
    }

    /// Where a note stands among the ones the agent wrote: one-based, for "said 3 of 9".
    public func saidOrdinal(of stepID: String) -> Int? {
        guard let index = stepIndex[stepID] else { return nil }
        return saidOrder.firstIndex { $0.index == index }.map { $0 + 1 }
    }

    // MARK: Quote

    /// The agent's first said words on one line, cut at a word with an ellipsis: the card's third
    /// line. Nil for a turn that said nothing.
    public func quote(maxChars: Int) -> String? {
        guard let first = saidOrder.first, let said = said(at: first) else { return nil }
        return Self.quote(of: said.text, maxChars: maxChars)
    }

    /// The same with the speaker before it: "Fable: Building it from the existing film rig\u{2026}".
    public func quoteLine(maxChars: Int) -> String? {
        quote(maxChars: max(maxChars - speaker.count - 2, 8)).map {
            Localized.text("%1$@: %2$@", speaker, $0)
        }
    }

    /// Words cut to `maxChars` on one line at a word boundary, with an ellipsis where cut.
    public static func quote(of text: String, maxChars: Int) -> String {
        NeuralReadoutText.capped(NeuralReadoutText.oneLine(text, limit: 600), limit: max(maxChars, 1)).text
    }
}

extension NeuralReading {
    /// "Then it answered": the label before the final message.
    public static var thenItAnswered: String { Localized.text("Then it answered") }

    /// "said 3 of 9", what a screen reader hears on a jump to what the agent said.
    public static func saidOrdinal(_ number: Int, of total: Int) -> String {
        Localized.text("said %1$lld of %2$lld", number, total)
    }

    public static var replyLabel: String { Localized.text("Reply") }
    public static var nothingWaiting: String { Localized.text("Nothing is waiting on you") }
}

/// Holds the account the model last read, so a client that asks for it every frame costs the
/// steps once per change. Shared by copies of the model: a copy that reads at another revision
/// simply replaces what is held.
final class NeuralAccountCache: @unchecked Sendable {
    private struct Key: Equatable {
        var stamp: Int
        var zone: String
        var answer: String?
    }

    private let lock = NSLock()
    private var key: Key?
    private var held: NeuralAccount?
    private(set) var reads = 0

    func account(
        stamp: Int, tz: TimeZone, answer: String?, make: () -> NeuralAccount
    ) -> NeuralAccount {
        let wanted = Key(stamp: stamp, zone: tz.identifier, answer: answer)
        lock.lock()
        defer { lock.unlock() }
        if let held, key == wanted { return held }
        let built = make()
        held = built
        key = wanted
        reads += 1
        return built
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

extension NeuralBrainModel {
    /// What changes the account: the layout's revision, the length of the last step's words and
    /// output (the only thing a streamed token grows), the step count, the outcome and who spoke.
    var accountStamp: Int {
        var hasher = Hasher()
        hasher.combine(revision)
        hasher.combine(turn.steps.count)
        if let last = turn.steps.last {
            hasher.combine(last.text.utf8.count)
            hasher.combine(last.status)
            hasher.combine(last.call?.call.output?.utf8.count)
        }
        hasher.combine(turn.outcome)
        hasher.combine(turn.modelID)
        hasher.combine(turn.answerPartIDs.count)
        hasher.combine(context.providerID)
        return hasher.finalize()
    }

    /// The account of this turn: read once per change, whoever asks and however often.
    public func account(
        now: Date = Date(), tz: TimeZone = .current, answer: String? = nil
    ) -> NeuralAccount {
        let model = self
        return accountCache.account(stamp: accountStamp, tz: tz, answer: answer) {
            NeuralAccount.make(model: model, now: now, tz: tz, answer: answer)
        }
    }

    /// How many times the account was actually read: a test hook for the memo.
    public var accountReads: Int { accountCache.readCount }
}
