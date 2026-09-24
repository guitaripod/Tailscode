import AppKit
import CodingAgentKit
import TailscodeCore

/// What a row needs from the transcript that is not in the row itself: which rows are open, the
/// pictures and subagent transcripts already fetched, and the callbacks that fetch more. Rows are
/// rebuilt freely; this survives them.
@MainActor
final class TranscriptContext {
    var expanded = TranscriptExpansion()
    /// Whether the turn these rows belong to is still open. A tool call the record still says is
    /// running only moves while it is; once the turn has ended the same record is a stale mark.
    var turnOpen = false
    /// The newest text of a thought that is still being written. A reasoning row's header counts
    /// its words, so it changes on every arrival — and rebuilding the row for that is a flicker.
    /// The row is updated in place instead, and a body opened afterwards reads the current text
    /// from here rather than the one its closure was built with.
    var liveReasoning: [String: String] = [:]
    var subagentRows: [String: [TranscriptRow]] = [:]
    /// Live facts for the agents of the running fan-out, keyed by spawning tool-use id — what an
    /// inline agent card shows for progress while its transcript is still being written.
    var agentFacts: [String: SubagentSummary] = [:]
    /// The moment those facts were read at. It belongs to the arrival rather than to the row: an
    /// agent's clock is a reading of one snapshot, so a card built between two polls states the
    /// time the facts it draws are from, and two cards in the same transcript can never disagree
    /// about what time it is.
    var agentReadAt: Date = Date()
    /// The workflow runs of this conversation, keyed by the Workflow call that started each. A run
    /// outlives its tool call by minutes, so the card reads its state from here rather than from a
    /// call that has said all it will say.
    var workflowRuns: [String: WorkflowRun] = [:]
    /// The clock the live parts of a workflow card are drawn against, moved by the ticker so every
    /// spinner and elapsed reading in one frame agrees.
    var workflowNow: Date = Date()
    var onToggle: ((String, Bool) -> Void)?
    /// Called with a just-opened disclosure row: the transcript scrolls the minimum needed to
    /// show the opened body, never past the point where the clicked header would leave the top.
    var revealRow: ((NSView) -> Void)?
    var requestImage: ((FileReference, String) -> Void)?
    var requestSubagent: ((ToolCall) -> Void)?
    /// A workflow agent is fetched by its own id: it has no spawning call to name it.
    var requestWorkflowAgent: ((String) -> Void)?
    var openImage: ((String, String) -> Void)?
    var presentText: ((_ title: String, _ subtitle: String?, _ body: String, _ mono: Bool) -> Void)?
    /// A short confirmation the window floats over everything — "Command copied".
    var toast: ((String) -> Void)?
    /// The words of a turn that said nothing, sent again — the transcript's own send, so the
    /// retry is a message like any other rather than a second road into the backend.
    var askAgain: ((String) -> Void)?
    /// A board of design alternatives, opened. The pane owns it because reading the mocks is the
    /// server's file route and building one is the pane's own send.
    var openDesign: ((DesignSource) -> Void)?
    /// What each board in this transcript turned out to be, so its card can name it rather than
    /// its folder. Filled by the pane the first time a card asks.
    var designBoards: [String: DesignManifest] = [:]
    var requestDesignBoard: ((String) -> Void)?
    /// A message still waiting behind the running turn, opened for rewriting. It is the one row in
    /// a transcript that has not happened yet, so it is the one row a press means something on.
    var editQueued: ((UUID) -> Void)?
    var pendingAct: ((UUID, PendingSend.Act) -> Void)?
    /// A message being held for a provider's window: sent into it now anyway, opened for
    /// rewriting, or let out of the wait.
    var resumeAct: ((UUID, ResumeReading.Act) -> Void)?
    /// A turn the server's machine cut off, picked back up or let go on that machine.
    var resumeInterrupted: (() -> Void)?
    var dismissInterrupted: (() -> Void)?
    /// Whether "Undo from here" belongs on this message's row: a live question, since the answer
    /// depends on the conversation's own capabilities and on whatever else this device is already
    /// winding back, both of which change while the row just sits there.
    var offersUndo: ((String) -> Bool)?
    /// The row asked to undo back to its own message; the confirmation and the request itself
    /// belong to the transcript, which is the one thing that knows the conversation well enough
    /// to ask and to carry the answer out.
    var confirmUndo: ((String) -> Void)?
    /// The standing revert's own Restore press.
    var restoreRevert: (() -> Void)?
    /// Names a model the way this device already names it elsewhere, for a note that mentions
    /// one. Nil leaves Core's own fallback, the model's bare id, standing.
    var modelName: (ModelSelection) -> String? = { _ in nil }

    /// A run reads as open when any step inside it is, so folding a step into a run carries the
    /// reader's decision in with it rather than collapsing it.
    func isExpanded(_ key: String) -> Bool { expanded.reads(key) }
}

extension TranscriptRow {
    /// Whether this row draws a call the record still says is running — the rows whose marks have
    /// to be redrawn the moment the turn ends, because nothing about their value changes when it
    /// does.
    var hasOpenWork: Bool {
        switch kind {
        case .tool(let call), .subagent(let call), .workflow(let call):
            return call.status == .running
        case .run(let steps):
            return steps.contains {
                if case .tool(_, let call) = $0 { return call.status == .running }
                return false
            }
        default:
            return false
        }
    }
}

/// Folds messages into rows with a per-message memo: a streamed token changes one message, so
/// re-deriving the other two hundred and ninety-nine — markdown and all — on every state would be
/// the seconds-long pause between "Loading…" and the transcript. Only messages whose value
/// actually changed are re-folded.
@MainActor
final class TranscriptRowBuilder {
    private var cache:
        [String: (message: ChatMessage, promptID: String?, sealed: Bool, rows: [TranscriptRow])] =
            [:]

    /// Forgets every memoised row — the rendering baked into them (fonts, markdown) is stale
    /// after a type-scale change.
    func invalidate() {
        cache = [:]
    }

    /// A turn that said nothing is read against the question it answers, so the prompt walks along
    /// with the fold and is part of what a memoised row was folded from: the same assistant message
    /// under a different question is a different card, and reusing the earlier one would offer the
    /// wrong words to send again.
    func rows(for messages: [ChatMessage], turnOpen: Bool = false) -> [TranscriptRow] {
        var all: [TranscriptRow] = []
        var next: [String: (message: ChatMessage, promptID: String?, sealed: Bool, rows: [TranscriptRow])] = [:]
        next.reserveCapacity(messages.count)
        let writing = messages.last?.id
        var prompt: ChatMessage?
        for message in messages {
            let rows: [TranscriptRow]
            let sealed = MessageSegment.isSealed(
                streaming: message.isStreaming, isNewest: message.id == writing, turnOpen: turnOpen)
            if let hit = cache[message.id], hit.message == message, hit.promptID == prompt?.id,
                hit.sealed == sealed
            {
                rows = hit.rows
            } else {
                rows = TranscriptRow.rows(for: message, prompt: prompt, sealed: sealed)
            }
            next[message.id] = (message, prompt?.id, sealed, rows)
            if message.role == .user { prompt = message }
            guard !rows.isEmpty else { continue }
            if message.role == .user, !all.isEmpty {
                all.append(TranscriptRow(key: "break:\(message.id)", kind: .turnBreak))
            }
            all += rows
        }
        cache = next
        all = TranscriptRow.placeBoard(in: all)
        return TranscriptRow.compactTools ? TranscriptRow.fuse(all) : all
    }
}

/// One agent action in the order it happened — a thought or a tool call — folded together into a
/// run row the same way the iOS app groups them, so the three clients read the middle of a turn
/// alike.
enum ActivityStep: Hashable {
    case reasoning(key: String, String)
    case tool(key: String, ToolCall)

    /// The row's own durable key, carried in rather than re-derived from where the step ended up.
    /// A step's position inside a run moves whenever the run is re-split, and a key that moves is
    /// a reader's expansion thrown away.
    var key: String {
        switch self {
        case .reasoning(let key, _), .tool(let key, _): return key
        }
    }
}

/// One line of the transcript, in the CLIs' grammar: the prompt behind an accent rule, the
/// agent's answer as prose at full measure, code as blocks that copy byte-exactly, edits as
/// diffs, reasoning and tool output behind a disclosure, a compaction as a seam, a picture as
/// the picture. No bubbles — the material lives in the chrome around this.
struct TranscriptRow: Hashable {
    enum Kind: Hashable {
        case userText(String, messageID: String)
        case interruption
        /// The rendering rides in the row, computed where the rows are computed, so painting a
        /// prose row is a label set, not a markdown parse.
        case agentProse(text: String, rendered: NSAttributedString)
        case codeBlock(language: String?, body: String)
        case table(MarkdownTable)
        /// A table still being written: its card, its count, and none of its rows measured.
        case tableDraft(TableDraft)
        case reasoning(String)
        case tool(ToolCall)
        case run([ActivityStep])
        case subagent(ToolCall)
        case workflow(ToolCall)
        case file(FileReference, mine: Bool, messageID: String)
        /// A board of design alternatives the agent wrote, standing where the manifest that made
        /// it was written rather than as a line about a file.
        case designBoard(DesignSighting)
        case taskBoard(TaskBoard)
        case compaction(Compaction)
        case answerless(AnswerlessTurn)
        /// What the answer above it took, drawn only where the reader asked for it.
        case responseStats(ResponseStats)
        /// Written, not sent: a prompt waiting behind the turn that is running.
        case queuedSend(QueuedSend, position: Int, of: Int)
        case pendingSend(PendingSend, ResumePlan?, now: Date)
        /// Not `interruption`, which is the escape key: this is the machine stopping mid-answer.
        case interruptedTurn(InterruptedTurn)
        /// A line the server wrote for the reader rather than for the model: the model or the
        /// agent changing hands, a restart picking a turn back up, work it left running reporting
        /// back. Read into words only where it is drawn, so a client with no catalog yet still
        /// shows Core's own fallback rather than a value baked in too early.
        case note(TranscriptNote)
        /// The turn is waiting on its provider between attempts.
        case providerRetry(ProviderRetryCard)
        /// The conversation wound back to one of the reader's own messages, with the way back
        /// still open. `restoring` is this device's own press on Restore, in flight.
        case revertBanner(RevertBanner, restoring: Bool)
        /// An undo this device asked for, standing where the banner will land once the server
        /// answers.
        case revertPending
        case turnBreak
    }

    let key: String
    let kind: Kind

    /// Whether this row is part of what the person sent — the words, or a picture clipped to
    /// them — which is the block that rises to the top when a prompt goes.
    var isPromptBlock: Bool {
        switch kind {
        case .userText, .pendingSend: return true
        case .file(_, let mine, _): return mine
        default: return false
        }
    }

    /// The same switch every desktop reads: an environment override for screenshots and headless
    /// runs, then the shared `tailscode.*` default. On by default, like the iOS app, so a turn
    /// reads as ask → answer until opened.
    static var compactTools: Bool {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_COMPACT"] { return raw == "1" }
        if UserDefaults.standard.object(forKey: "tailscode.compactTools") == nil { return true }
        return UserDefaults.standard.bool(forKey: "tailscode.compactTools")
    }

    /// A Workflow call is its run, not a tool line; everything else that spawns work is an agent.
    static func kind(for call: ToolCall) -> Kind {
        if call.summaryKind == .workflow { return .workflow(call) }
        return call.spawnsSubagent ? .subagent(call) : .tool(call)
    }

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

    @MainActor
    /// - Parameter sealed: whether this message's text is finished, decided by the caller because
    ///   only the caller can see the conversation (`MessageSegment.isSealed`). Nil falls back to
    ///   what the record says about itself, which is all a caller with no state has.
    static func rows(
        for message: ChatMessage, prompt: ChatMessage? = nil, sealed: Bool? = nil
    ) -> [TranscriptRow] {
        let sealed = sealed ?? !message.isStreaming
        var rows: [TranscriptRow] = []
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
                        rows.append(
                            TranscriptRow(
                                key: "\(key):s\(index)",
                                kind: .agentProse(
                                    text: prose, rendered: MacMarkdown.render(prose))))
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
        if let answerless = AnswerlessTurnReading.read(message, prompt: prompt) {
            rows.append(
                TranscriptRow(key: "\(message.id):answerless", kind: .answerless(answerless)))
        }
        if ResponseStatsSetting.isEnabled, !rows.isEmpty,
            let stats = ResponseStats(turn: message, promptedAt: prompt?.createdAt)
        {
            rows.append(TranscriptRow(key: "\(message.id):stats", kind: .responseStats(stats)))
        }
        return rows
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
        all = placeBoard(in: all)
        return compactTools ? fuse(all) : all
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

    /// What in-conversation search reads for this row: the words a person saw, not widget state.
    var searchText: String {
        switch kind {
        case .userText(let text, _), .reasoning(let text):
            return text
        case .agentProse(let text, _):
            return text
        case .codeBlock(let language, let body):
            return "\(language ?? "") \(body)"
        case .table(let table):
            return (table.header + table.rows.flatMap { $0 }).joined(separator: " ")
        case .tableDraft(let draft):
            return draft.reading
        case .tool(let call), .subagent(let call), .workflow(let call):
            return Self.searchText(for: call)
        case .run(let steps):
            return steps.map { step -> String in
                switch step {
                case .reasoning(_, let text): return text
                case .tool(_, let call): return Self.searchText(for: call)
                }
            }.joined(separator: " ")
        case .file(let reference, _, _):
            return reference.filename ?? reference.path ?? ""
        case .taskBoard(let board):
            return board.items.map(\.subject).joined(separator: " ")
        case .compaction(let compaction):
            return compaction.summary ?? ""
        case .designBoard(let sighting):
            let reading = DesignCardReading.make(sighting: sighting, board: nil)
            return "\(reading.title) \(reading.detail)"
        case .answerless(let turn):
            return "\(turn.title) \(turn.detail)"
        case .responseStats(let stats):
            return stats.spoken
        case .queuedSend(let send, _, _):
            return SendQueueReading.rowTitle(send)
        case .pendingSend(let send, let plan, let now):
            guard let plan else { return PendingSendReading.spoken(send, now: now) }
            return ResumeReading.spoken(plan, words: send.text, now: now)
        case .interruptedTurn(let turn):
            return "\(turn.title) \(turn.prompt)"
        case .note(let note):
            return TranscriptNoteReading.read(note).text
        case .providerRetry(let card):
            return card.spoken
        case .revertBanner(let banner, _):
            return banner.spoken
        case .revertPending:
            return RevertReading.undoingTitle
        case .interruption:
            return "interrupted"
        case .turnBreak:
            return ""
        }
    }

    @MainActor
    func makeView(context: TranscriptContext) -> NSView {
        switch kind {
        case .userText(let text, let messageID):
            return Self.prompt(text, messageID: messageID, context: context)
        case .interruption:
            return RowKit.label(
                "⌧ " + Localized.text("interrupted"), font: MacTheme.Ramp.font(.interruption),
                color: MacTheme.Color.tertiaryLabel)
        case .agentProse(_, let rendered):
            return RowKit.attributedLabel(rendered)
        case .codeBlock(let language, let body):
            return Self.codeBlock(language: language, body: body, key: key, context: context)
        case .table(let table):
            return Self.table(table, key: key)
        case .tableDraft(let draft):
            return MacTableDraftView(draft, key: key)
        case .reasoning(let text):
            return ToolRowView.reasoning(text, key: key, context: context)
        case .tool(let call):
            return ToolRowView.make(call, key: key, context: context)
        case .run(let steps):
            return ToolRowView.makeRun(steps, key: key, context: context)
        case .workflow(let call):
            return WorkflowCardView.make(call, key: key, context: context)
        case .subagent(let call):
            return SubagentRowView.make(call, key: key, context: context)
        case .file(let reference, let mine, let messageID):
            let view = ImageRowView.make(reference, mine: mine, key: key, context: context)
            guard mine else { return view }
            return Self.wrappedForUndo(view, messageID: messageID, context: context)
        case .designBoard(let sighting):
            return Self.designBoard(sighting, context: context)
        case .taskBoard(let board):
            return TaskBoardView.make(board)
        case .compaction(let compaction):
            return Self.seam(compaction, key: key, context: context)
        case .answerless(let turn):
            return Self.answerless(turn, context: context)
        case .responseStats(let stats):
            return Self.responseStats(stats)
        case .queuedSend(let send, let position, let total):
            return Self.queuedSend(send, position: position, of: total, context: context)
        case .pendingSend(let send, let plan, let now):
            return Self.pendingSend(send, plan: plan, now: now, context: context)
        case .interruptedTurn(let turn):
            return Self.interruptedTurn(turn, context: context)
        case .note(let note):
            return Self.noteLine(TranscriptNoteReading.read(note, modelName: context.modelName))
        case .providerRetry(let card):
            return Self.providerRetry(card)
        case .revertBanner(let banner, let restoring):
            return Self.revertBanner(banner, restoring: restoring, context: context)
        case .revertPending:
            return Self.revertPending()
        case .turnBreak:
            return RowKit.hairline(verticalPadding: MacTheme.Spacing.m)
        }
    }

    @MainActor
    private static func prompt(_ text: String, messageID: String, context: TranscriptContext)
        -> NSView
    {
        let rule = RowKit.Ground(frame: .zero)
        rule.fill = MacTheme.Color.accent

        let label = RowKit.attributedLabel(
            MacMarkdown.plainWithLinks(
                text, font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.label))
        let row = PromptRow(messageID: messageID, text: text, context: context)
        row.addSubview(rule)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            rule.topAnchor.constraint(equalTo: row.topAnchor),
            rule.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 2),
            label.leadingAnchor.constraint(
                equalTo: rule.trailingAnchor, constant: MacTheme.Spacing.s + 2),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    /// A row that is not itself built as a ``PromptRow`` still gets "Undo from here" when it is
    /// part of what the reader sent. A picture with no words beside it is a message like any
    /// other, and the only thing it lacks is somewhere to put the menu.
    @MainActor
    private static func wrappedForUndo(_ view: NSView, messageID: String, context: TranscriptContext)
        -> NSView
    {
        let row = PromptRow(messageID: messageID, text: nil, context: context)
        view.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            view.topAnchor.constraint(equalTo: row.topAnchor),
            view.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    /// Markdown as the transcript renders it — headings, emphasis, lists, links, fenced code with
    /// its own copy — for prose that lives outside the transcript: a compaction summary in the
    /// reader, where the CLI's own formatting is the only structure the text has.
    @MainActor
    static func richBody(_ text: String, context: TranscriptContext?, key: String = "rich") -> NSView {
        let column = FillingStack()
        column.spacing = MacTheme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        for (index, segment) in MessageSegment.split(text).enumerated() {
            switch segment {
            case .prose(let prose):
                for chunk in paragraphChunks(prose) {
                    column.addArrangedSubview(RowKit.attributedLabel(MacMarkdown.render(chunk)))
                }
            case .code(let language, let body):
                column.addArrangedSubview(
                    codeBlock(language: language, body: body, key: "\(key):s\(index)", context: context))
            case .table(let table):
                column.addArrangedSubview(Self.table(table, key: "\(key):s\(index)"))
            }
        }
        return column
    }

    /// A pipe table, drawn by `MacTableView` — a card with a header band and washed rows, fitted
    /// to the pane it is in.
    @MainActor
    static func table(_ table: MarkdownTable, key: String) -> NSView {
        MacTableView(table, key: key)
    }

    /// Bounded labels: one layout pass over forty thousand words takes a visible pause to
    /// measure, so prose breaks at blank lines into pieces each small enough to lay out in a
    /// frame, and the reading is unchanged.
    static func paragraphChunks(_ prose: String, limit: Int = 3000) -> [String] {
        guard prose.count > limit else { return [prose] }
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for paragraph in prose.components(separatedBy: "\n\n") {
            if size > 0, size + paragraph.count > limit {
                chunks.append(current.joined(separator: "\n\n"))
                current = []
                size = 0
            }
            current.append(paragraph)
            size += paragraph.count + 2
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
        return chunks
    }

    /// A fenced block: the language and a copy in the header, a gutter of line numbers, the code
    /// scrolling sideways and never down, and under a long one a button naming the lines behind
    /// it. Opening grows the block in the page, so the transcript's own scroll carries it.
    @MainActor
    private static func codeBlock(
        language: String?, body: String, key: String, context: TranscriptContext?
    ) -> NSView {
        let column = FillingStack()
        column.spacing = MacTheme.Spacing.xs
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.s)
        column.translatesAutoresizingMaskIntoConstraints = false
        RowKit.ground(
            behind: column, fill: MacTheme.Color.canvasRaised, radius: MacTheme.Radius.control)

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = MacTheme.Spacing.s
        let tag = RowKit.label(
            SyntaxHighlighter.displayName(for: language, source: body),
            font: MacTheme.Ramp.font(.codeLabel),
            color: MacTheme.Color.tertiaryLabel)
        header.addArrangedSubview(tag)
        header.addArrangedSubview(RowKit.spacer())
        header.addArrangedSubview(RowKit.copyButton(body, toast: context?.toast))
        column.addArrangedSubview(header)

        let foldKey = "\(key)#code"
        var opened = context?.isExpanded(foldKey) ?? false
        var lines = RowKit.codeLines(body, language: language, expanded: opened)
        column.addArrangedSubview(lines)

        guard let title = TranscriptBlocks.fold(body, expanded: opened).toggleLabel else {
            return column
        }
        let onToggle = context?.onToggle
        let host = RowKit.Weak(column)
        let button = RowKit.Weak<NSButton>(nil)
        let toggle = RowKit.linkButton(title) {
            opened.toggle()
            onToggle?(foldKey, opened)
            guard let column = host.value else { return }
            let fresh = RowKit.codeLines(body, language: language, expanded: opened)
            column.removeArrangedSubview(lines)
            lines.removeFromSuperview()
            column.insertArrangedSubview(fresh, at: 1)
            lines = fresh
            button.value?.title = TranscriptBlocks.fold(body, expanded: opened).toggleLabel ?? ""
        }
        button.value = toggle
        toggle.font = MacTheme.Ramp.font(.codeAction)
        column.addArrangedSubview(toggle)
        return column
    }

    /// A compaction is a seam, not a message: the rule says the transcript restarted here, and
    /// the card says what was traded for what — the trade in tokens, the sliver of context the
    /// summary still occupies drawn as a bar, and what carried over. The CLI's machine-facing
    /// summary — tens of thousands of words — opens in a reader window rather than cramped into
    /// the flow.
    @MainActor
    private static func seam(
        _ compaction: Compaction, key: String, context: TranscriptContext
    ) -> NSView {
        let story = CompactionStory.done(compaction)
        let column = FillingStack()
        column.spacing = MacTheme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(RowKit.hairline())

        let card = RowKit.compactionCard(story, tint: MacTheme.Color.accent)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("\(story.title). \(story.detail)")

        if let kept = story.keptFraction {
            let track = RowKit.Ground(frame: .zero)
            track.fill = MacTheme.Color.separator
            track.radius = 2
            let fill = RowKit.Ground(frame: .zero)
            fill.fill = MacTheme.Color.accent
            fill.radius = 2
            track.addSubview(fill)
            NSLayoutConstraint.activate([
                track.heightAnchor.constraint(equalToConstant: 4),
                fill.topAnchor.constraint(equalTo: track.topAnchor),
                fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                fill.widthAnchor.constraint(
                    equalTo: track.widthAnchor, multiplier: CGFloat(kept)),
            ])
            card.addArrangedSubview(track)
            track.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -2 * MacTheme.Spacing.m)
                .isActive = true
        }

        if let footnote = story.footnote {
            card.addArrangedSubview(
                RowKit.wrapping(
                    footnote, font: MacTheme.Ramp.font(.seamFootnote),
                    color: MacTheme.Color.tertiaryLabel))
        }

        if let summary = story.summary, story.isReadable {
            let present = context.presentText
            let header = CompactionStory.summaryHeader(compaction)
            card.addArrangedSubview(
                RowKit.linkButton(Localized.text("Read the summary")) {
                    present?(Localized.text("Compaction summary"), header, summary, false)
                })
        }

        column.addArrangedSubview(card)
        column.addArrangedSubview(RowKit.hairline())
        return column
    }

    /// A prompt that has been written and not sent, drawn as the prompt it will become — same
    /// words, same place — but dimmed, marked, and pressable, because it is the one row in the
    /// transcript that is still the reader's to change. Nothing about it may read as sent.
    @MainActor
    private static func queuedSend(
        _ send: QueuedSend, position: Int, of total: Int, context: TranscriptContext
    ) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(
            RowKit.wrapping(
                "\(SendQueueReading.glyph) \(SendQueueReading.rowTitle(send))",
                font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.secondaryLabel))
        column.addArrangedSubview(
            RowKit.label(
                SendQueueReading.hint, font: MacTheme.Ramp.font(.hint),
                color: MacTheme.Color.tertiaryLabel))
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.group)
        column.setAccessibilityLabel(SendQueueReading.spoken(send, position: position, of: total))
        column.toolTip = SendQueueReading.hint
        guard !send.isCommand, let edit = context.editQueued else { return column }
        let id = send.id
        column.addGestureRecognizer(RowKit.PressGesture { edit(id) })
        return column
    }

    /// A message on its way out: the words drawn as the prompt they will become, told by ink
    /// rather than by a word — see `PendingSendRowView`, which is kept and restated across phases
    /// so the bubble fills in rather than being rebuilt.
    @MainActor
    private static func pendingSend(
        _ send: PendingSend, plan: ResumePlan?, now: Date, context: TranscriptContext
    ) -> NSView {
        PendingSendRowView(send: send, plan: plan, now: now, context: context)
    }

    /// What the answer above it took: one quiet strip of symbol-and-number, each figure carrying
    /// the sentence behind it as a tooltip. It is deliberately the dimmest thing in the transcript
    /// — a reader who turned it on wants the numbers available, not competing with the answer they
    /// describe — and it holds perfectly still, like every settled state in this app.
    @MainActor
    private static func responseStats(_ stats: ResponseStats) -> NSView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.alignment = .firstBaseline
        strip.spacing = MacTheme.Spacing.m
        strip.translatesAutoresizingMaskIntoConstraints = false
        for fact in stats.facts {
            let cell = NSStackView()
            cell.orientation = .horizontal
            cell.alignment = .firstBaseline
            cell.spacing = 3
            if let symbol = NSImage(
                systemSymbolName: fact.symbol, accessibilityDescription: fact.label)
            {
                let icon = NSImageView(image: symbol)
                icon.contentTintColor = MacTheme.Color.tertiaryLabel
                icon.symbolConfiguration = NSImage.SymbolConfiguration(
                    pointSize: MacTheme.Ramp.font(.responseStat).pointSize, weight: .regular)
                cell.addArrangedSubview(icon)
            }
            cell.addArrangedSubview(
                RowKit.label(
                    fact.value, font: MacTheme.Ramp.font(.responseStat),
                    color: MacTheme.Color.tertiaryLabel))
            cell.toolTip = "\(fact.label) — \(fact.detail)"
            strip.addArrangedSubview(cell)
        }
        strip.setAccessibilityElement(true)
        strip.setAccessibilityRole(.group)
        strip.setAccessibilityLabel(stats.spoken)
        return strip
    }

    /// A board of alternatives, offered rather than described. The letters are on the card
    /// because they are what the reader picks by, and the card is the way in — a design reachable
    /// only through a file path is a design nobody looks at.
    @MainActor
    private static func designBoard(_ sighting: DesignSighting, context: TranscriptContext) -> NSView
    {
        var board: DesignBoard?
        if case .board(let directory) = sighting.source {
            if let manifest = context.designBoards[directory] {
                board = DesignBoard(directory: directory, manifest: manifest)
            } else {
                context.requestDesignBoard?(directory)
            }
        }
        let reading = DesignCardReading.make(sighting: sighting, board: board)
        let card = RowKit.card(
            symbol: reading.symbol, title: reading.title, detail: reading.detail,
            tint: MacTheme.Color.info)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("\(reading.title). \(reading.detail)")
        if !reading.letters.isEmpty {
            let strip = NSStackView()
            strip.orientation = .horizontal
            strip.spacing = MacTheme.Spacing.xs
            for letter in reading.letters {
                strip.addArrangedSubview(
                    RowKit.label(
                        letter, font: MacTheme.Ramp.font(.badge), color: MacTheme.Color.accent))
            }
            card.addArrangedSubview(strip)
        }
        let open = context.openDesign
        let source = sighting.source
        card.addArrangedSubview(RowKit.linkButton(reading.action) { open?(source) })
        return card
    }

    /// A turn that finished having said nothing. It is a card rather than a prose row because
    /// there is no prose — the transcript would otherwise show the question and then simply the
    /// next thing, with the whole turn missing.
    @MainActor
    private static func answerless(_ turn: AnswerlessTurn, context: TranscriptContext) -> NSView {
        let card = RowKit.card(
            symbol: AnswerlessTurn.symbol, title: turn.title, detail: turn.detail,
            tint: AnswerlessTurn.tone.color)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(turn.spoken)
        guard turn.offersRemedy else { return card }
        let askAgain = context.askAgain
        let words = turn.prompt
        card.addArrangedSubview(RowKit.linkButton(turn.action) { askAgain?(words) })
        return card
    }

    /// A turn the machine was pulled out from under. The account of what the work had already done
    /// is the substance of it — a person decides between continuing and starting over on whether
    /// anything on that machine changed — so it is drawn as lines rather than as a sentence.
    ///
    /// Every word on it is Core's, including the one nobody was being told: while the card stands
    /// undecided the server will not carry this session on by itself, so a card left alone quietly
    /// turns unattended continuation off for the whole conversation.
    @MainActor
    private static func interruptedTurn(_ turn: InterruptedTurn, context: TranscriptContext)
        -> NSView
    {
        let card = RowKit.card(
            symbol: InterruptedTurn.symbol, title: turn.title, detail: turn.detail,
            tint: InterruptedTurn.tone.color)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(turn.spoken)
        if !turn.prompt.isEmpty {
            card.insertArrangedSubview(
                RowKit.wrapping(
                    turn.prompt, font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.label),
                at: 1)
        }
        for line in turn.progress {
            card.addArrangedSubview(
                RowKit.wrapping(
                    "· \(line)", font: MacTheme.Ramp.font(.rowNote),
                    color: MacTheme.Color.secondaryLabel))
        }
        if let queued = turn.queuedLine {
            card.addArrangedSubview(
                RowKit.wrapping(
                    queued, font: MacTheme.Ramp.font(.rowNote),
                    color: MacTheme.Color.secondaryLabel))
        }
        if let cost = turn.cost {
            card.addArrangedSubview(
                RowKit.wrapping(
                    cost, font: MacTheme.Ramp.font(.rowNote), color: InterruptedTurn.tone.color))
        }
        if let buttons = interruptedActions(turn, context: context) {
            card.addArrangedSubview(buttons)
        }
        return card
    }

    /// The two things a cut-off turn offers, or nothing at all once the server has picked it back
    /// up — the work is going again there, so "let it go" would mean forgetting the record rather
    /// than stopping anything, and a button that cannot do what its words say is worse than no
    /// button.
    ///
    /// A press already in flight keeps both, wearing Core's in-flight wording and refusing a second
    /// press, because seeing what was asked for is the whole point of acknowledging it — a button
    /// that vanished under the pointer is a press nobody can tell landed.
    @MainActor
    private static func interruptedActions(_ turn: InterruptedTurn, context: TranscriptContext)
        -> NSStackView?
    {
        guard !turn.isResumed else { return nil }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.m
        if let resume = context.resumeInterrupted {
            buttons.addArrangedSubview(
                RowKit.linkButton(turn.resumeTitle, enabled: turn.acceptsPress) { resume() })
        }
        if let dismiss = context.dismissInterrupted {
            buttons.addArrangedSubview(
                RowKit.linkButton(turn.dismissTitle, enabled: turn.acceptsPress) { dismiss() })
        }
        return buttons.arrangedSubviews.isEmpty ? nil : buttons
    }

    /// A line the server wrote for the reader: small, tinted by its tone, holding perfectly still.
    /// Never a bubble and never a card, because a note is a fact about the conversation rather
    /// than something anybody said.
    @MainActor
    private static func noteLine(_ line: TranscriptNoteLine) -> NSView {
        Self.quietLine(symbol: line.symbol, text: line.text, tone: line.tone, spoken: line.spoken)
    }

    /// The placeholder an undo wears from the press until the server answers, standing exactly
    /// where the banner will land so the person sees the same slot fill in rather than a card
    /// appearing out of nowhere once the request finally lands.
    @MainActor
    private static func revertPending() -> NSView {
        Self.quietLine(
            symbol: RevertBanner.symbol, text: RevertReading.undoingTitle, tone: RevertBanner.tone,
            spoken: RevertReading.undoingTitle)
    }

    /// The one small shape a quiet, still line across the transcript is built from: a note, and
    /// the placeholder an undo wears while it is in flight.
    @MainActor
    private static func quietLine(symbol: String, text: String, tone: ActivityTone, spoken: String)
        -> NSView
    {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 11 * MacTheme.UIScale.factor, weight: .medium))
        icon.contentTintColor = tone.color
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)
        let label = RowKit.wrapping(text, font: MacTheme.Ramp.font(.note), color: tone.color)
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel(spoken)
        return row
    }

    /// The card docked while the turn waits on its provider: the reason it gave, the attempt line
    /// that carries the countdown in tabular figures so it never jitters, and the remedy it named,
    /// where it named one. No other action belongs here: stopping the turn stays where it is.
    @MainActor
    private static func providerRetry(_ card: ProviderRetryCard) -> NSView {
        let view = RowKit.card(
            symbol: ProviderRetryCard.symbol, title: card.title, detail: card.reason,
            tint: ProviderRetryCard.tone.color)
        view.addArrangedSubview(
            RowKit.label(
                card.attemptLine, font: MacTheme.Ramp.font(.rowStamp),
                color: ProviderRetryCard.tone.color))
        if let remedy = card.remedy {
            view.addArrangedSubview(
                RowKit.label(
                    remedy.title, font: MacTheme.Ramp.font(.rowTitleStrong),
                    color: MacTheme.Color.label))
            view.addArrangedSubview(
                RowKit.wrapping(
                    remedy.message, font: MacTheme.Ramp.font(.cardBody),
                    color: MacTheme.Color.secondaryLabel))
            if let link = remedy.link {
                view.addArrangedSubview(RowKit.linkButton(remedy.label) { NSWorkspace.shared.open(link) })
            }
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(card.spoken)
        return view
    }

    /// How many set-aside files a revert banner names before it pages the rest: enough that most
    /// reverts show every file, narrow enough that the card never grows past the turn it stands in
    /// for.
    private static let revertFileLimit = 6

    /// The banner where the set-aside messages were: how many were wound back, which files came
    /// back and how, and Restore one press away for as long as the revert stands.
    @MainActor
    private static func revertBanner(
        _ banner: RevertBanner, restoring: Bool, context: TranscriptContext
    ) -> NSView {
        let card = RowKit.card(
            symbol: RevertBanner.symbol, title: banner.title, detail: banner.detail,
            tint: RevertBanner.tone.color)
        let paged = banner.files(upTo: Self.revertFileLimit)
        for file in paged.shown {
            card.addArrangedSubview(Self.revertFileRow(file))
        }
        if let more = paged.more {
            card.addArrangedSubview(
                RowKit.label(more, font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.tertiaryLabel))
        }
        if let restore = context.restoreRevert {
            card.addArrangedSubview(
                RowKit.linkButton(
                    restoring ? RevertReading.restoringTitle : banner.restoreTitle,
                    enabled: !restoring, action: restore))
        }
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(banner.spoken)
        return card
    }

    /// One file a revert put back: its path, what happened to it, and by how much. These are the
    /// same three facts `GitPanelView` draws for a changed file, because a revert's files are
    /// exactly that.
    @MainActor
    private static func revertFileRow(_ file: RevertBanner.FileLine) -> NSView {
        let path = RowKit.label(
            file.path, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let change = RowKit.label(
            file.change, font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.secondaryLabel)
        change.setContentHuggingPriority(.required, for: .horizontal)
        var views = [path, change]
        if let counts = file.counts {
            let countsLabel = RowKit.label(
                counts, font: MacTheme.Ramp.font(.rowStamp), color: MacTheme.Color.tertiaryLabel)
            countsLabel.setContentHuggingPriority(.required, for: .horizontal)
            views.append(countsLabel)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        return row
    }
}

/// The small vocabulary every row view speaks: labels that wrap, labels that truncate, hairlines,
/// flat little buttons, capped scrolls — one place, so the rows stay about their content.
@MainActor
enum RowKit {
    /// The shell every compaction card shares: the raised box, the symbol wearing the story's
    /// tone, the bold title and the detail line. Callers append what their state adds — a bar, a
    /// ticking clock, a reader link.
    static func compactionCard(_ story: CompactionStory, tint: NSColor) -> NSStackView {
        card(symbol: story.symbol, title: story.title, detail: story.detail, tint: tint)
    }

    /// The shape every stated-outcome card in the transcript wears: a symbol in its tint, the
    /// fact, and the sentence under it.
    static func card(symbol: String, title: String, detail: String, tint: NSColor) -> NSStackView {
        let card = FillingStack(topDown: false, stretches: false)
        card.spacing = MacTheme.Spacing.s
        card.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        card.translatesAutoresizingMaskIntoConstraints = false
        ground(
            behind: card, fill: MacTheme.Color.subagentBackground,
            stroke: MacTheme.Color.separator, radius: MacTheme.Radius.card)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 13 * MacTheme.UIScale.factor, weight: .semibold))
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)
        let heading = label(title, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [icon, heading])
        header.orientation = .horizontal
        header.spacing = MacTheme.Spacing.s
        card.addArrangedSubview(header)
        card.addArrangedSubview(
            wrapping(
                detail, font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.secondaryLabel))
        return card
    }

    /// A one-line label truncates rather than holds the window open. Left at AppKit's 750 its
    /// whole line is a width the window has to make room for — a prompt quoted in full is tens of
    /// thousands of points, and the window grew to fit it — so it resists just below the priority
    /// a window keeps its size at, which still ranks it over every label a caller lowered on
    /// purpose.
    static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(MacTheme.Layout.belowWindowSize, for: .horizontal)
        return label
    }

    static func wrapping(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func attributedLabel(_ text: NSAttributedString) -> NSTextField {
        let label = ProseLabel(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// The label prose is set in.
    ///
    /// Its links behave the way links do in any Mac text, whichever backend the chat is on: a hand
    /// over one, a click that opens it when released, and a right-click that offers to open or
    /// copy it — rather than depending on the text field's editor having taken the press, and on
    /// the one message menu that offered link items existing only where a chat can be wound back.
    /// And it can be repainted without being measured again, which is what the wave
    /// does to the answer being written on every frame — the words and their fonts are the ones
    /// already measured and only their colours move, but a text field told its value changed asks
    /// for its size again, and the whole transcript's layout ran at the display's rate.
    final class ProseLabel: NSTextField {
        /// Set while a repaint changes colours and nothing else.
        var holdsMeasure = false
        private var linkFrames: (width: CGFloat, links: [(rect: NSRect, target: URL?)])?
        /// The link a press landed on, opened only if the release lands on it too, so a press
        /// dragged away is taken back.
        private var pressedLink: URL?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var attributedStringValue: NSAttributedString {
            didSet { linkFrames = nil }
        }

        override func invalidateIntrinsicContentSize() {
            guard !holdsMeasure else { return }
            super.invalidateIntrinsicContentSize()
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            for link in links() { addCursorRect(link.rect, cursor: .pointingHand) }
        }

        /// The link drawn under a point in this label's own coordinates, if there is one.
        func link(at point: NSPoint) -> URL? {
            links().first { $0.rect.contains(point) }?.target
        }

        override func mouseDown(with event: NSEvent) {
            let target = link(at: convert(event.locationInWindow, from: nil))
            guard event.clickCount == 1, !event.modifierFlags.contains(.control), let target else {
                pressedLink = nil
                return super.mouseDown(with: event)
            }
            pressedLink = target
        }

        override func mouseUp(with event: NSEvent) {
            guard let pressed = pressedLink else { return super.mouseUp(with: event) }
            pressedLink = nil
            guard link(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
            NSWorkspace.shared.open(pressed)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let target = link(at: convert(event.locationInWindow, from: nil)) else {
                return super.menu(for: event)
            }
            let menu = NSMenu()
            for item in Self.linkItems(target) { menu.addItem(item) }
            return menu
        }

        /// Open Link and Copy Link for one address, for every menu that can open over a link.
        static func linkItems(_ target: URL) -> [NSMenuItem] {
            [
                ClosureMenuItem(title: Localized.text("Open Link")) {
                    NSWorkspace.shared.open(target)
                },
                ClosureMenuItem(title: Localized.text("Copy Link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.absoluteString, forType: .string)
                },
            ]
        }

        /// Where the links are drawn and where each goes, laid out the way the cell lays out its
        /// text and kept until the words or the width change.
        private func links() -> [(rect: NSRect, target: URL?)] {
            let area = cell?.titleRect(forBounds: bounds) ?? bounds
            if let linkFrames, linkFrames.width == area.width { return linkFrames.links }
            let text = attributedStringValue
            var ranges: [(NSRange, URL?)] = []
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) {
                value, range, _ in
                guard let value else { return }
                ranges.append((range, value as? URL ?? (value as? String).flatMap(URL.init)))
            }
            var found: [(rect: NSRect, target: URL?)] = []
            if !ranges.isEmpty, area.width > 0 {
                let storage = NSTextStorage(attributedString: text)
                let layout = NSLayoutManager()
                let container = NSTextContainer(
                    size: NSSize(width: area.width, height: .greatestFiniteMagnitude))
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
                for (range, target) in ranges {
                    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    layout.enumerateEnclosingRects(
                        forGlyphRange: glyphs,
                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                        in: container
                    ) { rect, _ in
                        let top = area.minY + rect.minY
                        found.append(
                            (
                                NSRect(
                                    x: area.minX + rect.minX,
                                    y: self.isFlipped ? top : self.bounds.height - top - rect.height,
                                    width: rect.width, height: rect.height), target
                            ))
                    }
                }
            }
            linkFrames = (area.width, found)
            return found
        }
    }

    /// A ground that answers the appearance it is being drawn under. A layer takes a `CGColor`,
    /// which is a colour with light and dark already resolved out of it, so a block painted after
    /// dark kept that dark through sunrise while the ink above it — dynamic to the last — flipped
    /// without it. Drawing the ground asks the token again every time, which is the only moment
    /// the answer is actually known.
    final class Ground: NSView {
        var fill: NSColor?
        var stroke: NSColor?
        var radius: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let inset: CGFloat = stroke == nil ? 0 : 0.5
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
            if let fill {
                fill.setFill()
                path.fill()
            }
            if let stroke {
                path.lineWidth = 1
                stroke.setStroke()
                path.stroke()
            }
        }
    }

    /// The same ground under a view that arranges its own rows — a card, a code block — laid in
    /// behind everything it holds rather than painted into its layer.
    static func ground(
        behind view: NSView, fill: NSColor?, stroke: NSColor? = nil, radius: CGFloat = 0
    ) {
        let ground = Ground(frame: .zero)
        ground.fill = fill
        ground.stroke = stroke
        ground.radius = radius
        view.addSubview(ground, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ground.topAnchor.constraint(equalTo: view.topAnchor),
            ground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    static func hairline(verticalPadding: CGFloat = 0) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        guard verticalPadding > 0 else { return line }
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: verticalPadding),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -verticalPadding),
        ])
        return wrap
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// A quiet inline action — "copy", "read summary", "open full output" — drawn as tinted text,
    /// not a bezel, because the transcript is content and bezels are chrome.
    /// A click on a plain view, carrying the closure it should run. AppKit's gesture recognizers
    /// take a target and a selector, and a row built in a static function has neither — so the
    /// gesture is its own target and holds the closure itself.
    final class PressGesture: NSClickGestureRecognizer {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
            super.init(target: nil, action: nil)
            self.target = self
            self.action = #selector(fire)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        @objc private func fire() { handler() }
    }

    /// A flat little button. `enabled` is for the ones that stay on screen having already been
    /// pressed: the row still says what was asked for, and says it cannot be asked twice.
    static func linkButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void)
        -> NSButton
    {
        let button = ActionButton(title: title, action: action)
        button.isBordered = false
        button.isEnabled = enabled
        button.contentTintColor = enabled ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel
        button.font = MacTheme.Ramp.font(.panelFootnote)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func inset(_ view: NSView, leading: CGFloat, top: CGFloat = 0) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            view.topAnchor.constraint(equalTo: wrap.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    /// A fenced block, lexed by the shared highlighter and painted in this theme's colours. The
    /// label does not wrap: a long line runs off the right and is scrolled to, because a line of
    /// code that reflowed is a line you cannot read and cannot count.
    static func code(_ body: String, language: String?) -> NSTextField {
        let font = MacTheme.Ramp.font(.code)
        let label: NSTextField
        if SyntaxHighlighter.isDiff(language) {
            let washed = DiffWashField(labelWithAttributedString: diffAttributed(body, font: font))
            washed.washes = SyntaxHighlighter.diffLines(body).compactMap { line in
                guard line.kind == .added || line.kind == .removed else { return nil }
                return (line.row, MacTheme.Color.diffBackground(line.kind))
            }
            washed.lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
            label = washed
        } else {
            let plain = NSMutableAttributedString(
                string: body,
                attributes: [.font: font, .foregroundColor: MacTheme.Color.label])
            for token in SyntaxHighlighter.tokens(body, language: language) {
                let range = NSRange(location: token.offset, length: token.length)
                guard NSMaxRange(range) <= plain.length else { continue }
                plain.addAttribute(
                    .foregroundColor, value: MacTheme.Color.syntax(token.role), range: range)
            }
            label = NSTextField(labelWithAttributedString: plain)
        }
        label.lineBreakMode = .byClipping
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// A field that paints a diff's washes itself, the full width of the line. A background
    /// attribute covers only glyph runs, so an attribute-painted wash stops at the last glyph
    /// and reads as a rendering bug rather than a ground. Code never wraps in this field, so a
    /// source row is a drawn row and the rect is arithmetic — row × line height, edge to edge.
    final class DiffWashField: NSTextField {
        var washes: [(row: Int, color: NSColor)] = [] {
            didSet { needsDisplay = true }
        }
        /// How many rows the field draws, which is what makes one of them measurable: the metric of
        /// a font the field was never told it is set in put every wash a little further down the
        /// block than the line it belongs to, and by the tenth line it was under the wrong code.
        var lines = 0

        override func draw(_ dirtyRect: NSRect) {
            if !washes.isEmpty, lines > 0 {
                let height = bounds.height / CGFloat(lines)
                for wash in washes {
                    let top = CGFloat(wash.row) * height
                    let y = isFlipped ? top : bounds.height - top - height
                    wash.color.setFill()
                    NSRect(x: 0, y: y, width: bounds.width, height: height).fill()
                }
            }
            super.draw(dirtyRect)
        }
    }

    /// A patch's ink. The wash under each changed line carries the diff's meaning — painted by
    /// the hosting view, full width, never as a background attribute that stops at the last
    /// glyph — which frees the foreground for the file's own language: the marker glyph keeps
    /// the diff's full ink, and every token on a washed line is coloured against the wash it
    /// actually sits on. A patch that names no file keeps the old whole-line red and green,
    /// because guessing a language would colour code as something it is not.
    static func diffAttributed(
        _ source: String, language: String? = nil, font: NSFont
    ) -> NSAttributedString {
        let diff = SyntaxHighlighter.diff(source, language: language)
        let result = NSMutableAttributedString(
            string: source,
            attributes: [.font: font, .foregroundColor: MacTheme.Color.label])
        let length = result.length
        for token in diff.tokens {
            let range = NSRange(location: token.offset, length: token.length)
            guard NSMaxRange(range) <= length else { continue }
            let kind = diff.kind(at: token.offset)
            let colour = kind == .added || kind == .removed
                ? MacTheme.Color.syntax(token.role, on: kind) : MacTheme.Color.syntax(token.role)
            result.addAttribute(.foregroundColor, value: colour, range: range)
        }
        return result
    }

    /// The pane a code block lives in: exactly as tall as the code, as wide as the column, and
    /// scrolling sideways when a line runs past it — never down, because a scroller inside the
    /// transcript's scroller is two gestures fighting over one wheel.
    static func codeScroll(around content: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.trailingAnchor.constraint(greaterThanOrEqualTo: clip.trailingAnchor),
            scroll.heightAnchor.constraint(equalTo: content.heightAnchor),
        ])
        return scroll
    }

    /// The lines a block shows right now — a gutter of numbers beside the code, both set in the
    /// same face so a row of one is a row of the other — folded or whole as the reader decided.
    static func codeLines(_ body: String, language: String?, expanded: Bool) -> NSView {
        let fold = TranscriptBlocks.fold(body, expanded: expanded)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        if fold.totalLines > 1 {
            let gutter = label(
                TranscriptBlocks.lineNumbers(fold), font: MacTheme.Ramp.font(.code),
                color: MacTheme.Color.tertiaryLabel)
            gutter.alignment = .right
            gutter.maximumNumberOfLines = 0
            gutter.setContentCompressionResistancePriority(.required, for: .horizontal)
            gutter.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(gutter)
        }
        let scroll = codeScroll(around: code(fold.shown, language: language))
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(scroll)
        return row
    }

    /// The copy button of a block: the bytes go to the pasteboard exactly, and the button says
    /// so for a moment where the pointer already is, beside the toast.
    static func copyButton(_ bytes: String, toast: ((String) -> Void)?) -> NSButton {
        let ref = Weak<NSButton>(nil)
        let button = linkButton(Localized.text("copy")) {
            copyToClipboard(bytes)
            toast?(Localized.text("Code copied"))
            ref.value?.title = Localized.text("copied")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                ref.value?.title = Localized.text("copy")
            }
        }
        ref.value = button
        button.font = MacTheme.Ramp.font(.codeAction)
        return button
    }

    /// A weak hand on a view for a closure the view itself owns, so a button that retitles
    /// itself does not keep itself alive.
    final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    /// A tool's output, given room to be read: whole when it is short, its first lines and a
    /// button naming the rest when it is long — never a box that scrolls inside the transcript.
    static func foldedOutput(_ output: String, render: @escaping (String) -> NSAttributedString)
        -> NSView
    {
        var opened = false
        let fold = TranscriptBlocks.fold(output, expanded: false)
        let field = attributedLabel(render(fold.shown))
        guard let title = fold.toggleLabel else { return field }
        let column = FillingStack()
        column.spacing = MacTheme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(field)
        let shown = Weak(field)
        let button = Weak<NSButton>(nil)
        let toggle = linkButton(title) {
            opened.toggle()
            let fold = TranscriptBlocks.fold(output, expanded: opened)
            shown.value?.attributedStringValue = render(fold.shown)
            button.value?.title = fold.toggleLabel ?? ""
        }
        button.value = toggle
        toggle.font = MacTheme.Ramp.font(.codeAction)
        column.addArrangedSubview(toggle)
        return column
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A target-action shim so a row built in a static function can hand a closure to AppKit.
    final class ActionButton: NSButton {
        private var handler: () -> Void

        init(title: String, action: @escaping () -> Void) {
            handler = action
            super.init(frame: .zero)
            self.title = title
            bezelStyle = .rounded
            target = self
            self.action = #selector(fire)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// What the button does, changed after it was made — a purchase button learns its product
        /// only once the App Store answers, and the window is built before that.
        func setAction(_ action: @escaping () -> Void) {
            handler = action
        }

        @objc private func fire() {
            handler()
        }
    }

    final class FlippedClip: NSClipView {
        nonisolated override var isFlipped: Bool { true }
    }
}

/// A header you click and a body that appears under it, built lazily the first time it opens —
/// nearly every row is collapsed, and its body must cost nothing until then. The body survives a
/// collapse hidden, so reopening is free. `onToggle` also receives the row itself, because the
/// one thing a caller cannot reconstruct from a key is where on screen the clicked header is.
@MainActor
final class DisclosureRow: NSView, KeyboardPressable {
    private let stack = FillingStack()
    private let makeBody: () -> NSView
    private let onToggle: (Bool, DisclosureRow) -> Void
    private var body: NSView?

    /// The header this row was built around, for a restate that writes into its labels.
    var headerView: NSView? { stack.arrangedSubviews.first }
    /// The body, if it has ever been opened — hidden while collapsed, never discarded.
    var bodyView: NSView? { body }

    init(
        header: NSView, expanded: Bool, onToggle: @escaping (Bool, DisclosureRow) -> Void,
        makeBody: @escaping () -> NSView
    ) {
        self.makeBody = makeBody
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack.addArrangedSubview(header)
        header.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggle)))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let spoken = Self.spoken(header)
        if !spoken.isEmpty { setAccessibilityLabel(spoken) }
        setAccessibilityExpanded(false)
        if expanded { reveal() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Every word the header shows, in the order it shows them. A tool's header is a row of labels
    /// — the tool, what it touched, how it ended — and naming the row only when its header was one
    /// label left the commonest row in a transcript unnamed to VoiceOver.
    private static func spoken(_ view: NSView) -> String {
        guard !view.isHidden else { return "" }
        if let field = view as? NSTextField { return field.stringValue }
        let parts = (view as? NSStackView)?.arrangedSubviews ?? view.subviews
        return parts.map(spoken).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// With Full Keyboard Access on, a row is a stop in the Tab loop and Space or Return opens it;
    /// without it a click keeps meaning what it always meant, and the composer keeps the keyboard.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard [49, 36, 76].contains(event.keyCode) else { return super.keyDown(with: event) }
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    @objc private func toggle() {
        if let body {
            body.isHidden = !body.isHidden
            setAccessibilityExpanded(!body.isHidden)
            onToggle(!body.isHidden, self)
            return
        }
        reveal()
        onToggle(true, self)
    }

    private func reveal() {
        let built = makeBody()
        stack.addArrangedSubview(built)
        body = built
        setAccessibilityExpanded(true)
    }

    /// The header restated without rebuilding the row — what a thought counting its own words
    /// needs, since tearing the row down twenty times a second is the flicker, not the counting.
    func restate(header text: String) {
        (stack.arrangedSubviews.first as? NSTextField)?.stringValue = text
        setAccessibilityLabel(text)
    }

    /// The body restated, when it happens to be open already.
    func restateBody(_ text: String) {
        guard let body else { return }
        if let field = body as? NSTextField {
            field.stringValue = text
            return
        }
        for view in body.subviews {
            if let field = view as? NSTextField {
                field.stringValue = text
                return
            }
        }
    }
}

/// A prompt row that knows its own message, so it can offer "Undo from here" the way every other
/// destructive action on a Mac does: from the row's own context menu rather than a button that
/// would sit in the transcript forever asking to be pressed.
///
/// The item is left off the menu entirely when it does not apply, rather than shown and disabled,
/// because a menu that always has the same items and sometimes greys one out invites a second
/// look at a row that never earned one. Where it does apply, the menu is the message's own, with
/// Copy beside it, because the words are a selectable label whose text menu would otherwise
/// answer every right-click on them.
@MainActor
final class PromptRow: NSView {
    private let messageID: String
    private let text: String?
    private let context: TranscriptContext

    init(messageID: String, text: String?, context: TranscriptContext) {
        self.messageID = messageID
        self.text = text
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return asksForMenu(NSApp.currentEvent) ? self : hit
    }

    /// Whether the event in flight is a request for a context menu this row answers: a right
    /// click, or a click with Control held, on a message that can be wound back to. Any other
    /// event reaches the label as before, so selecting the words still works.
    private func asksForMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        let wantsMenu =
            event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return wantsMenu && context.offersUndo?(messageID) == true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard context.offersUndo?(messageID) == true else { return nil }
        let menu = NSMenu()
        if let target = link(under: event) {
            for item in RowKit.ProseLabel.linkItems(target) { menu.addItem(item) }
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: RevertReading.actionTitle, action: #selector(undo), keyEquivalent: "")
        item.target = self
        item.image = NSImage(
            systemSymbolName: RevertReading.actionSymbol, accessibilityDescription: nil)
        menu.addItem(item)
        if text != nil {
            menu.addItem(.separator())
            let copy = NSMenuItem(
                title: Localized.text("Copy"), action: #selector(copyWords), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control), let menu = menu(for: event) else {
            return super.mouseDown(with: event)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func undo() {
        context.confirmUndo?(messageID)
    }

    /// The link under a right-click, when it landed on one. The message's own menu answers every
    /// right-click on the row, and a link in the words would otherwise have lost Open and Copy.
    private func link(under event: NSEvent) -> URL? {
        let point = convert(event.locationInWindow, from: nil)
        guard let label = hitLabel(at: point, in: self) else { return nil }
        return label.link(at: label.convert(point, from: self))
    }

    private func hitLabel(at point: NSPoint, in view: NSView) -> RowKit.ProseLabel? {
        for child in view.subviews.reversed() where !child.isHidden {
            let local = child.convert(point, from: view)
            guard child.bounds.contains(local) else { continue }
            if let label = child as? RowKit.ProseLabel { return label }
            if let found = hitLabel(at: local, in: child) { return found }
        }
        return nil
    }

    @objc private func copyWords() {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The row a sent message stands in until the server's account carries it. The rule and the words
/// are the prompt's own, because that is what this is; the state is the ink — faint on the wire,
/// full once the server has it, the danger tone when it never got there — and the line under the
/// words is drawn only when `PendingSendReading.caption` has something to say. The row survives a
/// phase change: the bubble animates from faint to full instead of being torn down and remade.
@MainActor
final class PendingSendRowView: NSView {
    private let rule = RowKit.Ground(frame: .zero)
    private let column = NSStackView()
    private let words: NSTextField
    private let strip = NSStackView()
    private let mark = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let acts = NSStackView()
    private var ink: PendingSendReading.Ink
    private var send: PendingSend
    private var plan: ResumePlan?
    private let context: TranscriptContext

    init(send: PendingSend, plan: ResumePlan?, now: Date, context: TranscriptContext) {
        self.send = send
        self.plan = plan
        self.context = context
        ink = PendingSendReading.ink(send)
        words = RowKit.attributedLabel(
            MacMarkdown.plainWithLinks(
                send.text, font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.label))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(words)

        strip.orientation = .horizontal
        strip.alignment = .firstBaseline
        strip.spacing = 5
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        caption.font = MacTheme.Ramp.font(.hint)
        strip.addArrangedSubview(mark)
        strip.addArrangedSubview(caption)
        column.addArrangedSubview(strip)

        acts.orientation = .horizontal
        acts.spacing = MacTheme.Spacing.m
        column.addArrangedSubview(acts)

        addSubview(rule)
        addSubview(column)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 2),
            column.leadingAnchor.constraint(
                equalTo: rule.trailingAnchor, constant: MacTheme.Spacing.s + 2),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        words.alphaValue = ink.opacity
        rule.alphaValue = ink.opacity
        paint(now: now)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The same row, a moment later: the ink moves on the platform's clock when the phase changed,
    /// and the strip appears or goes as the caption has something to say.
    func restate(send: PendingSend, plan: ResumePlan?, now: Date) {
        self.send = send
        self.plan = plan
        let next = PendingSendReading.ink(send)
        if next != ink {
            ink = next
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = reduced ? 0 : 0.25
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animation.allowsImplicitAnimation = true
                words.animator().alphaValue = next.opacity
                rule.animator().alphaValue = next.opacity
            }
        }
        paint(now: now)
    }

    private func paint(now: Date) {
        rule.fill =
            plan != nil
            ? MacTheme.Color.warning
            : (ink == .failed ? MacTheme.Color.danger : MacTheme.Color.accent)
        rule.needsDisplay = true
        let line = plan.map { ResumeReading.caption($0, now: now) }
            ?? PendingSendReading.caption(send, now: now)
        let icon = plan == nil ? PendingSendReading.icon(send) : ResumeReading.icon
        strip.isHidden = line == nil
        if let line {
            caption.stringValue = line
            caption.textColor = icon.tone.color
            mark.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)
            mark.contentTintColor = icon.tone.color
            mark.isHidden = mark.image == nil
        }
        for view in acts.arrangedSubviews { view.removeFromSuperview() }
        if let plan, let act = context.resumeAct {
            let id = plan.id
            for choice in ResumeReading.acts {
                acts.addArrangedSubview(
                    RowKit.linkButton(ResumeReading.title(choice)) { act(id, choice) })
            }
        } else if !send.acts.isEmpty, let act = context.pendingAct {
            let id = send.id
            for choice in send.acts {
                acts.addArrangedSubview(
                    RowKit.linkButton(PendingSendReading.title(choice)) { act(id, choice) })
            }
        }
        acts.isHidden = acts.arrangedSubviews.isEmpty
        setAccessibilityLabel(
            plan.map { ResumeReading.spoken($0, words: send.text, now: now) }
                ?? PendingSendReading.spoken(send, now: now))
    }
}
