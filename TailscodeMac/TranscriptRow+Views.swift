import AppKit
import CodingAgentKit
import TailscodeCore

extension TranscriptRow {
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
            let label = RowKit.attributedLabel(rendered)
            let rowKey = key
            (label as? RowKit.ProseLabel)?.verbs = { [weak context] in
                [
                    RowKit.verb(Localized.text("Copy")) {
                        context?.copyAnswer?(rowKey)
                    }
                ]
            }
            return label
        case .codeBlock(let language, let body):
            return Self.codeBlock(language: language, body: body, key: key, context: context)
        case .linkRail(let urls):
            return Self.linkRail(urls, key: key, context: context)
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
        case .subagentGroup(let fanout):
            return SubagentGroupView.make(fanout, key: key, context: context)
        case .file(let reference, let mine, let messageID):
            let view = ImageRowView.make(reference, mine: mine, key: key, context: context)
            guard mine else { return view }
            return Self.wrappedForUndo(view, messageID: messageID, context: context)
        case .pictures(let pictures):
            return PictureGalleryRowView.make(pictures, context: context)
        case .designBoard(let sighting):
            return Self.designBoard(sighting, context: context)
        case .taskBoard(let board):
            return TaskBoardView.make(board)
        case .compaction(let compaction):
            return Self.seam(compaction, key: key, context: context)
        case .answerless(let turn):
            return Self.answerless(turn, context: context)
        case .failedTurn(let turn):
            return Self.failedTurn(turn, context: context)
        case .responseStats(let stats):
            return Self.responseStats(stats)
        case .queuedSend(let row, let position, let total):
            return Self.queuedSend(row, position: position, of: total, context: context)
        case .queuePaused(let count):
            return Self.queuePaused(count: count, context: context)
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
        case .brain(let brain):
            return BrainRowView(row: brain, key: key, context: context)
        case .turnBreak:
            return RowKit.hairline(verticalPadding: ChatLayout.turnBreakPadding)
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
        (label as? RowKit.ProseLabel)?.verbs = { [weak context] in
            var verbs = [
                RowKit.verb(Localized.text("Copy")) {
                    RowKit.copyToClipboard(text)
                    context?.toast?(Localized.text("Copied"))
                }
            ]
            if context?.offersUndo?(messageID) == true {
                verbs.append(
                    RowKit.verb(RevertReading.actionTitle) { context?.confirmUndo?(messageID) })
            }
            return verbs
        }
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
        row.setContentHuggingPriority(view.contentHuggingPriority(for: .horizontal), for: .horizontal)
        row.flowWidth = view.flowWidth
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

    /// A fenced block: a gutter of line numbers, the code scrolling sideways and never down, and
    /// under a long one a button naming the lines behind it. The block has no header row of its
    /// own: its language and its copy appear at its top corner when the pointer is on it
    /// (`MessageHoverBar`), so the block is as tall as its code. Opening grows the block in the
    /// page, so the transcript's own scroll carries it.
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
            column.insertArrangedSubview(fresh, at: 0)
            lines = fresh
            button.value?.title = TranscriptBlocks.fold(body, expanded: opened).toggleLabel ?? ""
        }
        button.value = toggle
        toggle.font = MacTheme.Ramp.font(.codeAction)
        column.addArrangedSubview(toggle)
        return column
    }

    /// A compaction is a seam, not a message: one divider line saying what was traded for what —
    /// `Context compacted · 311.6k → 16.4k tokens · 1m 54s ›` — with the CLI's machine-facing
    /// summary, tens of thousands of words, behind it in a reader. The bar and the sentence that
    /// used to stand under the title are in that reader, because they say something only to a
    /// person who asks.
    @MainActor
    private static func seam(
        _ compaction: Compaction, key: String, context: TranscriptContext
    ) -> NSView {
        let story = CompactionStory.done(compaction)
        let words = "\(story.title) · \(story.detail)"
        var press: (() -> Void)?
        if let summary = story.summary, story.isReadable {
            let present = context.presentText
            let header = CompactionStory.summaryHeader(compaction)
            press = { present?(Localized.text("Compaction summary"), header, summary, false) }
        }
        return SeamLineView(
            symbol: story.symbol, text: words, tint: MacTheme.Color.accent,
            spoken: "\(story.title). \(story.detail)", onPress: press)
    }

    /// A prompt that has been written and not sent, drawn as the prompt it will become — same
    /// words, same place — but dimmed, marked, and pressable, because it is the one row in the
    /// transcript that is still the reader's to change. Nothing about it may read as sent.
    @MainActor
    private static func queuedSend(
        _ row: QueueRow, position: Int, of total: Int, context: TranscriptContext
    ) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        let title = RowKit.wrapping(
            "", font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.secondaryLabel)
        title.attributedStringValue = RowKit.symbolText(
            QueueReading.symbol(row), row.title,
            font: MacTheme.Ramp.font(.prompt), color: MacTheme.Color.secondaryLabel)
        column.addArrangedSubview(title)
        column.addArrangedSubview(
            RowKit.label(
                QueueReading.hint(row), font: MacTheme.Ramp.font(.hint),
                color: MacTheme.Color.secondaryLabel))
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.group)
        column.setAccessibilityLabel(QueueReading.spoken(row, position: position, of: total))
        column.toolTip = QueueReading.hint(row)
        guard row.canEdit, let edit = context.editQueued else { return column }
        let id = row.id
        column.addGestureRecognizer(RowKit.PressGesture { edit(id) })
        HoverPlate.attach(to: column)
        return column
    }

    /// The note under a queue a Stop paused, with the one press that lets it go on: the pause is
    /// the queue's, so Resume is drawn once beneath all of its messages.
    @MainActor
    private static func queuePaused(count: Int, context: TranscriptContext) -> NSView {
        let line = QueueReading.pausedLine(count: count)
        let card = RowKit.card(
            symbol: SendQueueReading.heldSymbol, title: line, detail: QueueReading.pausedHint,
            tint: MacTheme.Color.secondaryLabel)
        if let resume = context.resumeQueue {
            card.addArrangedSubview(RowKit.linkButton(QueueReading.resume, action: resume))
        }
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("\(line). \(QueueReading.pausedHint)")
        return card
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
}
