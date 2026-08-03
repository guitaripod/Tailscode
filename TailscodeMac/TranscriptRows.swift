import AppKit
import CodingAgentKit
import TailscodeCore

/// What a row needs from the transcript that is not in the row itself: which rows are open, the
/// pictures and subagent transcripts already fetched, and the callbacks that fetch more. Rows are
/// rebuilt freely; this survives them.
@MainActor
final class TranscriptContext {
    var expanded: Set<String> = []
    var subagentRows: [String: [TranscriptRow]] = [:]
    /// Live facts for the agents of the running fan-out, keyed by spawning tool-use id — what an
    /// inline agent card shows for progress while its transcript is still being written.
    var agentFacts: [String: SubagentSummary] = [:]
    var onToggle: ((String, Bool) -> Void)?
    var requestImage: ((FileReference, String) -> Void)?
    var requestSubagent: ((ToolCall) -> Void)?
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
        return TranscriptRow.compactTools ? TranscriptRow.fuse(all) : all
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
        case reasoning(String)
        case tool(ToolCall)
        case toolRun([ToolCall])
        case subagent(ToolCall)
        case file(FileReference)
        case compaction(Compaction)
        case turnBreak
    }

    let key: String
    let kind: Kind

    /// The same switch every desktop reads: an environment override for screenshots and headless
    /// runs, then the shared `tailscode.*` default.
    static var compactTools: Bool {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_COMPACT"] { return raw == "1" }
        return UserDefaults.standard.bool(forKey: "tailscode.compactTools")
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
                        key: key, kind: call.spawnsSubagent ? .subagent(call) : .tool(call)))
            case .file(let reference):
                rows.append(TranscriptRow(key: key, kind: .file(reference)))
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
        return compactTools ? fuse(all) : all
    }

    /// Compact mode: a run of ordinary tool calls collapses to one line. Twelve greps in a row are
    /// one fact — "it searched" — and spending twelve lines on them pushes the answer off the
    /// screen. The run keeps every call inside it, one click away, and anything that is not an
    /// ordinary tool call (an error, a subagent, a picture) never joins a run.
    static func fuse(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var fused: [TranscriptRow] = []
        var run: [ToolCall] = []
        var runKey = ""

        func flush() {
            guard !run.isEmpty else { return }
            if run.count == 1 {
                fused.append(TranscriptRow(key: runKey, kind: .tool(run[0])))
            } else {
                fused.append(TranscriptRow(key: "run:\(runKey)", kind: .toolRun(run)))
            }
            run = []
        }

        for row in rows {
            if case .tool(let call) = row.kind, call.status != .error, !call.asksUserQuestion {
                if run.isEmpty { runKey = row.key }
                run.append(call)
                continue
            }
            flush()
            fused.append(row)
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
        case .tool(let call), .subagent(let call):
            return Self.searchText(for: call)
        case .toolRun(let calls):
            return calls.map(Self.searchText(for:)).joined(separator: " ")
        case .file(let reference):
            return reference.filename ?? reference.path ?? ""
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
        case .reasoning(let text):
            return ToolRowView.reasoning(text, key: key, context: context)
        case .tool(let call):
            return ToolRowView.make(call, key: key, context: context)
        case .toolRun(let calls):
            return ToolRowView.makeRun(calls, key: key, context: context)
        case .subagent(let call):
            return SubagentRowView.make(call, key: key, context: context)
        case .file(let reference):
            return ImageRowView.make(reference, key: key, context: context)
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
            }
        }
        return column
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
        column.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        column.layer?.cornerRadius = 8

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = MacTheme.Spacing.s
        let tag = RowKit.label(
            language ?? "text", font: MacTheme.Font.caption(),
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

        let text = RowKit.wrapping(body, font: MacTheme.Font.mono(12), color: MacTheme.Color.label)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines > 18, body.count > 600 {
            column.addArrangedSubview(RowKit.heightCappedScroll(around: text, max: 320))
        } else {
            column.addArrangedSubview(text)
        }
        return column
    }

    /// A compaction is a seam, not a message: the rule says the transcript restarted here, the
    /// line says what was traded for what, and the CLI's machine-facing summary — tens of
    /// thousands of words — opens in a reader window rather than cramped into the flow.
    @MainActor
    private static func seam(
        _ compaction: Compaction, key: String, context: TranscriptContext
    ) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(RowKit.hairline())

        var facts: [String] = []
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            facts.append("\(StatusFacts.tokens(before)) → \(StatusFacts.tokens(after))")
        }
        if let duration = compaction.duration, duration > 0 {
            facts.append(StatusFacts.clock(duration))
        }
        if let kept = compaction.preservedMessageCount {
            facts.append(Localized.text("%@ messages kept", "\(kept)"))
        }
        if compaction.trigger == .auto { facts.append(Localized.text("automatic")) }
        let title = facts.isEmpty
            ? Localized.text("COMPACTED") : "COMPACTED · " + facts.joined(separator: " · ")
        let titleLabel = RowKit.label(
            title, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel)

        if let summary = compaction.summary, !summary.isEmpty {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = MacTheme.Spacing.s
            row.addArrangedSubview(titleLabel)
            let present = context.presentText
            row.addArrangedSubview(
                RowKit.linkButton(Localized.text("read summary")) {
                    present?(Localized.text("Compaction summary"), title, summary, false)
                })
            row.addArrangedSubview(RowKit.spacer())
            column.addArrangedSubview(row)
        } else {
            column.addArrangedSubview(titleLabel)
        }
        column.addArrangedSubview(RowKit.hairline())
        return column
    }
}

/// The small vocabulary every row view speaks: labels that wrap, labels that truncate, hairlines,
/// flat little buttons, capped scrolls — one place, so the rows stay about their content.
@MainActor
enum RowKit {
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
/// collapse hidden, so reopening is free.
@MainActor
final class DisclosureRow: NSView {
    private let stack = NSStackView()
    private let makeBody: () -> NSView
    private let onToggle: (Bool) -> Void
    private var body: NSView?

    init(
        header: NSView, expanded: Bool, onToggle: @escaping (Bool) -> Void,
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
            onToggle(!body.isHidden)
            return
        }
        reveal()
        onToggle(true)
    }

    private func reveal() {
        let built = makeBody()
        stack.addArrangedSubview(built)
        body = built
    }
}
