import AppKit
import CodingAgentKit
import TailscodeCore

/// A tool call as the CLIs draw one: a dense monospace line — glyph, name, what it touched, what
/// it cost — with the body behind a disclosure. An error opens itself, because a failure folded
/// away reads as success.
@MainActor
enum ToolRowView {
    static func make(_ call: ToolCall, key: String, context: TranscriptContext) -> NSView {
        let summary = call.summary
        let header = headerLine(call, summary)
        guard hasBody(call, summary) else {
            return RowKit.inset(header, leading: 6)
        }
        let expanded = call.status == .error || context.isExpanded(key)
        let toggle = context.onToggle
        let reveal = context.revealRow
        return DisclosureRow(
            header: header, expanded: expanded,
            onToggle: { open, row in
                toggle?(key, open)
                if open { reveal?(row) }
            }
        ) {
            RowKit.inset(bodyColumn(call, summary, context: context) ?? NSView(), leading: 26)
        }
    }

    /// A run of agent steps — thoughts and tool calls in the order they happened — as one line:
    /// what the tools were, how many, and the net diff, with the failures showing their glyph
    /// even when folded. Expanding in place opens the same rows compact mode folded away.
    static func makeRun(_ steps: [ActivityStep], key: String, context: TranscriptContext) -> NSView {
        let calls = steps.compactMap { step -> ToolCall? in
            if case .tool(let call) = step { return call }
            return nil
        }
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = MacTheme.Spacing.s
        let worst: ToolStatus =
            calls.contains { $0.status == .error }
            ? .error : calls.contains { $0.status == .running } ? .running : .completed
        header.addArrangedSubview(glyphLabel(worst))
        header.addArrangedSubview(
            RowKit.label(
                Localized.text("%@ tools", "\(calls.count)"), font: MacTheme.Ramp.font(.code),
                color: MacTheme.Color.label))

        var tally: [(String, Int)] = []
        for call in calls {
            if let index = tally.firstIndex(where: { $0.0 == call.name }) {
                tally[index].1 += 1
            } else {
                tally.append((call.name, 1))
            }
        }
        let names = tally.prefix(6).map { $0.1 > 1 ? "\($0.0)×\($0.1)" : $0.0 }
            .joined(separator: " ")
        header.addArrangedSubview(detailLabel(names))

        let added = calls.compactMap { $0.summary.diffStats?.added }.reduce(0, +)
        let removed = calls.compactMap { $0.summary.diffStats?.removed }.reduce(0, +)
        if added > 0 {
            header.addArrangedSubview(
                RowKit.label(
                    "+\(added)", font: MacTheme.Ramp.font(.toolOutput), color: MacTheme.Color.success))
        }
        if removed > 0 {
            header.addArrangedSubview(
                RowKit.label(
                    "−\(removed)", font: MacTheme.Ramp.font(.toolOutput), color: MacTheme.Color.danger))
        }

        let toggle = context.onToggle
        let reveal = context.revealRow
        return DisclosureRow(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open, row in
                toggle?(key, open)
                if open { reveal?(row) }
            }
        ) {
            let body = NSStackView()
            body.orientation = .vertical
            body.alignment = .width
            body.spacing = 2
            body.translatesAutoresizingMaskIntoConstraints = false
            for (index, step) in steps.enumerated() {
                switch step {
                case .reasoning(let text):
                    body.addArrangedSubview(
                        reasoning(text, key: "\(key):r\(index)", context: context))
                case .tool(let call):
                    body.addArrangedSubview(make(call, key: "\(key):\(index)", context: context))
                }
            }
            return RowKit.inset(body, leading: 16)
        }
    }

    /// Reasoning folded to its size, because the thought is the agent's scratch work: worth a
    /// glance, never worth the screen the answer needs.
    static func reasoning(_ text: String, key: String, context: TranscriptContext) -> NSView {
        context.liveReasoning[key] = text
        let header = RowKit.label(
            Self.thoughtHeader(text), font: MacTheme.Ramp.font(.panelFootnote),
            color: MacTheme.Color.secondaryLabel)
        let toggle = context.onToggle
        let reveal = context.revealRow
        return DisclosureRow(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open, row in
                toggle?(key, open)
                if open { reveal?(row) }
            }
        ) { [weak context] in
            RowKit.inset(
                RowKit.wrapping(
                    context?.liveReasoning[key] ?? text, font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel),
                leading: 14)
        }
    }

    static func thoughtHeader(_ text: String) -> String {
        Localized.text("⌄ Thought · %@ words", "\(text.split(separator: " ").count)")
    }

    /// Whether the disclosure would open onto anything — decided without building a single body
    /// view, because nearly every row is collapsed and its body must cost nothing until opened.
    private static func hasBody(_ call: ToolCall, _ summary: ToolCallSummary) -> Bool {
        if call.asksUserQuestion, !call.recordedAnswers.isEmpty { return true }
        if summary.kind == .shell, summary.command != nil { return true }
        if let path = summary.filePath ?? summary.detail, !path.isEmpty { return true }
        if !summary.links.isEmpty { return true }
        if ToolDiff.lines(for: call) != nil { return true }
        if let output = displayableOutput(call, summary), !output.isEmpty { return true }
        return false
    }

    static func headerLine(_ call: ToolCall, _ summary: ToolCallSummary) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        row.addArrangedSubview(glyphLabel(call.status))
        row.addArrangedSubview(
            RowKit.label(call.name, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.label))

        var detail = summary.title ?? call.title ?? ""
        if detail == call.name { detail = "" }
        if detail.isEmpty, let command = summary.command {
            detail = firstLine(command)
        }
        row.addArrangedSubview(
            detailLabel(String(detail.replacingOccurrences(of: "\n", with: " ").prefix(140))))

        if let stats = summary.diffStats {
            if stats.added > 0 {
                row.addArrangedSubview(
                    RowKit.label(
                        "+\(stats.added)", font: MacTheme.Ramp.font(.toolOutput),
                        color: MacTheme.Color.success))
            }
            if stats.removed > 0 {
                row.addArrangedSubview(
                    RowKit.label(
                        "−\(stats.removed)", font: MacTheme.Ramp.font(.toolOutput),
                        color: MacTheme.Color.danger))
            }
        } else if let metric = summary.metric {
            row.addArrangedSubview(
                RowKit.label(
                    metric, font: MacTheme.Ramp.font(.toolOutput), color: MacTheme.Color.secondaryLabel))
        }
        return row
    }

    /// What the disclosure opens onto, or nil when the line already says everything.
    private static func bodyColumn(
        _ call: ToolCall, _ summary: ToolCallSummary, context: TranscriptContext
    ) -> NSView? {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        var hasContent = false

        if call.asksUserQuestion {
            for answered in call.recordedAnswers {
                let line = NSStackView()
                line.orientation = .vertical
                line.alignment = .width
                line.spacing = 0
                line.addArrangedSubview(
                    RowKit.wrapping(
                        answered.question, font: MacTheme.Ramp.font(.toolOutput),
                        color: MacTheme.Color.secondaryLabel))
                line.addArrangedSubview(
                    RowKit.wrapping(
                        "→ \(answered.answer)", font: MacTheme.Ramp.font(.code),
                        color: MacTheme.Color.label))
                column.addArrangedSubview(line)
                hasContent = true
            }
        }

        if summary.kind == .shell, let command = summary.command {
            let toast = context.toast
            let line = ClickToCopyLabel(text: "$ \(command)") {
                RowKit.copyToClipboard(command)
                toast?(Localized.text("Command copied"))
            }
            column.addArrangedSubview(line)
            hasContent = true
        }

        if let path = summary.filePath ?? summary.detail, !path.isEmpty {
            column.addArrangedSubview(
                RowKit.wrapping(
                    path, font: MacTheme.Ramp.font(.toolOutput), color: MacTheme.Color.secondaryLabel))
            hasContent = true
        }

        for link in summary.links.prefix(6) {
            column.addArrangedSubview(
                RowKit.wrapping(
                    "· \(link.title)", font: MacTheme.Ramp.font(.toolOutput),
                    color: MacTheme.Color.secondaryLabel))
            hasContent = true
        }

        if let diff = ToolDiff.lines(for: call) {
            column.addArrangedSubview(diffBlock(diff, language: ToolDiff.language(for: call)))
            hasContent = true
        }

        if let output = displayableOutput(call, summary), !output.isEmpty {
            let label = RowKit.wrapping(
                output, font: MacTheme.Ramp.font(.toolOutput), color: MacTheme.Color.secondaryLabel)
            column.addArrangedSubview(RowKit.heightCappedScroll(around: label, max: 300))
            if let full = fullOutput(call, summary), full.count > 1500 {
                let present = context.presentText
                let name = call.name
                let detail = summary.title ?? call.title
                let read = RowKit.linkButton(Localized.text("open full output")) {
                    present?(name, detail, full, true)
                }
                let row = NSStackView(views: [read, RowKit.spacer()])
                row.orientation = .horizontal
                column.addArrangedSubview(row)
            }
            hasContent = true
        }

        return hasContent ? column : nil
    }

    private static func fullOutput(_ call: ToolCall, _ summary: ToolCallSummary) -> String? {
        call.status == .error ? call.sanitizedOutput : summary.displayOutput
    }

    private static func displayableOutput(_ call: ToolCall, _ summary: ToolCallSummary) -> String? {
        if call.status == .error {
            return call.sanitizedOutput.map { String($0.prefix(4000)) }
        }
        return summary.displayOutput.map { String($0.prefix(4000)) }
    }

    /// An Edit rendered the way a reviewer reads it: washed added/removed lines carrying the
    /// file's own syntax — the same treatment a fenced patch gets — cut at eighty lines with the
    /// remainder counted rather than drawn.
    static func diffBlock(_ lines: [(prefix: String, text: String)], language: String?) -> NSView {
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .width
        block.spacing = 0
        block.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        block.translatesAutoresizingMaskIntoConstraints = false
        block.wantsLayer = true
        block.layer?.backgroundColor = MacTheme.Color.codeBackground.cgColor
        block.layer?.cornerRadius = 8
        for line in lines.prefix(80) {
            let text = RowKit.diffAttributed(
                "\(line.prefix) \(line.text)", language: language, font: MacTheme.Ramp.font(.toolOutput))
            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = text
            label.isSelectable = true
            label.drawsBackground = true
            label.backgroundColor = MacTheme.Color.diffBackground(
                line.prefix == "+" ? .added : .removed)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            block.addArrangedSubview(label)
        }
        if lines.count > 80 {
            block.addArrangedSubview(
                RowKit.label(
                    Localized.text("… %@ more lines", "\(lines.count - 80)"),
                    font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        return block
    }

    /// The row's mark: still for work that is over, turning for work still out on the machine —
    /// the same ring the status band turns, on the same clock.
    static func glyphLabel(_ status: ToolStatus) -> NSTextField {
        let label = ActivityMarkLabel(frame: .zero)
        label.stringValue = glyph(status)
        label.font = MacTheme.Ramp.font(.toolOutput)
        label.textColor = tint(status)
        label.mark(status.activityIcon)
        return label
    }

    static func glyph(_ status: ToolStatus) -> String {
        switch status {
        case .completed: return "⏺"
        case .error: return "✗"
        case .running: return "◐"
        case .pending: return "○"
        }
    }

    static func tint(_ status: ToolStatus) -> NSColor {
        switch status {
        case .completed: return MacTheme.Color.success
        case .error: return MacTheme.Color.danger
        case .running: return MacTheme.Color.accent
        case .pending: return MacTheme.Color.tertiaryLabel
        }
    }

    /// The middle column of a dense line: truncates from the middle and soaks up the width the
    /// glyph and the stats do not need.
    static func detailLabel(_ text: String) -> NSTextField {
        let label = RowKit.label(
            text, font: MacTheme.Ramp.font(.toolOutput), color: MacTheme.Color.secondaryLabel)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        label.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        return label
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "")
    }
}

/// A command line that copies itself on a plain click while a drag still selects — both gestures
/// keep their meaning, and the tooltip says which one is on offer.
@MainActor
final class ClickToCopyLabel: NSTextField {
    private let onCopy: () -> Void

    init(text: String, onCopy: @escaping () -> Void) {
        self.onCopy = onCopy
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = true
        font = MacTheme.Ramp.font(.code)
        textColor = MacTheme.Color.label
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byCharWrapping
        maximumNumberOfLines = 0
        toolTip = Localized.text("Click to copy")
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        DispatchQueue.main.async { [weak self] in
            guard let self, (self.currentEditor()?.selectedRange.length ?? 0) == 0 else { return }
            self.onCopy()
        }
    }
}

/// A subagent is never its own chat: it renders inline at the tool call that spawned it, and
/// expanding it fetches the sidecar transcript into the same card.
@MainActor
enum SubagentRowView {
    static func make(_ call: ToolCall, key: String, context: TranscriptContext) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = MacTheme.Spacing.s
        header.addArrangedSubview(ToolRowView.glyphLabel(call.status))
        header.addArrangedSubview(
            RowKit.label("▸ agent", font: MacTheme.Ramp.font(.code), color: MacTheme.Color.label))
        let title = call.summary.title ?? call.title ?? call.name
        header.addArrangedSubview(
            ToolRowView.detailLabel(
                String(title.replacingOccurrences(of: "\n", with: " ").prefix(140))))
        if let live = context.agentFacts[call.id], live.isActive {
            header.addArrangedSubview(
                RowKit.label(
                    StatusFacts.liveDetail(live), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.accent))
        } else if call.status == .completed {
            header.addArrangedSubview(
                RowKit.label(
                    Localized.text("done"), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.success))
        }

        let toggle = context.onToggle
        let reveal = context.revealRow
        let request = context.requestSubagent
        return DisclosureRow(
            header: header, expanded: context.isExpanded(key),
            onToggle: { [weak context] open, row in
                toggle?(key, open)
                if open { reveal?(row) }
                if open, context?.subagentRows[call.id] == nil { request?(call) }
            }
        ) { [weak context] in
            let body = NSStackView()
            body.orientation = .vertical
            body.alignment = .width
            body.spacing = 6
            body.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            body.translatesAutoresizingMaskIntoConstraints = false
            body.wantsLayer = true
            body.layer?.backgroundColor = MacTheme.Color.subagentBackground.cgColor
            body.layer?.cornerRadius = MacTheme.Radius.control
            guard let context else { return RowKit.inset(body, leading: 26) }
            if let rows = context.subagentRows[call.id] {
                if rows.isEmpty {
                    body.addArrangedSubview(
                        RowKit.label(
                            Localized.text("No transcript for this agent."),
                            font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
                }
                for row in rows.suffix(160) {
                    body.addArrangedSubview(row.makeView(context: context))
                }
            } else {
                body.addArrangedSubview(
                    RowKit.label(
                        Localized.text("Loading transcript…"), font: MacTheme.Ramp.font(.panelFootnote),
                        color: MacTheme.Color.tertiaryLabel))
                if context.isExpanded(key) { context.requestSubagent?(call) }
            }
            return RowKit.inset(body, leading: 26)
        }
    }
}
