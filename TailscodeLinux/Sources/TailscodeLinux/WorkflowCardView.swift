import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A workflow is a run, not a receipt. The Workflow tool answers the instant it hands the work to
/// the background, so the call itself has nothing left to say while four agents spend three minutes
/// on it — the card says it instead: what the run is, the phases its script declares, every agent
/// that has appeared and what it is doing, how far through the fan-out in hand it is, and how long
/// it has been going. The answer arrives later as its own message and is folded into the same card,
/// so a run reads as one thing from launch to result.
enum WorkflowCardView {
    static func make(_ call: ToolCall, key: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let run = context.workflowRuns[call.id]
        let now = context.workflowNow
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(header), Gtk.label(glyph(run, now), css: glyphClass(run), selectable: false))
        gtk_box_append(ptr(header), Gtk.label("▸ workflow", css: "tool-name", selectable: false))

        let name = run?.name ?? call.summary.title ?? Localized.text("Workflow")
        let title = Gtk.label(name, css: "workflow-name", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(header), title)

        if let run {
            gtk_box_append(
                ptr(header),
                Gtk.label(run.headline(at: now), css: headlineClass(run), selectable: false))
            if let elapsed = run.elapsed(at: now) {
                gtk_box_append(
                    ptr(header),
                    Gtk.label(WorkflowRun.duration(elapsed), css: "workflow-elapsed", selectable: false))
            }
        }

        let toggle = context.onToggle
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open in toggle?(key, open) }
        ) {
            body(run, call: call, context: context, now: now)
        }
    }

    private static func body(
        _ run: WorkflowRun?, call: ToolCall, context: TranscriptContext, now: Date
    ) -> UnsafeMutablePointer<GtkWidget> {
        let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(body, "workflow-card")
        Gtk.margins(body, top: 4, bottom: 4, leading: 26, trailing: 4)
        guard let run else {
            gtk_box_append(
                ptr(body),
                Gtk.label(Localized.text("Starting…"), css: "dim", selectable: false))
            return body
        }

        if let summary = run.summary {
            let label = Gtk.label(summary, css: "workflow-summary", wrap: true, selectable: false)
            gtk_widget_set_halign(label, GTK_ALIGN_START)
            gtk_box_append(ptr(body), label)
        }
        gtk_box_append(ptr(body), meter(run))
        if !run.phases.isEmpty { gtk_box_append(ptr(body), phaseRail(run)) }
        if !run.agents.isEmpty { gtk_box_append(ptr(body), agentList(run, context: context, now: now)) }
        if let result = run.result, !result.isEmpty {
            gtk_box_append(ptr(body), Gtk.hairline())
            gtk_box_append(ptr(body), answer(result, name: run.name, context: context))
        }
        return body
    }

    /// Progress over the agents in hand. A run never promises how many it will spawn, so the meter
    /// is labelled with what it actually counts rather than implying a total nobody has stated.
    private static func meter(_ run: WorkflowRun) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let slots = 18
        let filled = Int((Double(slots) * run.progress).rounded())
        let bar = String(repeating: "▰", count: filled) + String(repeating: "▱", count: slots - filled)
        gtk_box_append(
            ptr(row),
            Gtk.label(bar, css: run.isLive ? "workflow-meter-live" : "workflow-meter", selectable: false))
        let caption =
            run.agents.isEmpty
            ? Localized.text("no agents yet")
            : Localized.text("%@ of %@ agents", "\(run.doneCount)", "\(run.agents.count)")
        gtk_box_append(ptr(row), Gtk.label(caption, css: "dim", selectable: false))
        return row
    }

    /// The phases the script declares, as the plan it is. Which phase an agent belongs to is only
    /// recorded by a finished run, so a live card never points at one — claiming a position the
    /// data cannot support is worse than showing the plan and the agents separately.
    private static func phaseRail(_ run: WorkflowRun) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        let done = !run.isLive
        for phase in run.phases {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let marker = phase.index == run.phases.count - 1 ? "└" : "├"
            gtk_box_append(
                ptr(row),
                Gtk.label(
                    "\(marker) \(done ? "▰" : "▱")", css: done ? "workflow-phase-done" : "workflow-phase",
                    selectable: false))
            gtk_box_append(ptr(row), Gtk.label(phase.title, css: "workflow-phase-title", selectable: false))
            if let detail = phase.detail {
                let label = Gtk.label(detail, css: "dim", selectable: false)
                gtk_widget_set_hexpand(label, 1)
                gtk_widget_set_halign(label, GTK_ALIGN_START)
                gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
                gtk_box_append(ptr(row), label)
            }
            if let model = phase.model {
                gtk_box_append(
                    ptr(row),
                    Gtk.label(shortModel(model), css: "workflow-model", selectable: false))
            }
            gtk_box_append(ptr(column), row)
        }
        return column
    }

    private static func agentList(_ run: WorkflowRun, context: TranscriptContext, now: Date)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        for agent in run.agents {
            gtk_box_append(ptr(column), agentRow(agent, run: run, context: context, now: now))
        }
        return column
    }

    /// One agent, openable in place: its own sidecar transcript is fetched on demand and rendered
    /// with the same rows as any other conversation, because a workflow agent is never its own chat.
    private static func agentRow(
        _ agent: WorkflowAgent, run: WorkflowRun, context: TranscriptContext, now: Date
    ) -> UnsafeMutablePointer<GtkWidget> {
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(header),
            Gtk.label(
                agentGlyph(agent, now: now), css: agentGlyphClass(agent), selectable: false))
        let title = Gtk.label(
            String(agent.title.replacingOccurrences(of: "\n", with: " ").prefix(120)),
            css: "tool-detail", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(header), title)
        if agent.isActive, let tool = agent.currentTool {
            gtk_box_append(ptr(header), Gtk.label(tool, css: "agent-live", selectable: false))
        }
        if let elapsed = agent.elapsed(at: now) {
            gtk_box_append(
                ptr(header),
                Gtk.label(WorkflowRun.duration(elapsed), css: "workflow-elapsed", selectable: false))
        }

        let key = "wf:\(run.id):\(agent.id)"
        let rowKey = WorkflowAgentRows.key(agent.id)
        let toggle = context.onToggle
        let request = context.requestWorkflowAgent
        let agentID = agent.id
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open in
                toggle?(key, open)
                if open, context.subagentRows[rowKey] == nil { request?(agentID) }
            }
        ) {
            let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            Gtk.addClass(body, "subagent-card")
            Gtk.margins(body, top: 4, bottom: 4, leading: 20, trailing: 4)
            if let rows = context.subagentRows[rowKey] {
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
                    Gtk.label(Localized.text("Loading transcript…"), css: "dim", selectable: false))
                if context.isExpanded(key) { context.requestWorkflowAgent?(agentID) }
            }
            return body
        }
    }

    /// The run's answer, in the card that started it. Long answers stay behind a reader rather than
    /// unrolling thousands of words inside a tool row.
    private static func answer(_ result: String, name: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let palette = MatrixTheme.palette
        let preview = result.count > 1200 ? String(result.prefix(1200)) + "…" : result
        let label = Gtk.markupLabel(
            PangoMarkdown.render(
                preview, dim: palette.textDim, code: palette.info, accent: palette.accent),
            css: "workflow-answer")
        gtk_label_set_wrap(op(label), 1)
        gtk_widget_set_halign(label, GTK_ALIGN_START)
        gtk_box_append(ptr(column), label)
        if result.count > 1200 {
            let present = context.presentText
            let button = Gtk.button(Localized.text("Read the whole answer"), css: ["seam-read"]) {
                present?(name, nil, result, false)
            }
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_box_append(ptr(column), button)
        }
        return column
    }

    /// A phase's model as a badge: the family, without the vendor prefix or the dated build that
    /// makes every badge the same width and none of them readable.
    private static func shortModel(_ model: String) -> String {
        var name = model
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        let parts = name.split(separator: "-")
        let keep = parts.prefix { Int($0) == nil || $0.count < 3 }
        return keep.isEmpty ? name : keep.joined(separator: "-")
    }

    private static let spinner = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]

    private static func frame(_ now: Date) -> String {
        spinner[Int(now.timeIntervalSince1970) % spinner.count]
    }

    private static func glyph(_ run: WorkflowRun?, _ now: Date) -> String {
        guard let run else { return "○" }
        switch run.state {
        case .launching, .running: return frame(now)
        case .finished: return "⏺"
        case .failed: return "✗"
        }
    }

    private static func glyphClass(_ run: WorkflowRun?) -> String {
        guard let run else { return "glyph-pending" }
        switch run.state {
        case .launching, .running: return "glyph-running"
        case .finished: return "glyph-done"
        case .failed: return "glyph-error"
        }
    }

    private static func headlineClass(_ run: WorkflowRun) -> String {
        switch run.state {
        case .launching, .running: return "agent-live"
        case .finished: return "dim"
        case .failed: return "glyph-error"
        }
    }

    private static func agentGlyph(_ agent: WorkflowAgent, now: Date) -> String {
        if agent.isCompleted { return "✓" }
        return agent.isActive ? frame(now) : "○"
    }

    private static func agentGlyphClass(_ agent: WorkflowAgent) -> String {
        if agent.isCompleted { return "glyph-done" }
        return agent.isActive ? "glyph-running" : "glyph-pending"
    }
}

/// Workflow agents have no spawning tool call, so their fetched transcripts are keyed by agent id
/// in the same store the spawned ones use — one namespace, no collision with a tool-use id.
enum WorkflowAgentRows {
    static func key(_ agentID: String) -> String { "workflow-agent:\(agentID)" }
}
