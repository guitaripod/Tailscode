import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TranscriptRow {
    /// The text the agent is still writing into, when this row is the kind that grows a character
    /// at a time. Everything else — a tool call, a picture, a seam — arrives whole and has nothing
    /// for the cascade to pace.
    var streamedText: String? {
        switch kind {
        case .agentProse(let text, _): return text
        case .codeBlock(_, let body): return body
        default: return nil
        }
    }

    /// Whether this row is a strip that draws the picture cached under `key`.
    func holdsPicture(_ key: String) -> Bool {
        guard case .pictures(let pictures) = kind else { return false }
        return pictures.contains { $0.key == key }
    }

    /// Whether this row is a link rail rather than something the agent wrote. A rail is docked
    /// under the prose that mentioned its addresses, so it is never the row being streamed into,
    /// whatever it is last among.
    var isLinkRail: Bool {
        if case .linkRail = kind { return true }
        return false
    }

    /// Whether the text this row streams is prose, whose half-open inline markdown the gate has to
    /// hold back, or code, which has none of it to protect and everything to lose by being judged
    /// as if it did: `**kwargs`, `*ptr`, `self._value` and an odd count of backticks in a comment
    /// are all unclosed markdown tokens and all ordinary syntax, so a code block read through the
    /// gate freezes behind the first one, dumps when the gate gives up, and freezes again.
    var streamsMarkdown: Bool {
        if case .codeBlock = kind { return false }
        return true
    }

    /// Whether this row's arrival is worth a fade. A prompt the person typed has been on screen
    /// since they pressed Enter — it is echoed locally and only later confirmed by the server under
    /// the server's own key — so animating it, and the turn break above it, blinks the words they
    /// just wrote out of the transcript and fades them back in.
    var announcesArrival: Bool {
        switch kind {
        case .userText, .turnBreak: return false
        default: return true
        }
    }

    /// The same row with only the part of its text that has been revealed. The markup is rebuilt
    /// uncached: a growing prefix is a new string sixty times a second and none of them will ever
    /// be asked for again.
    func truncated(to visible: String) -> TranscriptRow {
        switch kind {
        case .agentProse:
            let palette = MatrixTheme.palette
            return TranscriptRow(
                key: key,
                kind: .agentProse(
                    text: visible,
                    markup: PangoMarkdown.render(
                        visible, dim: palette.textDim, code: palette.info,
                        accent: palette.accent, cache: false)))
        case .codeBlock(let language, _):
            return TranscriptRow(key: key, kind: .codeBlock(language: language, body: visible))
        default:
            return self
        }
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
        case .linkRail(let urls):
            return urls.joined(separator: " ")
        case .pictures(let pictures):
            return pictures.map { $0.reference.filename ?? $0.reference.path ?? "" }.joined(separator: " ")
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
        case .file(let reference, _):
            return reference.filename ?? reference.path ?? ""
        case .designBoard(let sighting):
            let reading = DesignCardReading.make(sighting: sighting, board: nil)
            return "\(reading.title) \(reading.detail)"
        case .taskBoard(let board):
            return board.items.map(\.subject).joined(separator: " ")
        case .compaction(let compaction):
            return compaction.summary ?? ""
        case .answerless(let turn):
            return "\(turn.title) \(turn.detail)"
        case .failed(let turn):
            return "\(turn.title) \(turn.detail) \(turn.reason)"
        case .subagentGroup(let members):
            return members.map { Self.searchText(for: $0.call) }.joined(separator: " ")
        case .responseStats(let stats):
            return stats.spoken
        case .queuedSend(let row, _, _):
            return row.title
        case .queuePaused(let count):
            return QueueReading.pausedLine(count: count)
        case .pendingSend(let send, let plan):
            guard let plan else { return PendingSendReading.spoken(send, now: Date()) }
            return ResumeReading.spoken(plan, words: send.text)
        case .interruptedTurn(let turn):
            return "\(turn.title) \(turn.prompt)"
        case .note(let line):
            return line.text
        case .providerRetry(let card):
            return "\(card.title) \(card.reason)"
        case .revertBanner(let banner, _):
            return "\(banner.title) \(banner.detail)"
        case .interruption:
            return "interrupted"
        case .brain(let brain):
            return brain.turn.steps.map { step in
                [step.title, step.detail, step.text].filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: " ")
        case .turnBreak:
            return ""
        }
    }

    func makeWidget(context: TranscriptContext) -> UnsafeMutablePointer<GtkWidget> {
        let widget = buildWidget(context: context)
        if Soak.isOn { tailscode_soak_track_row(widget) }
        return widget
    }

    func buildWidget(context: TranscriptContext) -> UnsafeMutablePointer<GtkWidget> {
        switch kind {
        case .userText(let text, let messageID):
            return Self.prompt(text, messageID: messageID, context: context)
        case .interruption:
            let label = Gtk.label(
                "⌧ " + Localized.text("interrupted"), css: "interruption", selectable: false)
            gtk_widget_set_halign(label, GTK_ALIGN_START)
            return label
        case .agentProse(let text, let markup):
            let label = Gtk.markupLabel(markup, css: "agent-text")
            if let marker = PangoMarkdown.hangingMarker(for: text) {
                tailscode_label_set_hanging_marker(label, marker)
            }
            return label
        case .codeBlock(let language, let body):
            return Self.codeBlock(language: language, body: body, key: key, context: context)
        case .linkRail(let urls):
            return LinkRailView.make(urls: urls, key: key, context: context)
        case .pictures(let pictures):
            return PictureGalleryView.make(pictures, context: context)
        case .table(let table):
            return Self.table(table, key: key)
        case .tableDraft(let draft):
            return TableView.draft(draft, key: key)
        case .reasoning(let text):
            return Self.reasoning(text, key: key, context: context)
        case .tool(let call):
            return ToolRowView.make(call, key: key, context: context)
        case .run(let steps):
            return ToolRowView.makeRun(steps, key: key, context: context)
        case .subagent(let call):
            return SubagentRowView.make(call, key: key, context: context)
        case .workflow(let call):
            return WorkflowCardView.make(call, key: key, context: context)
        case .file(let reference, let mine):
            return Self.filePart(reference, mine: mine, key: key, context: context)
        case .designBoard(let sighting):
            return Self.designBoard(sighting, context: context)
        case .taskBoard(let board):
            return TaskBoardView.make(board)
        case .compaction(let compaction):
            return Self.seam(compaction, key: key, context: context)
        case .answerless(let turn):
            return Self.answerless(turn, context: context)
        case .failed(let turn):
            return Self.failedTurn(turn, context: context)
        case .subagentGroup(let members):
            return SubagentRowView.makeGroup(members, key: key, context: context)
        case .responseStats(let stats):
            return Self.responseStats(stats)
        case .queuedSend(let row, let position, let total):
            return Self.queuedSend(row, position: position, of: total, context: context)
        case .queuePaused(let count):
            return Self.queuePaused(count: count, context: context)
        case .pendingSend(let send, let plan):
            return Self.pendingSend(send, plan: plan, context: context)
        case .interruptedTurn(let turn):
            return Self.interruptedTurn(turn, context: context)
        case .note(let line):
            return Self.note(line)
        case .providerRetry(let card):
            return Self.providerRetry(card)
        case .revertBanner(let banner, let restoring):
            return Self.revertBanner(banner, restoring: restoring, context: context)
        case .brain(let row):
            return BrainView.make(row, context: context)
        case .turnBreak:
            return Gtk.hairline()
        }
    }

    /// A user message's own actions, right-click, the way every other row in this app keeps them
    /// out of its face until asked for. Undo is the only one there is today; the anchor is the
    /// prompt's own widget, which outlives the popover a re-render never has reason to touch.
    static func prompt(
        _ text: String, messageID: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(rule, "prompt-rule")
        gtk_widget_set_size_request(rule, 2, -1)
        let label = Gtk.markupLabel(
            PangoMarkdown.plainWithLinks(text, accent: MatrixTheme.palette.accent),
            css: "prompt-text")
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), rule)
        gtk_box_append(ptr(row), label)
        let bits = UInt(bitPattern: row)
        Gtk.onRightClickCapture(row) { x, y in context.presentMessageMenu?(messageID, bits, x, y) }
        return row
    }

    /// Markdown as the transcript renders it — headings, emphasis, lists, links, fenced code with
    /// its own copy — for prose that lives outside the transcript: a compaction summary in the
    /// reader, where the CLI's own formatting is the only structure the text has.
    static func richBody(_ text: String, key: String = "rich") -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        let palette = MatrixTheme.palette
        for (index, segment) in MessageSegment.split(text).enumerated() {
            switch segment {
            case .prose(let prose):
                for chunk in paragraphChunks(prose) {
                    let markup = PangoMarkdown.render(
                        chunk, dim: palette.textDim, code: palette.info, accent: palette.accent)
                    gtk_box_append(ptr(column), Gtk.markupLabel(markup, css: "agent-text"))
                }
            case .code(let language, let body):
                gtk_box_append(
                    ptr(column),
                    codeBlock(language: language, body: body, key: "\(key):s\(index)", context: nil))
            case .table(let table):
                gtk_box_append(ptr(column), Self.table(table, key: "\(key):s\(index)"))
            }
        }
        return column
    }

    /// A pipe table, drawn by `TableView` — a card with a header band and washed rows, measured
    /// in pixels and fitted to the pane it is in.
    static func table(_ table: MarkdownTable, key: String) -> UnsafeMutablePointer<GtkWidget> {
        TableView.make(table, key: key)
    }

    /// Bounded labels: one Pango layout over forty thousand words takes a visible pause to
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
    /// under a long one a button naming the lines behind it. The language and the copy are not a
    /// header row spending a line on every block but a plate at the block's top trailing corner,
    /// shown while the pointer is over the block or focus is inside it. Opening grows the block in
    /// the page, so the transcript's own scroll carries it.
    static func codeBlock(
        language: String?, body: String, key: String, context: TranscriptContext?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = codeColumn(language: language, body: body, key: key, context: context)
        let wrap = gtk_overlay_new()!
        Gtk.addClass(wrap, "code-wrap")
        gtk_overlay_set_child(op(wrap), column)
        let plate = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(plate, "code-plate")
        gtk_widget_set_halign(plate, GTK_ALIGN_END)
        gtk_widget_set_valign(plate, GTK_ALIGN_START)
        let tag = Gtk.label(
            SyntaxHighlighter.displayName(for: language, source: body), css: "code-header",
            selectable: false)
        gtk_widget_set_valign(tag, GTK_ALIGN_CENTER)
        gtk_label_set_ellipsize(op(tag), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(plate), tag)
        gtk_box_append(ptr(plate), copyButton(body, toast: context?.toast))
        gtk_overlay_add_overlay(op(wrap), plate)
        return wrap
    }

    static func codeColumn(
        language: String?, body: String, key: String, context: TranscriptContext?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(column, "code-block")

        let foldKey = "\(key)#code"
        let state = FoldState(opened: context?.isExpanded(foldKey) ?? false)
        let fold = TranscriptBlocks.fold(body, expanded: state.opened)

        let gutter = Gtk.label(TranscriptBlocks.lineNumbers(fold), css: "code-gutter", selectable: false)
        gtk_label_set_xalign(op(gutter), 1)
        gtk_widget_set_valign(gutter, GTK_ALIGN_START)
        gtk_widget_set_visible(gutter, fold.totalLines > 1 ? 1 : 0)
        let text = Gtk.markupLabel(
            PangoSyntax.render(fold.shown, language: language, palette: MatrixTheme.palette),
            css: "code-body", wrap: false)
        gtk_widget_set_valign(text, GTK_ALIGN_START)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_propagate_natural_width(op(scroller), 0)
        gtk_scrolled_window_set_child(op(scroller), text)
        gtk_widget_set_hexpand(scroller, 1)
        Gtk.addClass(scroller, "code-scroll")
        let lines = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_box_append(ptr(lines), gutter)
        gtk_box_append(ptr(lines), scroller)
        gtk_box_append(ptr(column), lines)

        guard let title = fold.toggleLabel else { return column }
        let gutterBits = UInt(bitPattern: gutter)
        let textBits = UInt(bitPattern: text)
        let toggleSlot = Gtk.Slot()
        let onToggle = context?.onToggle
        let toggle = Gtk.button(title, css: ["flat", "code-fold"]) {
            state.opened.toggle()
            onToggle?(foldKey, state.opened)
            let fold = TranscriptBlocks.fold(body, expanded: state.opened)
            guard let gutter = UnsafeMutablePointer<GtkWidget>(bitPattern: gutterBits),
                let text = UnsafeMutablePointer<GtkWidget>(bitPattern: textBits),
                let toggle = UnsafeMutablePointer<GtkWidget>(bitPattern: toggleSlot.bits)
            else { return }
            gtk_label_set_text(op(gutter), TranscriptBlocks.lineNumbers(fold))
            gtk_label_set_markup(
                op(text),
                PangoSyntax.render(fold.shown, language: language, palette: MatrixTheme.palette))
            gtk_button_set_label(ptr(toggle), fold.toggleLabel)
        }
        toggleSlot.bits = UInt(bitPattern: toggle)
        gtk_widget_set_halign(toggle, GTK_ALIGN_START)
        gtk_box_append(ptr(column), toggle)
        return column
    }
}
