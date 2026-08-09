import AppKit
import CodingAgentKit
import TailscodeCore

/// What a row needs from the transcript that is not in the row itself: which rows are open, the
/// pictures and subagent transcripts already fetched, and the callbacks that fetch more. Rows are
/// rebuilt freely; this survives them.
@MainActor
final class TranscriptContext {
    var expanded: Set<String> = []
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

    func isExpanded(_ key: String) -> Bool { expanded.contains(key) }
}

/// Folds messages into rows with a per-message memo: a streamed token changes one message, so
/// re-deriving the other two hundred and ninety-nine — markdown and all — on every state would be
/// the seconds-long pause between "Loading…" and the transcript. Only messages whose value
/// actually changed are re-folded.
@MainActor
final class TranscriptRowBuilder {
    private var cache: [String: (message: ChatMessage, rows: [TranscriptRow])] = [:]

    /// Forgets every memoised row — the rendering baked into them (fonts, markdown) is stale
    /// after a type-scale change.
    func invalidate() {
        cache = [:]
    }

    func rows(for messages: [ChatMessage]) -> [TranscriptRow] {
        var all: [TranscriptRow] = []
        var next: [String: (message: ChatMessage, rows: [TranscriptRow])] = [:]
        next.reserveCapacity(messages.count)
        for message in messages {
            let rows: [TranscriptRow]
            if let hit = cache[message.id], hit.message == message {
                rows = hit.rows
            } else {
                rows = TranscriptRow.rows(for: message)
            }
            next[message.id] = (message, rows)
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
    case reasoning(String)
    case tool(ToolCall)
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
        case taskBoard(TaskBoard)
        case compaction(Compaction)
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
    static func rows(for message: ChatMessage) -> [TranscriptRow] {
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
        return rows
    }

    /// Rows for a whole transcript, with a hairline between turns so the reading rhythm survives
    /// density.
    @MainActor
    static func rows(for messages: [ChatMessage]) -> [TranscriptRow] {
        var all: [TranscriptRow] = []
        for message in messages {
            let rows = Self.rows(for: message)
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
    static func placeBoard(in rows: [TranscriptRow]) -> [TranscriptRow] {
        let calls = rows.compactMap { row -> ToolCall? in
            guard case .tool(let call) = row.kind, TaskBoard.isBoardCall(call.name) else {
                return nil
            }
            return call
        }
        let board = TaskBoard.fold(calls)
        guard !board.isEmpty, let lastID = calls.last?.id else { return rows }
        return rows.map { row in
            guard case .tool(let call) = row.kind, call.id == lastID else { return row }
            return TranscriptRow(key: row.key, kind: .taskBoard(board))
        }
    }

    /// Compact mode: everything the agent did between two messages — the thoughts and the tool
    /// calls, failures included — folds to one line. Twelve greps, four edits and the thinking
    /// around them are one fact: "it worked". The run keeps every step inside it, one click away;
    /// only what is its own card (a subagent, a workflow, a picture) never joins a run, and a run
    /// with no tools stays its own thought rows so a lone reflection still reads as one.
    static func fuse(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var fused: [TranscriptRow] = []
        var run: [ActivityStep] = []
        var runKey = ""

        func flush() {
            guard !run.isEmpty else { return }
            let tools = run.compactMap { step -> ToolCall? in
                if case .tool(let call) = step { return call }
                return nil
            }
            if tools.isEmpty {
                for step in run {
                    if case .reasoning(let text) = step {
                        fused.append(TranscriptRow(key: runKey, kind: .reasoning(text)))
                    }
                }
            } else if tools.count == 1, run.count == 1 {
                fused.append(TranscriptRow(key: runKey, kind: .tool(tools[0])))
            } else {
                fused.append(TranscriptRow(key: "run:\(runKey)", kind: .run(run)))
            }
            run = []
        }

        for row in rows {
            switch row.kind {
            case .tool(let call):
                if run.isEmpty { runKey = row.key }
                run.append(.tool(call))
            case .reasoning(let text):
                if run.isEmpty { runKey = row.key }
                run.append(.reasoning(text))
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
                case .reasoning(let text): return text
                case .tool(let call): return Self.searchText(for: call)
                }
            }.joined(separator: " ")
        case .file(let reference, _):
            return reference.filename ?? reference.path ?? ""
        case .taskBoard(let board):
            return board.items.map(\.subject).joined(separator: " ")
        case .compaction(let compaction):
            return compaction.summary ?? ""
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
                "⌧ " + Localized.text("interrupted"), font: MacTheme.Font.caption(),
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
        case .taskBoard(let board):
            return TaskBoardView.make(board)
        case .compaction(let compaction):
            return Self.seam(compaction, key: key, context: context)
        case .turnBreak:
            return RowKit.hairline(verticalPadding: 10)
        }
    }

    @MainActor
    private static func prompt(_ text: String) -> NSView {
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = MacTheme.Color.accent.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        let label = RowKit.wrapping(text, font: MacTheme.Font.body(), color: MacTheme.Color.label)
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
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 10
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
            label.preferredMaxLayoutWidth = 340
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
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        column.translatesAutoresizingMaskIntoConstraints = false
        column.wantsLayer = true
        column.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        column.layer?.cornerRadius = 8

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = MacTheme.Spacing.s
        let tag = RowKit.label(
            SyntaxHighlighter.displayName(for: language, source: body), font: MacTheme.Font.caption(),
            color: MacTheme.Color.tertiaryLabel)
        header.addArrangedSubview(tag)
        header.addArrangedSubview(RowKit.spacer())
        let toast = context?.toast
        header.addArrangedSubview(
            RowKit.linkButton(Localized.text("copy")) {
                RowKit.copyToClipboard(body)
                toast?(Localized.text("Code copied"))
            })
        column.addArrangedSubview(header)

        let text = RowKit.code(body, language: language)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        let scrolled = RowKit.codeScroll(around: text, cap: lines > 18 && body.count > 600 ? 320 : nil)
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
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = MacTheme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(RowKit.hairline())

        let card = RowKit.compactionCard(story, tint: MacTheme.Color.accent)

        if let kept = story.keptFraction {
            let track = NSView()
            track.wantsLayer = true
            track.layer?.backgroundColor = MacTheme.Color.separator.cgColor
            track.layer?.cornerRadius = 2
            track.translatesAutoresizingMaskIntoConstraints = false
            let fill = NSView()
            fill.wantsLayer = true
            fill.layer?.backgroundColor = MacTheme.Color.accent.cgColor
            fill.layer?.cornerRadius = 2
            fill.translatesAutoresizingMaskIntoConstraints = false
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
                    footnote, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
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
}

/// The small vocabulary every row view speaks: labels that wrap, labels that truncate, hairlines,
/// flat little buttons, capped scrolls — one place, so the rows stay about their content.
@MainActor
enum RowKit {
    /// The shell every compaction card shares: the raised box, the symbol wearing the story's
    /// tone, the bold title and the detail line. Callers append what their state adds — a bar, a
    /// ticking clock, a reader link.
    static func compactionCard(_ story: CompactionStory, tint: NSColor) -> NSStackView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = MacTheme.Spacing.s
        card.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = MacTheme.Color.subagentBackground.cgColor
        card.layer?.cornerRadius = MacTheme.Radius.card
        card.layer?.borderWidth = 1
        card.layer?.borderColor = MacTheme.Color.separator.cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: story.symbol, accessibilityDescription: story.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [
            icon, label(story.title, font: MacTheme.Font.emphasis(), color: MacTheme.Color.label),
        ])
        header.orientation = .horizontal
        header.spacing = MacTheme.Spacing.s
        card.addArrangedSubview(header)
        card.addArrangedSubview(
            wrapping(
                story.detail, font: MacTheme.Font.caption(), color: MacTheme.Color.secondaryLabel))
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
    static func linkButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(title: title, action: action)
        button.isBordered = false
        button.contentTintColor = MacTheme.Color.accent
        button.font = MacTheme.Font.caption()
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
        let font = MacTheme.Font.mono(12)
        let label: NSTextField
        if SyntaxHighlighter.isDiff(language) {
            let washed = DiffWashField(labelWithAttributedString: diffAttributed(body, font: font))
            washed.washes = SyntaxHighlighter.diffLines(body).compactMap { line in
                guard line.kind == .added || line.kind == .removed else { return nil }
                return (line.row, MacTheme.Color.diffBackground(line.kind))
            }
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

        override func draw(_ dirtyRect: NSRect) {
            if !washes.isEmpty, let font {
                let height = NSLayoutManager().defaultLineHeight(for: font)
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
    private let stack = NSStackView()
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
        stack.orientation = .vertical
        stack.alignment = .width
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
        if expanded { reveal() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() {
        if let body {
            body.isHidden = !body.isHidden
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
