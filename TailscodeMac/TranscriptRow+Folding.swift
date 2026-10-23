import AppKit
import CodingAgentKit
import TailscodeCore

extension TranscriptRow {
    /// The CLI records an Escape as a user line reading `[Request interrupted by user]` (or
    /// `… for tool use]`, sometimes with the next real prompt appended). That is a seam in the
    /// turn, not something the person said — it renders as a dim marker, and only the text they
    /// actually typed gets a prompt row.
    static func strippedInterruption(_ text: String) -> (interrupted: Bool, remainder: String) {
        guard text.hasPrefix("[Request interrupted") else { return (false, text) }
        guard let close = text.firstIndex(of: "]") else { return (true, "") }
        let remainder = String(text[text.index(after: close)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (true, remainder)
    }

    /// A message's rows with the rail of its closing run left out unless nothing could be written
    /// into that run any more, which is what `sealed` says when no conversation is around to ask.
    @MainActor
    /// - Parameter sealed: whether this message's text is finished, decided by the caller because
    ///   only the caller can see the conversation (`MessageSegment.isSealed`). Nil falls back to
    ///   what the record says about itself, which is all a caller with no state has.
    static func rows(
        for message: ChatMessage, prompt: ChatMessage? = nil, sealed: Bool? = nil
    ) -> [TranscriptRow] {
        let sealed = sealed ?? !message.isStreaming
        let fold = fold(for: message, prompt: prompt, sealed: sealed)
        guard !sealed, let trailing = fold.trailingRail else { return fold.rows }
        return fold.rows.filter { $0.key != trailing }
    }

    /// A message's rows, and the key of the rail of its last run when that run is the message's
    /// own end. That rail is the one thing that depends on more than the message — whether the
    /// turn is still open — so the memo keeps it in the fold and the builder decides at each
    /// arrival whether it shows, without folding the message again.
    @MainActor
    static func fold(
        for message: ChatMessage, prompt: ChatMessage?, sealed: Bool
    ) -> (rows: [TranscriptRow], trailingRail: String?) {
        var rows: [TranscriptRow] = []
        var run = ProseRun()
        var trailingRail: String?
        func closeRun(trailing: Bool) {
            guard let rail = run.rail() else {
                run = ProseRun()
                return
            }
            rows.insert(rail.row, at: rail.index)
            if trailing { trailingRail = rail.row.key }
            run = ProseRun()
        }
        for part in message.parts {
            let key = "\(message.id):\(part.id)"
            var continuesRun = false
            if case .text = part.kind { continuesRun = true }
            if !continuesRun { closeRun(trailing: false) }
            switch part.kind {
            case .text(let text):
                let stripped = AgentMarkup.strip(text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !stripped.isEmpty else { continue }
                if message.role == .user {
                    let (interrupted, remainder) = Self.strippedInterruption(stripped)
                    if interrupted {
                        rows.append(TranscriptRow(key: "\(key):int", kind: .interruption))
                    }
                    if !remainder.isEmpty {
                        rows.append(
                            TranscriptRow(
                                key: key, kind: .userText(remainder, messageID: message.id)))
                    }
                    continue
                }
                let segments = MessageSegment.split(stripped, sealed: sealed)
                for (index, segment) in segments.enumerated() {
                    switch segment {
                    case .prose(let prose):
                        rows.append(
                            TranscriptRow(
                                key: "\(key):s\(index)",
                                kind: .agentProse(
                                    text: prose, rendered: MacMarkdown.render(prose))))
                        run.add(prose, key: "\(key):s\(index)", endingAt: rows.count)
                    case .code(let language, let body):
                        rows.append(
                            TranscriptRow(
                                key: "\(key):s\(index)",
                                kind: .codeBlock(language: language, body: body)))
                    case .table(let table):
                        let growing = TableDraft.isGrowing(
                            segment: index, of: segments.count, sealed: !message.isStreaming)
                        rows.append(
                            TranscriptRow(
                                key: "\(key):s\(index)",
                                kind: growing
                                    ? .tableDraft(TableDraft(table)) : .table(table)))
                    }
                }
            case .reasoning(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                rows.append(TranscriptRow(key: key, kind: .reasoning(trimmed)))
            case .tool(let call):
                if call.asksUserQuestion, call.isAwaitingAnswer { continue }
                if let sighting = DesignReading.sighting(of: call, in: message) {
                    rows.append(TranscriptRow(key: key, kind: .designBoard(sighting)))
                    continue
                }
                rows.append(
                    TranscriptRow(
                        key: key, kind: Self.kind(for: call)))
            case .file(let reference):
                rows.append(
                    TranscriptRow(
                        key: key,
                        kind: .file(reference, mine: message.role == .user, messageID: message.id)))
            case .compaction(let compaction):
                rows.append(TranscriptRow(key: key, kind: .compaction(compaction)))
            case .note(let note):
                rows.append(TranscriptRow(key: key, kind: .note(note)))
            case .unknown:
                continue
            }
        }
        closeRun(trailing: true)
        rows = Self.gatheringAgents(rows, messageID: message.id)
        if let answerless = AnswerlessTurnReading.read(message, prompt: prompt) {
            rows.append(
                TranscriptRow(key: "\(message.id):answerless", kind: .answerless(answerless)))
        }
        if let failed = FailedTurnReading.read(message, prompt: prompt) {
            rows.append(TranscriptRow(key: "\(message.id):failed", kind: .failedTurn(failed)))
        }
        if ResponseStatsSetting.isEnabled, !rows.isEmpty,
            let stats = ResponseStats(turn: message, promptedAt: prompt?.createdAt)
        {
            rows.append(TranscriptRow(key: "\(message.id):stats", kind: .responseStats(stats)))
        }
        return (rows, trailingRail)
    }

    /// A message's agents behind one row when there are more of them than the limit, standing where
    /// the first was spawned; the rows between them keep their places.
    static func gatheringAgents(_ rows: [TranscriptRow], messageID: String) -> [TranscriptRow] {
        let members = rows.compactMap { row -> SubagentFanout.Member? in
            guard case .subagent(let call) = row.kind else { return nil }
            return SubagentFanout.Member(key: row.key, call: call)
        }
        guard members.count > SubagentFanout.inlineLimit else { return rows }
        let id = "agents:\(messageID)"
        var gathered: [TranscriptRow] = []
        var placed = false
        for row in rows {
            guard case .subagent = row.kind else {
                gathered.append(row)
                continue
            }
            if !placed {
                gathered.append(
                    TranscriptRow(
                        key: id, kind: .subagentGroup(SubagentFanout(id: id, members: members))))
                placed = true
            }
        }
        return gathered
    }

    /// The prose between two pieces of furniture, gathered as a message is folded: where its last
    /// row ended and what its paragraphs said, which is all its rail is made from.
    private struct ProseRun {
        private var texts: [String] = []
        private var lastKey = ""
        private var end = 0

        mutating func add(_ text: String, key: String, endingAt index: Int) {
            texts.append(text)
            lastKey = key
            end = index
        }

        /// The rail this run earns and where its row goes, or nil for a run that mentioned no
        /// address or when previews are off.
        func rail() -> (row: TranscriptRow, index: Int)? {
            guard !texts.isEmpty else { return nil }
            let urls = LinkRailPolicy.addresses(inRun: texts, settled: true)
            guard !urls.isEmpty else { return nil }
            return (TranscriptRow(key: "\(lastKey):rail", kind: .linkRail(urls: urls)), end)
        }
    }

    /// Rows for a whole transcript, with a hairline between turns so the reading rhythm survives
    /// density.
    @MainActor
    static func rows(for messages: [ChatMessage]) -> [TranscriptRow] {
        var all: [TranscriptRow] = []
        var prompt: ChatMessage?
        for message in messages {
            let rows = Self.rows(for: message, prompt: prompt)
            if message.role == .user { prompt = message }
            guard !rows.isEmpty else { continue }
            if message.role == .user, !all.isEmpty {
                all.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            all += rows
        }
        all = gallery(placeBoard(in: all))
        return compactTools ? gallery(fuse(all)) : all
    }

    /// The agent's plan shows once: the last call that moved the to-do list becomes the board —
    /// the fold of every board call before it — and every earlier one stays the one-line tool row
    /// it was, so a long run reads as one plan updating rather than twenty snapshots.
    ///
    /// The row keeps one identity wherever it lands. Naming it after the call it is standing on
    /// re-identified the whole card every time the agent revised its plan: a delete and an insert
    /// where a person sees one card counting up, and on a keyed diff a move rather than a repaint.
    /// There is only ever one board in a transcript, so it can simply say so.
    /// Consecutive pictures the agent made become one gallery. A picture that is the person's own
    /// stays where it is — it belongs to the prompt it was sent with — and so does anything that is
    /// not an image. The gallery is named after its first picture, so a picture arriving beside it
    /// changes the gallery's value and not its identity.
    static func gallery(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        func picture(_ row: TranscriptRow) -> GalleryPicture? {
            guard case .file(let reference, let mine, _) = row.kind, !mine,
                (reference.mime ?? "").hasPrefix("image/")
            else { return nil }
            return GalleryPicture(key: row.key, reference: reference)
        }
        var result: [TranscriptRow] = []
        result.reserveCapacity(rows.count)
        var pending: [GalleryPicture] = []
        func flush() {
            guard let first = pending.first else { return }
            result.append(TranscriptRow(key: first.key, kind: .pictures(pending)))
            pending = []
        }
        for row in rows {
            if let one = picture(row) {
                pending.append(one)
            } else {
                flush()
                result.append(row)
            }
        }
        flush()
        return result
    }

    static func placeBoard(in rows: [TranscriptRow]) -> [TranscriptRow] {
        let calls = rows.compactMap { row -> ToolCall? in
            guard case .tool(let call) = row.kind, TaskBoard.isBoardCall(call.name) else {
                return nil
            }
            return call
        }
        let board = TaskBoard.fold(calls)
        guard !board.isEmpty, let anchor = calls.last?.id else { return rows }
        return rows.map { row in
            guard case .tool(let call) = row.kind, call.id == anchor else { return row }
            return TranscriptRow(key: Self.boardKey, kind: .taskBoard(board))
        }
    }

    /// One board, one identity.
    static let boardKey = "board"

    /// Compact mode: everything the agent did between two messages — the thoughts and the tool
    /// calls, failures included — folds to one line. Twelve greps, four edits and the thinking
    /// around them are one fact: "it worked". The run keeps every step inside it, one click away;
    /// only what is its own card (a subagent, a workflow, a picture) never joins a run, and a run
    /// with no tools stays its own thought rows so a lone reflection still reads as one.
    ///
    /// Every step keeps the key its own row had. Everything downstream reads a key as an identity —
    /// the diff anchors by it, the expansion is filed under it, the entrance remembers it — and a
    /// step's place inside a run is not one: a lone call becomes the second step of a run the moment
    /// another joins it, and the run re-splits whenever `placeBoard` lifts a board out of its
    /// middle. Keyed by where it sat, the reader's decision was thrown away by the arrival that
    /// reshaped the run, which reads exactly like the click never landing.
    ///
    /// The lone tool is emitted under the run's key for the same reason: it is the row that is about
    /// to become a run, so its identity stops changing at the moment the fan-out starts.
    static func fuse(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var fused: [TranscriptRow] = []
        var run: [ActivityStep] = []
        var runKey = ""

        func flush() {
            guard !run.isEmpty else { return }
            let tools = run.compactMap { step -> ToolCall? in
                if case .tool(_, let call) = step { return call }
                return nil
            }
            if tools.isEmpty {
                for step in run {
                    if case .reasoning(let key, let text) = step {
                        fused.append(TranscriptRow(key: key, kind: .reasoning(text)))
                    }
                }
            } else if tools.count == 1, run.count == 1 {
                fused.append(TranscriptRow(key: "run:\(runKey)", kind: .tool(tools[0])))
            } else {
                fused.append(TranscriptRow(key: "run:\(runKey)", kind: .run(run)))
            }
            run = []
        }

        for row in rows {
            switch row.kind {
            case .tool(let call):
                if run.isEmpty { runKey = row.key }
                run.append(.tool(key: row.key, call))
            case .reasoning(let text):
                if run.isEmpty { runKey = row.key }
                run.append(.reasoning(key: row.key, text))
            default:
                flush()
                fused.append(row)
            }
        }
        flush()
        return fused
    }
}
