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
///
/// A live card is a clock, and a clock must not be a demolition: the once-a-second tick is written
/// into the labels the card already has (``restate``), never by tearing the widget down — a card
/// rebuilt under the pointer eats the click that was in flight and rebuilds an opened agent
/// transcript nobody asked to pay for again. Every label whose text comes and goes is created up
/// front and hidden while empty, so the tick only ever changes words, and the widget tree stays
/// the shape ``restate`` expects for as long as the run's structure holds. Only a structural
/// change — an agent appearing, the result landing — earns a rebuild.
enum WorkflowCardView {
    static func make(_ call: ToolCall, key: String, context: TranscriptContext)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let run = context.workflowRuns[call.id]
        let now = context.workflowNow
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let icon = mark(run)
        let markLabel = Gtk.label(icon.glyph, css: icon.glyphCSS, selectable: false)
        applyMark(icon, to: markLabel)
        gtk_box_append(ptr(header), markLabel)
        gtk_box_append(ptr(header), Gtk.label("▸ workflow", css: "tool-name", selectable: false))

        let name = run?.name ?? call.summary.title ?? Localized.text("Workflow")
        let title = Gtk.label(name, css: "workflow-name", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_box_append(ptr(header), title)

        let headline = Gtk.label(
            run.map { $0.headline(at: now) } ?? "",
            css: run.map(headlineClass) ?? "dim", selectable: false)
        gtk_widget_set_visible(headline, run == nil ? 0 : 1)
        gtk_box_append(ptr(header), headline)
        let elapsed = Gtk.label(
            (run?.elapsed(at: now)).map(WorkflowRun.duration) ?? "",
            css: "workflow-elapsed", selectable: false)
        gtk_widget_set_visible(elapsed, run?.elapsed(at: now) == nil ? 0 : 1)
        gtk_box_append(ptr(header), elapsed)

        let toggle = context.onToggle
        let reveal = context.revealRow
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open, bits in
                toggle?(key, open)
                if open { reveal?(bits) }
            }
        ) {
            body(run, call: call, context: context, now: now)
        }
    }

    /// The card restated in place from the run it already shows: spinner frame, headline, elapsed
    /// readings, meter fill, phase marks, each agent's glyph and current tool. False the moment the
    /// widget's structure no longer matches the run — a new agent, the result arriving, a card
    /// built before its run existed — which is the caller's cue to rebuild this one card whole.
    static func restate(
        _ widget: UnsafeMutablePointer<GtkWidget>, call: ToolCall, context: TranscriptContext
    ) -> Bool {
        let run = context.workflowRuns[call.id]
        let now = context.workflowNow
        guard let button = gtk_widget_get_first_child(widget),
            isA(button, gtk_button_get_type()),
            let header = Gtk.disclosureHeader(button)
        else { return false }
        let head = children(of: header)
        guard head.count == 5 else { return false }
        let icon = mark(run)
        applyMark(icon, to: head[0])
        setExclusiveClass(head[0], among: Self.glyphClasses, to: icon.glyphCSS)
        setLabel(head[3], text: run.map { $0.headline(at: now) } ?? "")
        setExclusiveClass(head[3], among: Self.headlineClasses, to: run.map(headlineClass) ?? "dim")
        gtk_widget_set_visible(head[3], run == nil ? 0 : 1)
        let elapsed = run?.elapsed(at: now)
        setLabel(head[4], text: elapsed.map(WorkflowRun.duration) ?? "")
        gtk_widget_set_visible(head[4], elapsed == nil ? 0 : 1)

        guard let body = gtk_widget_get_next_sibling(button) else { return true }
        guard let run else { return true }
        let sections = children(of: body)
        func section(_ css: String) -> UnsafeMutablePointer<GtkWidget>? {
            sections.first { gtk_widget_has_css_class($0, css) != 0 }
        }
        guard let meterRow = section("workflow-meter-row") else { return false }

        let summary = section("workflow-summary")
        guard (summary != nil) == (run.summary != nil) else { return false }
        if let summary, let text = run.summary { setLabel(summary, text: text) }

        let meter = children(of: meterRow)
        guard meter.count == 2 else { return false }
        setLabel(meter[0], text: meterBar(run))
        setExclusiveClass(
            meter[0], among: ["workflow-meter-live", "workflow-meter"],
            to: run.isLive ? "workflow-meter-live" : "workflow-meter")
        setLabel(meter[1], text: meterCaption(run))

        let phases = section("workflow-phases")
        guard (phases != nil) == !run.phases.isEmpty else { return false }
        if let phases {
            let rows = children(of: phases)
            guard rows.count == run.phases.count else { return false }
            let standing = run.phaseStanding
            for (row, phase) in zip(rows, run.phases) {
                guard let marker = gtk_widget_get_first_child(row) else { return false }
                setLabel(marker, text: phaseMark(phase, of: run.phases.count, standing: standing))
                setExclusiveClass(marker, among: Self.phaseClasses, to: standing.css)
                gtk_widget_set_tooltip_text(marker, standing.spoken)
            }
        }

        let agents = section("workflow-agents")
        guard (agents != nil) == !run.agents.isEmpty else { return false }
        if let agents {
            let rows = children(of: agents)
            guard rows.count == run.agents.count else { return false }
            for (row, agent) in zip(rows, run.agents) {
                guard restateAgent(row, agent: agent, in: run, now: now) else { return false }
            }
        }

        let hasAnswer = !(run.result ?? "").isEmpty
        guard (section("workflow-answer-col") != nil) == hasAnswer else { return false }
        return true
    }

    private static func restateAgent(
        _ row: UnsafeMutablePointer<GtkWidget>, agent: WorkflowAgent, in run: WorkflowRun, now: Date
    ) -> Bool {
        guard let button = gtk_widget_get_first_child(row),
            isA(button, gtk_button_get_type()),
            let header = Gtk.disclosureHeader(button)
        else { return false }
        let head = children(of: header)
        guard head.count == 4 else { return false }
        let icon = ActivityIcon.workflowAgent(agent, in: run)
        applyMark(icon, to: head[0])
        setExclusiveClass(head[0], among: Self.glyphClasses, to: icon.glyphCSS)
        let tool = liveTool(agent, wearing: icon)
        setLabel(head[2], text: tool ?? "")
        gtk_widget_set_visible(head[2], tool == nil ? 0 : 1)
        let elapsed = agent.elapsed(at: now)
        setLabel(head[3], text: elapsed.map(WorkflowRun.duration) ?? "")
        gtk_widget_set_visible(head[3], elapsed == nil ? 0 : 1)
        return true
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
        Gtk.addClass(row, "workflow-meter-row")
        gtk_box_append(
            ptr(row),
            Gtk.label(
                meterBar(run), css: run.isLive ? "workflow-meter-live" : "workflow-meter",
                selectable: false))
        gtk_box_append(ptr(row), Gtk.label(meterCaption(run), css: "dim", selectable: false))
        return row
    }

    private static func meterBar(_ run: WorkflowRun) -> String {
        let slots = 18
        let filled = Int((Double(slots) * run.progress).rounded())
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: slots - filled)
    }

    private static func meterCaption(_ run: WorkflowRun) -> String {
        run.agents.isEmpty
            ? Localized.text("no agents yet")
            : Localized.text("%@ of %@ agents", "\(run.doneCount)", "\(run.agents.count)")
    }

    /// The phases the script declares, as the plan it is. Which phase an agent belongs to is only
    /// recorded by a finished run, so a live card never points at one — claiming a position the
    /// data cannot support is worse than showing the plan and the agents separately.
    ///
    /// Whether the plan may be claimed to have happened is ``WorkflowRun/phaseStanding``'s to say,
    /// never this card's: a run being over is not a run having got through its phases, and a
    /// four-phase script killed inside phase one drawn as four filled phases is completed work the
    /// transcript never recorded.
    private static func phaseRail(_ run: WorkflowRun) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        Gtk.addClass(column, "workflow-phases")
        let standing = run.phaseStanding
        for phase in run.phases {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let marker = Gtk.label(
                phaseMark(phase, of: run.phases.count, standing: standing),
                css: standing.css, selectable: false)
            gtk_widget_set_tooltip_text(marker, standing.spoken)
            gtk_box_append(ptr(row), marker)
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

    private static func phaseMark(
        _ phase: WorkflowPhase, of count: Int, standing: WorkflowPhaseStanding
    ) -> String {
        "\(phase.index == count - 1 ? "└" : "├") \(standing.glyph)"
    }

    private static func agentList(_ run: WorkflowRun, context: TranscriptContext, now: Date)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        Gtk.addClass(column, "workflow-agents")
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
        let icon = ActivityIcon.workflowAgent(agent, in: run)
        let glyph = Gtk.label(icon.glyph, css: icon.glyphCSS, selectable: false)
        applyMark(icon, to: glyph)
        gtk_box_append(ptr(header), glyph)
        let title = Gtk.label(
            String(agent.title.replacingOccurrences(of: "\n", with: " ").prefix(120)),
            css: "tool-detail", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(header), title)
        let working = liveTool(agent, wearing: icon)
        let tool = Gtk.label(working ?? "", css: "agent-live", selectable: false)
        gtk_widget_set_visible(tool, working == nil ? 0 : 1)
        gtk_box_append(ptr(header), tool)
        let elapsed = Gtk.label(
            agent.elapsed(at: now).map(WorkflowRun.duration) ?? "",
            css: "workflow-elapsed", selectable: false)
        gtk_widget_set_visible(elapsed, agent.elapsed(at: now) == nil ? 0 : 1)
        gtk_box_append(ptr(header), elapsed)

        let key = "wf:\(run.id):\(agent.id)"
        let rowKey = WorkflowAgentRows.key(agent.id)
        let toggle = context.onToggle
        let reveal = context.revealRow
        let request = context.requestWorkflowAgent
        let agentID = agent.id
        return Gtk.disclosure(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open, bits in
                toggle?(key, open)
                if open { reveal?(bits) }
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
        Gtk.addClass(column, "workflow-answer-col")
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

    /// The tool an agent is holding right now, which is the mark's answer rather than a second
    /// one this card works out for itself.
    ///
    /// A sidecar goes on naming the tool it was last seen on for as long as its reporting window
    /// lasts, which outlives the run by up to half an hour — so a row read from the agent alone
    /// would keep "WebFetch" lit beside a settled mark under a header that says the run is over.
    /// ``ActivityIcon/workflowAgent(_:in:)`` has already weighed the agent against its run: only
    /// the mark it hands back for an agent genuinely still out names a tool.
    private static func liveTool(_ agent: WorkflowAgent, wearing icon: ActivityIcon) -> String? {
        icon == .openWork ? agent.currentTool : nil
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

    /// The mark this card wears, which is the run's own — never a face invented here. A card that
    /// spelled an ending its own way could disagree with the agent rows under it and with the same
    /// card on a phone, and the ending is the whole thing a reader is looking for. A call whose run
    /// has not been assembled yet has not started, and idle is what not started looks like.
    private static func mark(_ run: WorkflowRun?) -> ActivityIcon { run?.activityIcon ?? .idle }

    /// Points a mark at its state and leaves it showing that state's own glyph.
    ///
    /// A settled state does not animate, and ``ActivityPulse`` stops a mark without putting words
    /// back — so the still glyph is written here, or a run that ended would keep whichever frame of
    /// the sweep it was on when the report landed, which is the moving record this card exists not
    /// to be.
    private static func applyMark(
        _ icon: ActivityIcon, to label: UnsafeMutablePointer<GtkWidget>
    ) {
        ActivityPulse.apply(icon, to: label)
        let motion = icon.motion.honoring(reduceMotion: !ActivityPulse.motionAllowed)
        guard !motion.isAnimated else { return }
        setLabel(label, text: icon.glyph)
    }

    /// One reading of the header's mark, for a harness that has to prove it stopped rather than
    /// watch it: the glyph on screen and what the mark itself counted.
    static func markReading(of card: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let button = gtk_widget_get_first_child(card), isA(button, gtk_button_get_type()),
            let header = Gtk.disclosureHeader(button), let label = children(of: header).first
        else { return "mark=none" }
        let glyph = gtk_label_get_text(op(label)).map { String(cString: $0) } ?? ""
        return "mark=\(glyph) " + ActivityPulse.reading(of: label)
    }

    /// One reading of the phase rail, for a harness that has to prove a run that was killed draws
    /// a different rail from one that got all the way through: every marker's glyph and the
    /// standing it is wearing, in the order the plan declares them.
    static func phaseReading(of card: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let button = gtk_widget_get_first_child(card),
            let body = gtk_widget_get_next_sibling(button),
            let phases = children(of: body).first(where: {
                gtk_widget_has_css_class($0, "workflow-phases") != 0
            })
        else { return "phases=none" }
        let marks = children(of: phases).compactMap { row -> String? in
            guard let marker = gtk_widget_get_first_child(row) else { return nil }
            let text = gtk_label_get_text(op(marker)).map { String(cString: $0) } ?? ""
            let standing = Self.phaseClasses.first { gtk_widget_has_css_class(marker, $0) != 0 }
            return "\(text.split(separator: " ").last ?? "?"):\(standing ?? "none")"
        }
        return "phases=\(marks.joined(separator: ","))"
    }

    /// One reading of the agent rows, for a harness that has to prove a row under a run that
    /// ended holds still however active the agent's own record still claims to be: each row's
    /// glyph and whether it is on the clock.
    static func agentReading(of card: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let button = gtk_widget_get_first_child(card),
            let body = gtk_widget_get_next_sibling(button),
            let agents = children(of: body).first(where: {
                gtk_widget_has_css_class($0, "workflow-agents") != 0
            })
        else { return "agents=none" }
        let marks = children(of: agents).compactMap { row -> String? in
            guard let disclosure = gtk_widget_get_first_child(row),
                let header = Gtk.disclosureHeader(disclosure),
                let glyph = children(of: header).first
            else { return nil }
            let text = gtk_label_get_text(op(glyph)).map { String(cString: $0) } ?? ""
            let moving = ActivityPulse.reading(of: glyph).hasPrefix("moving=1")
            return "\(text):\(moving ? "moving" : "still")"
        }
        return "agents=\(marks.joined(separator: ","))"
    }

    private static let glyphClasses = ActivityTone.allCases.map(\.glyphCSS)
    private static let phaseClasses = WorkflowPhaseStanding.allCases.map(\.css)
    private static let headlineClasses = ["agent-live", "dim", "glyph-error"]

    private static func headlineClass(_ run: WorkflowRun) -> String {
        if run.isLive { return "agent-live" }
        return run.activityIcon.tone == .danger ? "glyph-error" : "dim"
    }

    private static func isA(_ widget: UnsafeMutablePointer<GtkWidget>, _ type: GType) -> Bool {
        let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
        return g_type_check_instance_is_a(instance, type) != 0
    }

    private static func children(of box: UnsafeMutablePointer<GtkWidget>)
        -> [UnsafeMutablePointer<GtkWidget>]
    {
        var found: [UnsafeMutablePointer<GtkWidget>] = []
        var child = gtk_widget_get_first_child(box)
        while let current = child {
            found.append(current)
            child = gtk_widget_get_next_sibling(current)
        }
        return found
    }

    /// Writes a label only when the words changed: an equal set still invalidates the label's
    /// layout, and a tick that changes nothing must cost nothing.
    private static func setLabel(_ label: UnsafeMutablePointer<GtkWidget>, text: String) {
        guard isA(label, gtk_label_get_type()) else { return }
        if let current = gtk_label_get_text(op(label)), String(cString: current) == text { return }
        gtk_label_set_text(op(label), text)
    }

    private static func setExclusiveClass(
        _ widget: UnsafeMutablePointer<GtkWidget>, among all: [String], to chosen: String
    ) {
        for name in all where name != chosen { gtk_widget_remove_css_class(widget, name) }
        gtk_widget_add_css_class(widget, chosen)
    }
}

/// Workflow agents have no spawning tool call, so their fetched transcripts are keyed by agent id
/// in the same store the spawned ones use — one namespace, no collision with a tool-use id.
enum WorkflowAgentRows {
    static func key(_ agentID: String) -> String { "workflow-agent:\(agentID)" }
}
