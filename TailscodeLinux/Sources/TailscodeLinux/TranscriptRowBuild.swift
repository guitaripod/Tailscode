import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TranscriptRow {
    static func searchText(for call: ToolCall) -> String {
        let summary = call.summary
        return [
            call.name, summary.title, call.title, summary.detail, summary.command,
            summary.filePath, summary.displayOutput.map { String($0.prefix(4000)) },
        ].compactMap { $0 }.joined(separator: " ")
    }

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

    /// - Parameter cacheMarkup: whether the prose this message renders is worth remembering. The
    ///   message a turn is currently writing into is a different string on every arrival, so
    ///   remembering its markup fills the memo with a thousand prefixes of one answer and evicts
    ///   the settled segments the memo exists for.
    /// - Parameter sealed: whether this message's text is finished, decided by the caller because
    ///   only the caller can see the conversation (`MessageSegment.isSealed`). Nil falls back to
    ///   what the record says about itself, which is all a caller with no state has.
    /// - Parameter modelName: maps a note's model to the name this client already shows for it, so
    ///   `TranscriptNoteReading` can write the model's picked name rather than its bare id.
    static func rows(
        for message: ChatMessage, prompt: ChatMessage? = nil, cacheMarkup: Bool = true,
        sealed: Bool? = nil, modelName: (ModelSelection) -> String? = { _ in nil }
    ) -> [TranscriptRow] {
        let sealed = sealed ?? !message.isStreaming
        var rows: [TranscriptRow] = []
        var run = ProseRun()
        for part in message.parts {
            let key = "\(message.id):\(part.id)"
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
                        let palette = MatrixTheme.palette
                        for (offset, chunk) in PangoMarkdown.chunks(prose).enumerated() {
                            let chunkKey =
                                offset == 0 && !chunk.isList
                                ? "\(key):s\(index)"
                                : "\(key):s\(index).\(chunk.isList ? "l" : "p")\(offset)"
                            rows.append(
                                TranscriptRow(
                                    key: chunkKey,
                                    kind: .agentProse(
                                        text: chunk.text,
                                        markup: PangoMarkdown.render(
                                            chunk.text, dim: palette.textDim, code: palette.info,
                                            accent: palette.accent, cache: cacheMarkup))))
                            run.add(chunk.text, at: rows.count - 1)
                        }
                    case .code(let language, let body):
                        rows.append(
                            TranscriptRow(
                                key: "\(key):s\(index)",
                                kind: .codeBlock(language: language, body: body)))
                    case .table(let table):
                        let growing = TableDraft.isGrowing(
                            segment: index, of: segments.count, sealed: sealed)
                        rows.append(
                            TranscriptRow(
                                key: "\(key):s\(index)",
                                kind: growing
                                    ? .tableDraft(TableDraft(table)) : .table(table)))
                    }
                }
                continue
            case .unknown:
                continue
            default:
                break
            }
            run.close(into: &rows, messageID: message.id, followedByFurniture: true, open: !sealed)
            switch part.kind {
            case .reasoning(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                rows.append(TranscriptRow(key: key, kind: .reasoning(trimmed)))
            case .tool(let call):
                if call.asksUserQuestion, call.isAwaitingAnswer { continue }
                let kind: Kind
                if let sighting = DesignReading.sighting(of: call, in: message) {
                    kind = .designBoard(sighting)
                } else if call.summaryKind == .workflow {
                    kind = .workflow(call)
                } else {
                    kind = call.spawnsSubagent ? .subagent(call) : .tool(call)
                }
                rows.append(TranscriptRow(key: key, kind: kind))
            case .file(let reference):
                rows.append(
                    TranscriptRow(key: key, kind: .file(reference, mine: message.role == .user)))
            case .compaction(let compaction):
                rows.append(TranscriptRow(key: key, kind: .compaction(compaction)))
            case .note(let note):
                rows.append(
                    TranscriptRow(
                        key: key,
                        kind: .note(TranscriptNoteReading.read(note, modelName: modelName))))
            case .text, .unknown:
                continue
            }
        }
        run.close(into: &rows, messageID: message.id, followedByFurniture: false, open: !sealed)
        rows = groupAgents(in: rows, messageID: message.id)
        if let answerless = AnswerlessTurnReading.read(message, prompt: prompt) {
            rows.append(
                TranscriptRow(key: "\(message.id):answerless", kind: .answerless(answerless)))
        }
        if let failed = FailedTurnReading.read(message, prompt: prompt) {
            rows.append(TranscriptRow(key: "\(message.id):failed", kind: .failed(failed)))
        }
        if Preferences.responseStats, !rows.isEmpty,
            let stats = ResponseStats(turn: message, promptedAt: prompt?.createdAt)
        {
            rows.append(
                TranscriptRow(key: "\(message.id):stats", kind: .responseStats(stats)))
        }
        return rows
    }

    /// A turn that spawns a crowd of agents draws one row for the crowd. The rows stay where the
    /// first of them was, in the turn they belong to, and the cards are one open away.
    static func groupAgents(in rows: [TranscriptRow], messageID: String) -> [TranscriptRow] {
        let members = rows.compactMap { row -> AgentMember? in
            guard case .subagent(let call) = row.kind else { return nil }
            return AgentMember(key: row.key, call: call)
        }
        guard members.count > inlineAgentLimit else { return rows }
        var grouped: [TranscriptRow] = []
        var placed = false
        for row in rows {
            guard case .subagent = row.kind else {
                grouped.append(row)
                continue
            }
            guard !placed else { continue }
            placed = true
            grouped.append(
                TranscriptRow(key: "agents:\(messageID)", kind: .subagentGroup(members)))
        }
        return grouped
    }

    /// The consecutive prose of one message between two pieces of furniture, from which the rail
    /// under it is made. Code and tables inside the run do not end it — they are part of the same
    /// answer — and the rail docks under the run's last paragraph.
    struct ProseRun {
        private var texts: [String] = []
        private var lastProse = 0
        private var railCount = 0

        mutating func add(_ prose: String, at index: Int) {
            texts.append(prose)
            lastProse = index
        }

        /// Ends the run: when it has settled and mentioned any address, the rail goes in under its
        /// last paragraph. A run at the tail of a message still being written is not settled, and
        /// neither is anything in a message whose turn is open and whose last row is the live one.
        mutating func close(
            into rows: inout [TranscriptRow], messageID: String, followedByFurniture: Bool,
            open: Bool
        ) {
            defer { texts = [] }
            guard !texts.isEmpty else { return }
            let settled = LinkRailPolicy.isSettled(
                lastRowIsLive: open && !followedByFurniture,
                followedByFurniture: followedByFurniture, turnIsOpen: open)
            let urls = LinkRailPolicy.addresses(
                inRun: texts, enabled: Preferences.linkEmbeds, settled: settled)
            guard !urls.isEmpty else { return }
            rows.insert(
                TranscriptRow(
                    key: "\(messageID):rail\(railCount)", kind: .linkRail(urls: urls)),
                at: lastProse + 1)
            railCount += 1
        }
    }

    /// Rows for a whole transcript, with a hairline between turns so the reading rhythm survives
    /// density.
    static func rows(
        for messages: [ChatMessage], modelName: (ModelSelection) -> String? = { _ in nil }
    ) -> [TranscriptRow] {
        var all: [TranscriptRow] = []
        var prompt: ChatMessage?
        for message in messages {
            let rows = Self.rows(for: message, prompt: prompt, modelName: modelName)
            if message.role == .user { prompt = message }
            guard !rows.isEmpty else { continue }
            if message.role == .user, !all.isEmpty {
                all.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            all += rows
        }
        all = placeBoard(in: all)
        return gallery(Preferences.compactTools ? fuse(all) : all)
    }

    /// Consecutive pictures the agent made become one gallery. A picture that is the person's own
    /// stays where it is — it belongs to the prompt it was sent with — and so does anything that is
    /// not an image. The gallery is named after its first picture, so a picture arriving beside it
    /// changes the gallery's value and not its identity.
    static func gallery(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        func picture(_ row: TranscriptRow) -> GalleryPicture? {
            guard case .file(let reference, let mine) = row.kind, !mine,
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

    /// The agent's plan shows once: the last call that moved the to-do list becomes the board —
    /// the fold of every board call before it — and every earlier one stays the one-line tool row
    /// it was, so a long run reads as one plan updating rather than twenty snapshots.
    ///
    /// The row keeps one identity wherever it lands. Naming it after the call it is standing on
    /// re-identified the whole card every time the agent revised its plan: a delete and an insert
    /// where a person sees one card counting up, and on a keyed diff a move rather than a repaint.
    /// There is only ever one board in a transcript, so it can simply say so.
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
    /// around them are one fact: "it worked". The run keeps every step inside it, one tap away;
    /// only what is its own card (a subagent, a workflow, a picture) never joins a run, and a run
    /// with no tools stays its own thought rows so a lone reflection still reads as one.
    ///
    /// Those thought rows get one key each, suffixed by their position in the run the way a run's
    /// own body names its steps. A run's key is the key of the row that opened it, and handing that
    /// one key to every thought in a tool-less stretch made two rows the same row to everything
    /// downstream: the diff's anchor resolved to the first of them and tore the tail down on every
    /// arrival, only the first animated its entrance, and opening one thought opened all of them.
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
