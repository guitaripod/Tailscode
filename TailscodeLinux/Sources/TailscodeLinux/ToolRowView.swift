import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A tool call as the CLIs draw one: a dense monospace line — glyph, name, what it touched, what
/// it cost — with the body behind a disclosure. An error opens itself, because a failure folded
/// away reads as success.
enum ToolRowView {
    static func make(_ call: ToolCall, key: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let summary = call.summary
        let header = headerLine(call, summary)
        guard hasBody(call, summary) else {
            Gtk.margins(header, leading: 6)
            return header
        }
        let expanded = call.status == .error || context.isExpanded(key)
        let toggle = context.onToggle
        return Gtk.disclosure(
            header: header, expanded: expanded, onToggle: { open in toggle?(key, open) }
        ) {
            let body = bodyColumn(call, summary, context: context)
                ?? Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.margins(body, leading: 26)
            return body
        }
    }

    /// A run of agent steps — thoughts and tool calls in the order they happened — as one line:
    /// what the tools were, how many, and the net diff, with the failures showing their glyph
    /// even when folded. Expanding in place opens the same rows compact mode folded away.
    static func makeRun(_ steps: [ActivityStep], key: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let calls = steps.compactMap { step -> ToolCall? in
            if case .tool(let call) = step { return call }
            return nil
        }
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let worst: ToolStatus = calls.contains { $0.status == .error }
            ? .error : calls.contains { $0.status == .running } ? .running : .completed
        gtk_box_append(
            ptr(header), mark(worst))
        gtk_box_append(
            ptr(header),
            Gtk.label(
                Localized.text("%@ tools", "\(calls.count)"), css: "tool-name", selectable: false))

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
        let label = Gtk.label(names, css: "tool-detail", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(header), label)

        let added = calls.compactMap { $0.summary.diffStats?.added }.reduce(0, +)
        let removed = calls.compactMap { $0.summary.diffStats?.removed }.reduce(0, +)
        if added > 0 {
            gtk_box_append(ptr(header), Gtk.label("+\(added)", css: "diff-add", selectable: false))
        }
        if removed > 0 {
            gtk_box_append(
                ptr(header), Gtk.label("−\(removed)", css: "diff-remove", selectable: false))
        }

        let toggle = context.onToggle
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open in toggle?(key, open) }
        ) {
            let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            Gtk.margins(body, leading: 16)
            for (index, step) in steps.enumerated() {
                switch step {
                case .reasoning(let text):
                    gtk_box_append(
                        ptr(body),
                        TranscriptRow.reasoning(text, key: "\(key):r\(index)", context: context))
                case .tool(let call):
                    gtk_box_append(
                        ptr(body), make(call, key: "\(key):\(index)", context: context))
                }
            }
            return body
        }
    }

    /// Whether the disclosure would open onto anything — decided without building a single body
    /// widget, because nearly every row is collapsed and its body must cost nothing until opened.
    private static func hasBody(_ call: ToolCall, _ summary: ToolCallSummary) -> Bool {
        if call.asksUserQuestion, !call.recordedAnswers.isEmpty { return true }
        if summary.kind == .shell, summary.command != nil { return true }
        if let path = summary.filePath ?? summary.detail, !path.isEmpty { return true }
        if !summary.links.isEmpty { return true }
        if ToolDiff.lines(for: call) != nil { return true }
        if let output = displayableOutput(call, summary), !output.isEmpty { return true }
        return false
    }

    static func headerLine(_ call: ToolCall, _ summary: ToolCallSummary)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(row), mark(call.status))
        gtk_box_append(ptr(row), Gtk.label(call.name, css: "tool-name", selectable: false))

        var detail = summary.title ?? call.title ?? ""
        if detail == call.name { detail = "" }
        if detail.isEmpty, let command = summary.command {
            detail = firstLine(command)
        }
        let label = Gtk.label(
            String(detail.replacingOccurrences(of: "\n", with: " ").prefix(140)),
            css: "tool-detail", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), label)

        if let stats = summary.diffStats {
            if stats.added > 0 {
                gtk_box_append(
                    ptr(row), Gtk.label("+\(stats.added)", css: "diff-add", selectable: false))
            }
            if stats.removed > 0 {
                gtk_box_append(
                    ptr(row), Gtk.label("−\(stats.removed)", css: "diff-remove", selectable: false))
            }
        } else if let metric = summary.metric {
            gtk_box_append(ptr(row), Gtk.label(metric, css: "tool-detail", selectable: false))
        }
        return row
    }

    /// What the disclosure opens onto, or nil when the line already says everything. The command
    /// line copies on a plain click while a drag still selects — the release only copies when
    /// nothing ended up selected, so both gestures keep their meaning.
    private static func bodyColumn(
        _ call: ToolCall, _ summary: ToolCallSummary, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget>? {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        var hasContent = false

        if call.asksUserQuestion {
            for answered in call.recordedAnswers {
                let line = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                gtk_box_append(
                    ptr(line), Gtk.label(answered.question, css: "tool-detail", wrap: true))
                gtk_box_append(
                    ptr(line), Gtk.label("→ \(answered.answer)", css: "tool-name", wrap: true))
                gtk_box_append(ptr(column), line)
                hasContent = true
            }
        }

        if summary.kind == .shell, let command = summary.command {
            let line = Gtk.label("$ \(command)", css: "code-body", wrap: true)
            Gtk.addClass(line, "command-line")
            gtk_widget_set_cursor_from_name(line, "copy")
            gtk_widget_set_tooltip_text(line, Localized.text("Click to copy"))
            let toast = context.toast
            let lineBits = UInt(bitPattern: line)
            Gtk.onRelease(line) {
                guard let raw = UnsafeMutableRawPointer(bitPattern: lineBits) else { return }
                let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
                guard tailscode_label_has_selection(widget) == 0 else { return }
                Gtk.copyToClipboard(command)
                toast?(Localized.text("Command copied"))
            }
            gtk_box_append(ptr(column), line)
            hasContent = true
        }

        if let path = summary.filePath ?? summary.detail, !path.isEmpty {
            gtk_box_append(ptr(column), Gtk.label(path, css: "tree-path", selectable: true))
            hasContent = true
        }

        for link in summary.links.prefix(6) {
            gtk_box_append(
                ptr(column),
                Gtk.label("· \(link.title)", css: "tool-detail", wrap: true))
            hasContent = true
        }

        if let diff = ToolDiff.lines(for: call) {
            gtk_box_append(ptr(column), diffBlock(diff, language: ToolDiff.language(for: call)))
            hasContent = true
        }

        if let output = displayableOutput(call, summary), !output.isEmpty {
            let label = Gtk.label(output, css: "tool-output", wrap: true)
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_max_content_height(op(scroller), 300)
            gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
            gtk_scrolled_window_set_child(op(scroller), label)
            gtk_box_append(ptr(column), scroller)
            if let full = fullOutput(call, summary), full.count > 1500 {
                let present = context.presentText
                let name = call.name
                let detail = summary.title ?? call.title
                let read = Gtk.button(
                    Localized.text("open full output"), css: ["flat", "seam-read"]
                ) {
                    present?(name, detail, full, true)
                }
                gtk_widget_set_halign(read, GTK_ALIGN_START)
                gtk_box_append(ptr(column), read)
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

    static func diffBlock(_ lines: [(prefix: String, text: String)], language: String?)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(block, "code-block")
        let palette = MatrixTheme.palette
        for line in lines.prefix(80) {
            let markup = PangoSyntax.diffLine(
                prefix: line.prefix, body: line.text,
                kind: line.prefix == "+" ? .added : .removed,
                language: language, palette: palette)
            let label = Gtk.markupLabel(markup, css: "diff-line", wrap: true)
            gtk_box_append(ptr(block), label)
        }
        if lines.count > 80 {
            gtk_box_append(
                ptr(block),
                Gtk.label(
                    Localized.text("… %@ more lines", "\(lines.count - 80)"), css: "dim",
                    selectable: false))
        }
        return block
    }

    /// The row's mark: a still glyph for work that is over, and the turning ring for work that is
    /// still out on the machine — the same ring the band shows, on the same clock, so a running
    /// row and the status above it turn together.
    static func mark(_ status: ToolStatus) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(glyph(status), css: glyphClass(status), selectable: false)
        ActivityPulse.apply(status.activityIcon, to: label)
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

    static func glyphClass(_ status: ToolStatus) -> String {
        switch status {
        case .completed: return "glyph-done"
        case .error: return "glyph-error"
        case .running: return "glyph-running"
        case .pending: return "glyph-pending"
        }
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "")
    }
}

/// A subagent is never its own chat: it renders inline at the tool call that spawned it, and
/// expanding it fetches the sidecar transcript into the same card.
enum SubagentRowView {
    static func make(_ call: ToolCall, key: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(header), ToolRowView.mark(call.status))
        gtk_box_append(ptr(header), Gtk.label("▸ agent", css: "tool-name", selectable: false))
        let title = call.summary.title ?? call.title ?? call.name
        let label = Gtk.label(
            String(title.replacingOccurrences(of: "\n", with: " ").prefix(140)),
            css: "tool-detail", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(header), label)
        if let live = context.agentFacts[call.id], live.isActive {
            gtk_box_append(
                ptr(header),
                Gtk.label(StatusFacts.liveDetail(live), css: "agent-live", selectable: false))
        } else if call.status == .completed {
            gtk_box_append(ptr(header), Gtk.label("done", css: "glyph-done", selectable: false))
        }

        let toggle = context.onToggle
        let request = context.requestSubagent
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open in
                toggle?(key, open)
                if open, context.subagentRows[call.id] == nil { request?(call) }
            }
        ) {
            let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            Gtk.addClass(body, "subagent-card")
            Gtk.margins(body, top: 4, bottom: 4, leading: 26, trailing: 4)
            if let rows = context.subagentRows[call.id] {
                if rows.isEmpty {
                    gtk_box_append(
                        ptr(body),
                        Gtk.label(
                            Localized.text("No transcript for this agent."), css: "dim",
                            selectable: false))
                }
                for row in rows.suffix(160) {
                    gtk_box_append(ptr(body), row.makeWidget(context: context))
                }
            } else {
                gtk_box_append(
                    ptr(body),
                    Gtk.label(
                        Localized.text("Loading transcript…"), css: "dim", selectable: false))
                if context.isExpanded(key) { context.requestSubagent?(call) }
            }
            return body
        }
    }
}
