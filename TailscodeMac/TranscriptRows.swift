import AppKit
import CodingAgentKit
import TailscodeCore

/// What a row needs from the transcript that is not in the row itself: which rows are open, the
/// pictures and subagent transcripts already fetched, and the callbacks that fetch more. Rows are
/// rebuilt freely; this survives them.
@MainActor
final class TranscriptContext {
    var expanded = TranscriptExpansion()
    /// The newest text of a thought that is still being written. A reasoning row's header counts
    /// its words, so it changes on every arrival — and rebuilding the row for that is a flicker.
    /// The row is updated in place instead, and a body opened afterwards reads the current text
    /// from here rather than the one its closure was built with.
    var liveReasoning: [String: String] = [:]
    var subagentRows: [String: [TranscriptRow]] = [:]
    /// Live facts for the agents of the running fan-out, keyed by spawning tool-use id — what an
    /// inline agent card shows for progress while its transcript is still being written.
    var agentFacts: [String: SubagentSummary] = [:]
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
    /// A turn the server's machine cut off, picked back up or let go on that machine.
    var resumeInterrupted: (() -> Void)?
    var dismissInterrupted: (() -> Void)?

    /// A run reads as open when any step inside it is, so folding a step into a run carries the
    /// reader's decision in with it rather than collapsing it.
    func isExpanded(_ key: String) -> Bool { expanded.reads(key) }
}

/// Folds messages into rows with a per-message memo: a streamed token changes one message, so
/// re-deriving the other two hundred and ninety-nine — markdown and all — on every state would be
/// the seconds-long pause between "Loading…" and the transcript. Only messages whose value
/// actually changed are re-folded.
@MainActor
final class TranscriptRowBuilder {
    private var cache: [String: (message: ChatMessage, promptID: String?, rows: [TranscriptRow])] =
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
    func rows(for messages: [ChatMessage]) -> [TranscriptRow] {
        var all: [TranscriptRow] = []
        var next: [String: (message: ChatMessage, promptID: String?, rows: [TranscriptRow])] = [:]
        next.reserveCapacity(messages.count)
        var prompt: ChatMessage?
        for message in messages {
            let rows: [TranscriptRow]
            if let hit = cache[message.id], hit.message == message, hit.promptID == prompt?.id {
                rows = hit.rows
            } else {
                rows = TranscriptRow.rows(for: message, prompt: prompt)
            }
            next[message.id] = (message, prompt?.id, rows)
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
        case userText(String)
        case interruption
        /// The rendering rides in the row, computed where the rows are computed, so painting a
        /// prose row is a label set, not a markdown parse.
        case agentProse(text: String, rendered: NSAttributedString)
        case codeBlock(language: String?, body: String)
        case table(MarkdownTable)
        case reasoning(String)
        case tool(ToolCall)
        case run([ActivityStep])
        case subagent(ToolCall)
        case workflow(ToolCall)
        case file(FileReference, mine: Bool)
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
        case pendingSend(PendingSend, now: Date)
        /// Not `interruption`, which is the escape key: this is the machine stopping mid-answer.
        case interruptedTurn(InterruptedTurn)
        case turnBreak
    }

    let key: String
    let kind: Kind

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
        if call.summary.kind == .workflow { return .workflow(call) }
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
    static func rows(for message: ChatMessage, prompt: ChatMessage? = nil) -> [TranscriptRow] {
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
                        rows.append(TranscriptRow(key: key, kind: .userText(remainder)))
                    }
                    continue
                }
                for (index, segment) in MessageSegment.split(stripped).enumerated() {
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
                        rows.append(TranscriptRow(key: "\(key):s\(index)", kind: .table(table)))
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
                    TranscriptRow(key: key, kind: .file(reference, mine: message.role == .user)))
            case .compaction(let compaction):
                rows.append(TranscriptRow(key: key, kind: .compaction(compaction)))
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
        case .userText(let text), .reasoning(let text):
            return text
        case .agentProse(let text, _):
            return text
        case .codeBlock(let language, let body):
            return "\(language ?? "") \(body)"
        case .table(let table):
            return (table.header + table.rows.flatMap { $0 }).joined(separator: " ")
        case .tool(let call), .subagent(let call), .workflow(let call):
            return Self.searchText(for: call)
        case .run(let steps):
            return steps.map { step -> String in
                switch step {
                case .reasoning(_, let text): return text
                case .tool(_, let call): return Self.searchText(for: call)
                }
            }.joined(separator: " ")
        case .file(let reference, _):
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
        case .pendingSend(let send, let now):
            return PendingSendReading.spoken(send, now: now)
        case .interruptedTurn(let turn):
            return "\(turn.title) \(turn.prompt)"
        case .interruption:
            return "interrupted"
        case .turnBreak:
            return ""
        }
    }

    @MainActor
    func makeView(context: TranscriptContext) -> NSView {
        switch kind {
        case .userText(let text):
            return Self.prompt(text)
        case .interruption:
            return RowKit.label(
                "⌧ " + Localized.text("interrupted"), font: MacTheme.Ramp.font(.interruption),
                color: MacTheme.Color.tertiaryLabel)
        case .agentProse(_, let rendered):
            return RowKit.attributedLabel(rendered)
        case .codeBlock(let language, let body):
            return Self.codeBlock(language: language, body: body, context: context)
        case .table(let table):
            return Self.table(table)
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
        case .file(let reference, let mine):
            return ImageRowView.make(reference, mine: mine, key: key, context: context)
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
        case .pendingSend(let send, let now):
            return Self.pendingSend(send, now: now, context: context)
        case .interruptedTurn(let turn):
            return Self.interruptedTurn(turn, context: context)
        case .turnBreak:
            return RowKit.hairline(verticalPadding: MacTheme.Spacing.m)
        }
    }

    @MainActor
    private static func prompt(_ text: String) -> NSView {
        let rule = RowKit.Ground(frame: .zero)
        rule.fill = MacTheme.Color.accent

        let label = RowKit.attributedLabel(
            MacMarkdown.plainWithLinks(
                text, font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.label))
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
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

    /// Markdown as the transcript renders it — headings, emphasis, lists, links, fenced code with
    /// its own copy — for prose that lives outside the transcript: a compaction summary in the
    /// reader, where the CLI's own formatting is the only structure the text has.
    @MainActor
    static func richBody(_ text: String, context: TranscriptContext?) -> NSView {
        let column = FillingStack()
        column.spacing = MacTheme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        for segment in MessageSegment.split(text) {
            switch segment {
            case .prose(let prose):
                for chunk in paragraphChunks(prose) {
                    column.addArrangedSubview(RowKit.attributedLabel(MacMarkdown.render(chunk)))
                }
            case .code(let language, let body):
                column.addArrangedSubview(
                    codeBlock(language: language, body: body, context: context))
            case .table(let table):
                column.addArrangedSubview(Self.table(table))
            }
        }
        return column
    }

    /// A pipe table as columns: NSGridView does the sizing, a hairline seats the header, and a
    /// cell wraps past its cap so a prose column folds instead of running the pane out.
    @MainActor
    static func table(_ table: MarkdownTable) -> NSView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 3
        grid.columnSpacing = 16
        grid.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        func cell(_ text: String, header: Bool) -> NSTextField {
            let label = RowKit.attributedLabel(MacMarkdown.tableCell(text, header: header))
            label.preferredMaxLayoutWidth = 340 * MacTheme.UIScale.factor
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            return label
        }

        grid.addRow(with: table.header.map { cell($0, header: true) })
        grid.addRow(with: [RowKit.hairline(verticalPadding: 2)])
        grid.mergeCells(
            inHorizontalRange: NSRange(location: 0, length: table.columnCount),
            verticalRange: NSRange(location: 1, length: 1))
        for row in table.rows.indices {
            grid.addRow(with: table.cells(in: row).map { cell($0, header: false) })
        }
        for column in 0..<table.columnCount {
            switch table.alignment(of: column) {
            case .leading: grid.column(at: column).xPlacement = .leading
            case .center: grid.column(at: column).xPlacement = .center
            case .trailing: grid.column(at: column).xPlacement = .trailing
            }
        }
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            grid.topAnchor.constraint(equalTo: wrap.topAnchor),
            grid.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor),
        ])
        return wrap
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

    @MainActor
    private static func codeBlock(
        language: String?, body: String, context: TranscriptContext?
    ) -> NSView {
        let column = FillingStack()
        column.spacing = 2
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
        let toast = context?.toast
        let copy = RowKit.linkButton(Localized.text("copy")) {
            RowKit.copyToClipboard(body)
            toast?(Localized.text("Code copied"))
        }
        copy.font = MacTheme.Ramp.font(.codeAction)
        header.addArrangedSubview(copy)
        column.addArrangedSubview(header)

        let text = RowKit.code(body, language: language)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        let scrolled = RowKit.codeScroll(
            around: text, cap: TranscriptBlocks.fitsInline(body) ? nil : TranscriptBlocks.cappedHeight)
        column.addArrangedSubview(scrolled)
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

    /// A message on its way out: the words drawn as the prompt they will become, with a line
    /// under them saying whether they went.
    ///
    /// The rule and the words are the prompt's own, because that is what this is. What is added is
    /// the one thing the transcript could never say — that the message is not in the server's
    /// account yet — and, when it never got there, the words stay here and offer the three things
    /// worth doing about them rather than being dropped back into the composer.
    @MainActor
    private static func pendingSend(
        _ send: PendingSend, now: Date, context: TranscriptContext
    ) -> NSView {
        let icon = PendingSendReading.icon(send)
        let rule = RowKit.Ground(frame: .zero)
        rule.fill = send.isFailed ? MacTheme.Color.danger : MacTheme.Color.accent

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(
            RowKit.attributedLabel(
                MacMarkdown.plainWithLinks(
                    send.text, font: MacTheme.Ramp.font(.prompt),
                    color: send.isFailed ? MacTheme.Color.secondaryLabel : MacTheme.Color.label)))

        let status = NSStackView()
        status.orientation = .horizontal
        status.alignment = .firstBaseline
        status.spacing = 5
        if let symbol = NSImage(
            systemSymbolName: icon.symbol, accessibilityDescription: nil)
        {
            let mark = NSImageView(image: symbol)
            mark.contentTintColor = icon.tone.color
            mark.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 10, weight: .semibold)
            status.addArrangedSubview(mark)
        }
        status.addArrangedSubview(
            RowKit.label(
                PendingSendReading.caption(send, now: now), font: MacTheme.Ramp.font(.hint),
                color: icon.tone.color))
        column.addArrangedSubview(status)

        if !send.acts.isEmpty, let act = context.pendingAct {
            let buttons = NSStackView()
            buttons.orientation = .horizontal
            buttons.spacing = MacTheme.Spacing.m
            let id = send.id
            for choice in send.acts {
                buttons.addArrangedSubview(
                    RowKit.linkButton(PendingSendReading.title(choice)) { act(id, choice) })
            }
            column.addArrangedSubview(buttons)
        }

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(rule)
        row.addSubview(column)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            rule.topAnchor.constraint(equalTo: row.topAnchor),
            rule.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 2),
            column.leadingAnchor.constraint(
                equalTo: rule.trailingAnchor, constant: MacTheme.Spacing.s + 2),
            column.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            column.topAnchor.constraint(equalTo: row.topAnchor),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel(PendingSendReading.spoken(send, now: now))
        return row
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
        if !turn.queued.isEmpty {
            card.addArrangedSubview(
                RowKit.wrapping(
                    turn.queued.count == 1
                        ? Localized.text("One prompt was waiting behind it and never ran.")
                        : Localized.text(
                            "%@ prompts were waiting behind it and never ran.",
                            "\(turn.queued.count)"),
                    font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.secondaryLabel))
        }
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.m
        if !turn.isResumed, let resume = context.resumeInterrupted {
            buttons.addArrangedSubview(RowKit.linkButton(turn.resumeTitle) { resume() })
        }
        if let dismiss = context.dismissInterrupted {
            buttons.addArrangedSubview(RowKit.linkButton(turn.dismissTitle) { dismiss() })
        }
        card.addArrangedSubview(buttons)
        return card
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
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
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

    static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
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
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
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

    static func linkButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(title: title, action: action)
        button.isBordered = false
        button.contentTintColor = MacTheme.Color.accent
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

    /// The pane a code block lives in: as tall as the code up to an optional cap, as wide as the
    /// column, and scrolling in whichever direction the code actually overflows.
    static func codeScroll(around content: NSView, cap: CGFloat?) -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = cap != nil
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
        ])
        if let cap { scroll.heightAnchor.constraint(lessThanOrEqualToConstant: cap).isActive = true }
        let fit = scroll.heightAnchor.constraint(equalTo: content.heightAnchor)
        fit.priority = .defaultHigh
        fit.isActive = true
        return scroll
    }

    /// Output boxes stop growing at a cap and scroll inside themselves, so one chatty tool cannot
    /// push the conversation off the screen.
    static func heightCappedScroll(around content: NSView, max cap: CGFloat) -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        scroll.heightAnchor.constraint(lessThanOrEqualToConstant: cap).isActive = true
        let fit = scroll.heightAnchor.constraint(equalTo: content.heightAnchor)
        fit.priority = .defaultHigh
        fit.isActive = true
        return scroll
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A target-action shim so a row built in a static function can hand a closure to AppKit.
    final class ActionButton: NSButton {
        private let handler: () -> Void

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

        @objc private func fire() {
            handler()
        }
    }

    final class FlippedClip: NSClipView {
        override var isFlipped: Bool { true }
    }
}

/// A header you click and a body that appears under it, built lazily the first time it opens —
/// nearly every row is collapsed, and its body must cost nothing until then. The body survives a
/// collapse hidden, so reopening is free. `onToggle` also receives the row itself, because the
/// one thing a caller cannot reconstruct from a key is where on screen the clicked header is.
@MainActor
final class DisclosureRow: NSView {
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
        if let title = (header as? NSTextField)?.stringValue, !title.isEmpty {
            setAccessibilityLabel(title)
        }
        setAccessibilityExpanded(false)
        if expanded { reveal() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
