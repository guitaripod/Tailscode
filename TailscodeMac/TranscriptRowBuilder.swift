import AppKit
import CodingAgentKit
import TailscodeCore

/// Folds messages into rows with a per-message memo: a streamed token changes one message, so
/// re-deriving the other two hundred and ninety-nine — markdown and all — on every state would be
/// the seconds-long pause between "Loading…" and the transcript. Only messages whose value
/// actually changed are re-folded.
@MainActor
final class TranscriptRowBuilder {
    /// A message's rows once the brain has taken what it consumes, held with the number that says
    /// how it was shaped, so a conversation of finished turns is shaped once and not on every
    /// token.
    private struct Shaped {
        let stamp: Int
        let railKept: Bool
        let rows: [TranscriptRow]
    }

    private typealias Entry = (
        message: ChatMessage, promptID: String?, sealed: Bool, rows: [TranscriptRow],
        trailingRail: String?, shaped: Shaped?
    )

    /// The rows of every message before the newest turn's question, already shaped, laid out and
    /// folded into runs, with what they were made from. A streamed token changes the newest turn
    /// and nothing before it, and a run of tool calls never reaches across a question, so those
    /// rows are final until a message in them, the brain's view of them or the turn's openness
    /// changes; the rebuild then lays out only the newest turn.
    private struct Prefix {
        let messages: [ChatMessage]
        let turnOpen: Bool
        let stamp: Int
        let rows: [TranscriptRow]
        let hadRows: Bool
        let prompt: ChatMessage?
    }

    private var cache: [String: Entry] = [:]
    private var prefix: Prefix?
    private var seamTracker = ModelSeamTracker()
    private var seams: [String: ModelSwitch] = [:]

    /// The model catalog the seams' words are read against. A catalog that grows or shrinks can
    /// rename a model, so the held prefix, which carries the seams it was laid out with, is let
    /// go; the tracker starts over on its own.
    var catalog: [ModelInfo] = [] {
        didSet {
            if catalog.count != oldValue.count { prefix = nil }
        }
    }
    private var lastMessages: [ChatMessage] = []

    /// Whether this is the array the last rebuild was handed, not one equal to it: an array that
    /// shares storage with another is the same messages without looking at one of them, which is
    /// what a rebuild for a choice the person made (a brain opened) is.
    private func isLastMessages(_ messages: [ChatMessage]) -> Bool {
        messages.count == lastMessages.count
            && messages.withUnsafeBufferPointer { now in
                lastMessages.withUnsafeBufferPointer { before in now.baseAddress == before.baseAddress }
            }
    }
    private var builtWithEmbeds = LinkEmbedsSetting.isEnabled
    private var builtWithDensity = ChatDensitySetting.current

    /// The pane's brains. Nil, or a store that is not active, leaves every row exactly where it
    /// was before the brain existed.
    var brains: BrainStore?

    /// How many tool calls finished since the rows were last asked for: the edges the trackpad
    /// reports as progress. Counted from the messages as they change, so a conversation of hundreds
    /// of messages is never walked to find the one call that completed.
    private(set) var completions = 0

    /// How many rebuilds took the whole conversation and how many only its newest turn, for the
    /// bench and the selftest that prove a streamed token costs the turn and not the conversation.
    private(set) var wholeRebuilds = 0
    private(set) var tailRebuilds = 0

    /// The completions counted since the last call, handed over once.
    func takeCompletions() -> Int {
        defer { completions = 0 }
        return completions
    }

    /// Forgets every memoised row — the rendering baked into them (fonts, markdown) is stale
    /// after a type-scale change. The link switch and the density do the same by themselves: the
    /// rails are rows, and a density is a size every picture and line was built to.
    func invalidate() {
        cache = [:]
        prefix = nil
    }

    /// A turn that said nothing is read against the question it answers, so the prompt walks along
    /// with the fold and is part of what a memoised row was folded from: the same assistant message
    /// under a different question is a different card, and reusing the earlier one would offer the
    /// wrong words to send again.
    func rows(
        for messages: [ChatMessage], turnOpen: Bool = false, awaiting: NeuralAwaiting = .none
    ) -> [TranscriptRow] {
        if builtWithEmbeds != LinkEmbedsSetting.isEnabled
            || builtWithDensity != ChatDensitySetting.current
        {
            builtWithEmbeds = LinkEmbedsSetting.isEnabled
            builtWithDensity = ChatDensitySetting.current
            cache = [:]
            prefix = nil
        }
        let brains = brains.flatMap { $0.isActive ? $0 : nil }
        seams = seamTracker.update(messages, catalog: catalog)
        let same = isLastMessages(messages)
        lastMessages = messages
        let verified = prefixHolds(messages, turnOpen: turnOpen, same: same)
        if let brains {
            brains.read(
                messages: messages, running: turnOpen, awaiting: awaiting, mayDefer: verified)
        } else {
            self.brains?.clear()
        }
        if let rows = extended(messages, turnOpen: turnOpen, brains: brains, prefixHolds: verified) {
            return rows
        }
        return rebuilt(messages, turnOpen: turnOpen, brains: brains)
    }

    /// One message's rows as the transcript draws them: folded (or the memo's fold), its closing
    /// rail left out until nothing can be written into the run, and the brain's turn applied.
    private func process(
        _ message: ChatMessage, prompt: ChatMessage?, writing: String?, turnOpen: Bool,
        brains: BrainStore?
    ) -> (rows: [TranscriptRow], entry: Entry) {
        let folded: [TranscriptRow]
        let trailing: String?
        var shaped: Shaped?
        let sealed = MessageSegment.isSealed(
            streaming: message.isStreaming, isNewest: message.id == writing, turnOpen: turnOpen)
        if let hit = cache[message.id], hit.message == message, hit.promptID == prompt?.id,
            hit.sealed == sealed
        {
            folded = hit.rows
            trailing = hit.trailingRail
            shaped = hit.shaped
        } else {
            let fold = TranscriptRow.fold(for: message, prompt: prompt, sealed: sealed)
            folded = fold.rows
            trailing = fold.trailingRail
            completions += Self.completed(message, since: cache[message.id]?.message)
        }
        var rows = folded
        if let trailing {
            let settled = LinkRailPolicy.isSettled(
                lastRowIsLive: !sealed, followedByFurniture: message.id != writing,
                turnIsOpen: turnOpen)
            if !settled { rows.removeAll { $0.key == trailing } }
        }
        if let brains, let stamp = brains.stamp(forMessage: message.id) {
            let railKept = rows.count == folded.count
            if let held = shaped, held.stamp == stamp, held.railKept == railKept {
                rows = held.rows
            } else {
                rows = brains.shape(rows, of: message)
                shaped = Shaped(stamp: stamp, railKept: railKept, rows: rows)
            }
        } else {
            shaped = nil
        }
        if !rows.isEmpty, let change = seams[message.id] {
            rows.insert(Self.seamRow(change, before: message), at: 0)
        }
        return (rows, (message, prompt?.id, sealed, folded, trailing, shaped))
    }

    /// The line that stands ahead of the answer a different model wrote. It is keyed by that
    /// answer, so it keeps its view for as long as the answer does.
    private static func seamRow(_ change: ModelSwitch, before message: ChatMessage) -> TranscriptRow {
        TranscriptRow(key: "\(message.id):modelseam", kind: .modelSeam(change))
    }

    /// What the brain says about the messages above the newest turn, as one number: the store's
    /// shape epoch moves when any turn's membership, revision, openness or listed rows may have, and
    /// the count says how long a run it is for.
    private func stamp(of messages: ArraySlice<ChatMessage>, brains: BrainStore?) -> Int {
        var hasher = Hasher()
        guard let brains else { return hasher.finalize() }
        hasher.combine(brains.shapeEpoch)
        hasher.combine(messages.count)
        return hasher.finalize()
    }

    private static func isBoardRow(_ row: TranscriptRow) -> Bool {
        guard case .tool(let call) = row.kind else { return false }
        return TaskBoard.isBoardCall(call.name)
    }

    /// The rows laid out as a transcript shows them: the plan promoted to a board, the brain's
    /// superseded board calls dropped, and runs folded.
    private func finish(_ base: [TranscriptRow], brains: BrainStore?) -> [TranscriptRow] {
        var all = TranscriptRow.placeBoard(in: base)
        if let brains {
            all.removeAll { row in
                guard Self.isBoardRow(row) else { return false }
                return brains.isSupersededBoardCall(row.key)
            }
        }
        return TranscriptRow.gallery(TranscriptRow.compactTools ? TranscriptRow.fuse(all) : all)
    }

    /// The whole conversation, and the prefix the next arrivals can build on.
    private func rebuilt(
        _ messages: [ChatMessage], turnOpen: Bool, brains: BrainStore?
    ) -> [TranscriptRow] {
        wholeRebuilds += 1
        var base: [TranscriptRow] = []
        var starts: [Int] = []
        var next: [String: Entry] = [:]
        next.reserveCapacity(messages.count)
        let writing = messages.last?.id
        var prompt: ChatMessage?
        for message in messages {
            let made = process(
                message, prompt: prompt, writing: writing, turnOpen: turnOpen, brains: brains)
            next[message.id] = made.entry
            starts.append(base.count)
            if message.role == .user { prompt = message }
            guard !made.rows.isEmpty else { continue }
            if message.role == .user, !base.isEmpty {
                base.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            base += made.rows
        }
        cache = next
        let result = finish(base, brains: brains)
        prefix = nil
        if let cut = messages.lastIndex(where: { $0.role == .user }), cut > 0 {
            let at = starts[cut]
            if !base[at...].contains(where: Self.isBoardRow) {
                prefix = Prefix(
                    messages: Array(messages[..<cut]), turnOpen: turnOpen,
                    stamp: stamp(of: messages[..<cut], brains: brains),
                    rows: finish(Array(base[..<at]), brains: brains), hadRows: at > 0,
                    prompt: messages[..<cut].last { $0.role == .user })
            }
        }
        return result
    }

    /// Whether the held prefix is still what the conversation begins with: the same openness, a
    /// newest question where the prefix ends, and every message above it the message it was. One
    /// comparison per rebuild, made before the brain reads, so that a change far up the page is
    /// never waited on.
    private func prefixHolds(_ messages: [ChatMessage], turnOpen: Bool, same: Bool = false) -> Bool {
        guard let held = prefix, held.turnOpen == turnOpen, messages.count > held.messages.count,
            messages[held.messages.count].role == .user
        else { return false }
        if same { return true }
        for index in held.messages.indices where held.messages[index] != messages[index] {
            return false
        }
        return true
    }

    /// The newest turn laid out on top of a prefix that has not moved, or nil when something in the
    /// prefix did, the newest turn holds a plan (whose board may be promoted from an earlier
    /// call), or there is no prefix yet: the whole conversation is then laid out again.
    private func extended(
        _ messages: [ChatMessage], turnOpen: Bool, brains: BrainStore?, prefixHolds: Bool
    ) -> [TranscriptRow]? {
        guard prefixHolds, let held = prefix,
            stamp(of: messages[..<held.messages.count], brains: brains) == held.stamp
        else { return nil }
        let from = held.messages.count
        let writing = messages.last?.id
        var prompt = held.prompt
        var tail: [TranscriptRow] = []
        var starts: [Int] = []
        for index in from..<messages.count {
            let message = messages[index]
            let made = process(
                message, prompt: prompt, writing: writing, turnOpen: turnOpen, brains: brains)
            cache[message.id] = made.entry
            starts.append(tail.count)
            if message.role == .user { prompt = message }
            guard !made.rows.isEmpty else { continue }
            if message.role == .user, held.hadRows || !tail.isEmpty {
                tail.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            tail += made.rows
        }
        guard !tail.contains(where: Self.isBoardRow) else {
            prefix = nil
            return nil
        }
        tailRebuilds += 1
        let folded = TranscriptRow.compactTools ? TranscriptRow.fuse(tail) : tail
        let result = held.rows + folded
        if let later = (from..<messages.count).last(where: { messages[$0].role == .user }),
            later > from
        {
            let rowCut = starts[later - from]
            let head = Array(tail[..<rowCut])
            prefix = Prefix(
                messages: Array(messages[..<later]), turnOpen: turnOpen,
                stamp: stamp(of: messages[..<later], brains: brains),
                rows: held.rows + (TranscriptRow.compactTools ? TranscriptRow.fuse(head) : head),
                hadRows: held.hadRows || rowCut > 0,
                prompt: messages[..<later].last { $0.role == .user })
        }
        return result
    }

    /// The conversation laid out the plain way, with no memo and no prefix, for the selftest that
    /// proves the tail rebuild gives exactly these rows.
    static func referenceRows(
        for messages: [ChatMessage], turnOpen: Bool, catalog: [ModelInfo] = []
    ) -> [TranscriptRow] {
        var all: [TranscriptRow] = []
        var tracker = ModelSeamTracker()
        let seams = tracker.update(messages, catalog: catalog)
        let writing = messages.last?.id
        var prompt: ChatMessage?
        for message in messages {
            let sealed = MessageSegment.isSealed(
                streaming: message.isStreaming, isNewest: message.id == writing, turnOpen: turnOpen)
            let fold = TranscriptRow.fold(for: message, prompt: prompt, sealed: sealed)
            var rows = fold.rows
            if let trailing = fold.trailingRail {
                let settled = LinkRailPolicy.isSettled(
                    lastRowIsLive: !sealed, followedByFurniture: message.id != writing,
                    turnIsOpen: turnOpen)
                if !settled { rows.removeAll { $0.key == trailing } }
            }
            if message.role == .user { prompt = message }
            guard !rows.isEmpty else { continue }
            if message.role == .user, !all.isEmpty {
                all.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            if let change = seams[message.id] {
                rows.insert(seamRow(change, before: message), at: 0)
            }
            all += rows
        }
        all = TranscriptRow.gallery(TranscriptRow.placeBoard(in: all))
        return TranscriptRow.compactTools ? TranscriptRow.gallery(TranscriptRow.fuse(all)) : all
    }

    /// How many calls in a message just completed that were not completed in the message it
    /// replaces: a call new to the conversation counts when it arrives already done, as a call
    /// that finishes while the reader waits does.
    private static func completed(_ message: ChatMessage, since old: ChatMessage?) -> Int {
        guard message.role == .assistant, let old else { return 0 }
        var before: [String: ToolStatus] = [:]
        for part in old.parts {
            if case .tool(let call) = part.kind { before[call.id] = call.status }
        }
        var count = 0
        for part in message.parts {
            guard case .tool(let call) = part.kind, call.status == .completed else { continue }
            if let was = before[call.id], was != .completed { count += 1 }
        }
        return count
    }
}
