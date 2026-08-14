import AppKit
import CodingAgentKit
import TailscodeCore

/// A workflow is a run, not a receipt. The Workflow tool answers the instant it hands the work to
/// the background, so the call itself has nothing left to say while its agents spend minutes on it —
/// the card says it instead: what the run is, the phases its script declares, every agent that has
/// appeared and what it is doing, how far through the fan-out in hand it is, and how long it has
/// been going. The answer arrives later as its own message and is folded into the same card.
///
/// A live card is a clock, and a clock must not be a demolition: the once-a-second tick is written
/// into the labels the card already has (``restate``), never by tearing the view down — a card
/// rebuilt under the pointer eats the click that was in flight and rebuilds an opened agent
/// transcript nobody asked to pay for again. Every label whose text comes and goes is created up
/// front and hidden while empty, so a tick only ever changes words, and the view tree stays the
/// shape ``restate`` expects for as long as the run's structure holds. Only a structural change —
/// an agent appearing, the result landing — earns a rebuild.
@MainActor
enum WorkflowCardView {
    private static let meterID = NSUserInterfaceItemIdentifier("workflow-meter")
    private static let phasesID = NSUserInterfaceItemIdentifier("workflow-phases")
    private static let agentsID = NSUserInterfaceItemIdentifier("workflow-agents")
    private static let answerID = NSUserInterfaceItemIdentifier("workflow-answer")
    private static let summaryID = NSUserInterfaceItemIdentifier("workflow-summary")

    static func make(_ call: ToolCall, key: String, context: TranscriptContext) -> NSView {
        let run = context.workflowRuns[call.id]
        let now = context.workflowNow
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = MacTheme.Spacing.s
        let expanded = context.isExpanded(key)
        header.addArrangedSubview(
            RowKit.label(glyph(run, now), font: MacTheme.Ramp.font(.code), color: glyphColor(run)))
        let word = RowKit.label(
            "\(ToolRowView.disclosureGlyph(expanded)) workflow", font: MacTheme.Ramp.font(.code),
            color: MacTheme.Color.label)
        header.addArrangedSubview(word)
        header.addArrangedSubview(
            RowKit.label(
                name(run, call), font: MacTheme.Ramp.font(.workflowName),
                color: MacTheme.Color.accent))
        let headline = RowKit.label(
            run.map { $0.headline(at: now) } ?? "", font: MacTheme.Ramp.font(.panelFootnote),
            color: run.map(headlineColor) ?? MacTheme.Color.tertiaryLabel)
        headline.isHidden = run == nil
        header.addArrangedSubview(headline)
        let elapsed = RowKit.label(
            (run?.elapsed(at: now)).map(WorkflowRun.duration) ?? "",
            font: MacTheme.Ramp.font(.workflowMeter), color: MacTheme.Color.secondaryLabel)
        elapsed.isHidden = run?.elapsed(at: now) == nil
        header.addArrangedSubview(elapsed)

        let toggle = context.onToggle
        let reveal = context.revealRow
        return DisclosureRow(
            header: header, expanded: expanded,
            onToggle: { open, row in
                word.stringValue = "\(ToolRowView.disclosureGlyph(open)) workflow"
                toggle?(key, open)
                if open { reveal?(row) }
            }
        ) { [weak context] in
            guard let context else { return RowKit.inset(NSStackView(), leading: 26) }
            return body(run, context: context, now: now)
        }
    }

    /// The card restated in place from the run it already shows: spinner frame, headline, elapsed
    /// readings, meter fill, phase marks, each agent's glyph and current tool. False the moment the
    /// view's structure no longer matches the run — a new agent, the result arriving, a card built
    /// before its run existed — which is the caller's cue to rebuild this one card whole.
    static func restate(_ view: NSView, call: ToolCall, context: TranscriptContext) -> Bool {
        guard let row = view as? DisclosureRow,
            let header = row.headerView as? NSStackView
        else { return false }
        let run = context.workflowRuns[call.id]
        let now = context.workflowNow
        let head = header.arrangedSubviews.compactMap { $0 as? NSTextField }
        guard head.count == 5 else { return false }
        setLabel(head[0], text: glyph(run, now), color: glyphColor(run))
        setLabel(head[2], text: name(run, call))
        setLabel(
            head[3], text: run.map { $0.headline(at: now) } ?? "",
            color: run.map(headlineColor) ?? MacTheme.Color.tertiaryLabel)
        head[3].isHidden = run == nil
        let elapsed = run?.elapsed(at: now)
        setLabel(head[4], text: elapsed.map(WorkflowRun.duration) ?? "")
        head[4].isHidden = elapsed == nil

        guard let body = row.bodyView else { return true }
        guard let run else { return true }
        guard let meterRow = find(meterID, in: body) as? NSStackView else { return false }

        let summary = find(summaryID, in: body) as? NSTextField
        guard (summary != nil) == (run.summary != nil) else { return false }
        if let summary, let text = run.summary { setLabel(summary, text: text) }

        let meter = meterRow.arrangedSubviews.compactMap { $0 as? NSTextField }
        guard meter.count == 2 else { return false }
        setLabel(
            meter[0], text: meterBar(run),
            color: run.isLive ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel)
        setLabel(meter[1], text: meterCaption(run))

        let phases = find(phasesID, in: body) as? NSStackView
        guard (phases != nil) == !run.phases.isEmpty else { return false }
        if let phases {
            let rows = phases.arrangedSubviews.compactMap { $0 as? NSStackView }
            guard rows.count == run.phases.count else { return false }
            let done = !run.isLive
            for (phaseRow, phase) in zip(rows, run.phases) {
                guard let marker = phaseRow.arrangedSubviews.first as? NSTextField else {
                    return false
                }
                setLabel(
                    marker, text: phaseMark(phase, of: run.phases.count, done: done),
                    color: done ? MacTheme.Color.accent : MacTheme.Color.tertiaryLabel)
            }
        }

        let agents = find(agentsID, in: body) as? NSStackView
        guard (agents != nil) == !run.agents.isEmpty else { return false }
        if let agents {
            let rows = agents.arrangedSubviews.compactMap { $0 as? DisclosureRow }
            guard rows.count == run.agents.count else { return false }
            for (agentRow, agent) in zip(rows, run.agents) {
                guard restateAgent(agentRow, agent: agent, now: now) else { return false }
            }
        }

        let hasAnswer = !(run.result ?? "").isEmpty
        guard (find(answerID, in: body) != nil) == hasAnswer else { return false }
        return true
    }

    private static func restateAgent(_ row: DisclosureRow, agent: WorkflowAgent, now: Date) -> Bool {
        guard let header = row.headerView as? NSStackView else { return false }
        let head = header.arrangedSubviews.compactMap { $0 as? NSTextField }
        guard head.count == 4 else { return false }
        setLabel(head[0], text: agentGlyph(agent, now: now), color: agentColor(agent))
        let tool = agent.isActive ? agent.currentTool : nil
        setLabel(head[2], text: tool ?? "")
        head[2].isHidden = tool == nil
        let elapsed = agent.elapsed(at: now)
        setLabel(head[3], text: elapsed.map(WorkflowRun.duration) ?? "")
        head[3].isHidden = elapsed == nil
        return true
    }

    private static func body(_ run: WorkflowRun?, context: TranscriptContext, now: Date) -> NSView {
        let body = FillingStack()
        body.spacing = 6
        body.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let card = GroundView(
            around: body, cornerRadius: MacTheme.Radius.control,
            fill: MacTheme.Color.subagentBackground)
        guard let run else {
            body.addArrangedSubview(
                RowKit.label(
                    Localized.text("Starting…"), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel))
            return RowKit.inset(card, leading: 26)
        }

        if let summary = run.summary {
            let label = RowKit.wrapping(
                summary, font: MacTheme.Ramp.font(.workflowSummary),
                color: MacTheme.Color.secondaryLabel)
            label.identifier = summaryID
            body.addArrangedSubview(label)
        }
        body.addArrangedSubview(meter(run))
        if !run.phases.isEmpty {
            let rail = FillingStack()
            rail.spacing = 1
            rail.identifier = phasesID
            for phase in run.phases { rail.addArrangedSubview(phaseRow(phase, run: run)) }
            body.addArrangedSubview(rail)
        }
        if !run.agents.isEmpty {
            let list = FillingStack()
            list.spacing = 1
            list.identifier = agentsID
            for agent in run.agents {
                list.addArrangedSubview(agentRow(agent, run: run, context: context, now: now))
            }
            body.addArrangedSubview(list)
        }
        if let result = run.result, !result.isEmpty {
            body.addArrangedSubview(RowKit.hairline(verticalPadding: 4))
            body.addArrangedSubview(answer(result, name: run.name, context: context))
        }
        return RowKit.inset(card, leading: 26)
    }

    /// Progress over the agents in hand. A run never promises how many it will spawn, so the meter
    /// is labelled with what it actually counts rather than implying a total nobody has stated.
    private static func meter(_ run: WorkflowRun) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        row.identifier = meterID
        row.addArrangedSubview(
            RowKit.label(
                meterBar(run), font: MacTheme.Ramp.font(.workflowMeter),
                color: run.isLive ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel))
        row.addArrangedSubview(
            RowKit.label(
                meterCaption(run), font: MacTheme.Ramp.font(.workflowMeter),
                color: MacTheme.Color.secondaryLabel))
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
    private static func phaseRow(_ phase: WorkflowPhase, run: WorkflowRun) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        let done = !run.isLive
        row.addArrangedSubview(
            RowKit.label(
                phaseMark(phase, of: run.phases.count, done: done), font: MacTheme.Ramp.font(.toolOutput),
                color: done ? MacTheme.Color.accent : MacTheme.Color.tertiaryLabel))
        row.addArrangedSubview(
            RowKit.label(phase.title, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.label))
        if let detail = phase.detail {
            row.addArrangedSubview(
                RowKit.label(
                    detail, font: MacTheme.Ramp.font(.workflowStep),
                    color: MacTheme.Color.secondaryLabel))
        }
        if let model = phase.model {
            row.addArrangedSubview(
                RowKit.label(
                    shortModel(model), font: MacTheme.Ramp.font(.workflowModel),
                    color: MacTheme.Color.mark))
        }
        return row
    }

    private static func phaseMark(_ phase: WorkflowPhase, of count: Int, done: Bool) -> String {
        "\(phase.index == count - 1 ? "└" : "├") \(done ? "▰" : "▱")"
    }

    /// One agent, openable in place: its own sidecar transcript is fetched on demand and rendered
    /// with the same rows as any other conversation, because a workflow agent is never its own chat.
    private static func agentRow(
        _ agent: WorkflowAgent, run: WorkflowRun, context: TranscriptContext, now: Date
    ) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = MacTheme.Spacing.s
        header.addArrangedSubview(
            RowKit.label(
                agentGlyph(agent, now: now), font: MacTheme.Ramp.font(.toolOutput),
                color: agentColor(agent)))
        header.addArrangedSubview(
            ToolRowView.detailLabel(
                String(agent.title.replacingOccurrences(of: "\n", with: " ").prefix(120))))
        let liveTool = agent.isActive ? agent.currentTool : nil
        let tool = RowKit.label(
            liveTool ?? "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.accent)
        tool.isHidden = liveTool == nil
        header.addArrangedSubview(tool)
        let elapsed = RowKit.label(
            agent.elapsed(at: now).map(WorkflowRun.duration) ?? "",
            font: MacTheme.Ramp.font(.workflowMeter), color: MacTheme.Color.secondaryLabel)
        elapsed.isHidden = agent.elapsed(at: now) == nil
        header.addArrangedSubview(elapsed)

        let key = "wf:\(run.id):\(agent.id)"
        let rowKey = WorkflowAgentRows.key(agent.id)
        let toggle = context.onToggle
        let reveal = context.revealRow
        let request = context.requestWorkflowAgent
        let agentID = agent.id
        return DisclosureRow(
            header: header, expanded: context.isExpanded(key),
            onToggle: { [weak context] open, row in
                toggle?(key, open)
                if open { reveal?(row) }
                if open, context?.subagentRows[rowKey] == nil { request?(agentID) }
            }
        ) { [weak context] in
            let body = FillingStack()
            body.spacing = 6
            body.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            guard let context else { return RowKit.inset(body, leading: 20) }
            if let rows = context.subagentRows[rowKey] {
                if rows.isEmpty {
                    body.addArrangedSubview(
                        RowKit.label(
                            Localized.text("No transcript for this agent."),
                            font: MacTheme.Ramp.font(.panelFootnote),
                            color: MacTheme.Color.secondaryLabel))
                }
                if rows.count > 160 {
                    body.addArrangedSubview(
                        RowKit.label(
                            Localized.text("… %@ earlier rows", "\(rows.count - 160)"),
                            font: MacTheme.Ramp.font(.panelFootnote),
                            color: MacTheme.Color.secondaryLabel))
                }
                for row in rows.suffix(160) {
                    body.addArrangedSubview(row.makeView(context: context))
                }
            } else {
                body.addArrangedSubview(
                    RowKit.label(
                        Localized.text("Loading transcript…"), font: MacTheme.Ramp.font(.panelFootnote),
                        color: MacTheme.Color.secondaryLabel))
                if context.isExpanded(key) { context.requestWorkflowAgent?(agentID) }
            }
            return RowKit.inset(body, leading: 20)
        }
    }

    /// The run's answer, in the card that started it. Long answers stay behind a reader rather than
    /// unrolling thousands of words inside a tool row.
    private static func answer(_ result: String, name: String, context: TranscriptContext) -> NSView
    {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.xs
        column.identifier = answerID
        let preview = result.count > 1200 ? String(result.prefix(1200)) + "…" : result
        column.addArrangedSubview(TranscriptRow.richBody(preview, context: context))
        if result.count > 1200 {
            let present = context.presentText
            column.addArrangedSubview(
                RowKit.linkButton(Localized.text("Read the whole answer")) {
                    present?(name, nil, result, false)
                })
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

    /// What the run is called, restated as well as built. The Workflow tool answers before its run
    /// exists, so a card is routinely made with the placeholder — and a collapsed card is never
    /// rebuilt, which left "Workflow" standing over a live headline for the length of the run.
    private static func name(_ run: WorkflowRun?, _ call: ToolCall) -> String {
        run?.name ?? call.summary.title ?? Localized.text("Workflow")
    }

    private static let spinner = ["⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷"]

    /// A desk that asked for less motion keeps the glyph and loses the turning, the way every other
    /// mark in the app does — this one is written by the card's own tick rather than by a pulse, so
    /// it has to ask.
    private static func frame(_ now: Date) -> String {
        guard ActivityPulse.motionAllowed else { return spinner[0] }
        return spinner[Int(now.timeIntervalSince1970) % spinner.count]
    }

    private static func glyph(_ run: WorkflowRun?, _ now: Date) -> String {
        guard let run else { return "○" }
        switch run.state {
        case .launching, .running: return frame(now)
        case .finished: return "⏺"
        case .failed: return "✗"
        }
    }

    private static func glyphColor(_ run: WorkflowRun?) -> NSColor {
        guard let run else { return MacTheme.Color.tertiaryLabel }
        switch run.state {
        case .launching, .running: return MacTheme.Color.accent
        case .finished: return MacTheme.Color.success
        case .failed: return MacTheme.Color.danger
        }
    }

    private static func headlineColor(_ run: WorkflowRun) -> NSColor {
        switch run.state {
        case .launching, .running: return MacTheme.Color.accent
        case .finished: return MacTheme.Color.tertiaryLabel
        case .failed: return MacTheme.Color.danger
        }
    }

    private static func agentGlyph(_ agent: WorkflowAgent, now: Date) -> String {
        if agent.isCompleted { return "✓" }
        return agent.isActive ? frame(now) : "○"
    }

    private static func agentColor(_ agent: WorkflowAgent) -> NSColor {
        if agent.isCompleted { return MacTheme.Color.success }
        return agent.isActive ? MacTheme.Color.accent : MacTheme.Color.tertiaryLabel
    }

    /// Writes a label only when the words changed: an equal set still dirties layout, and a tick
    /// that changes nothing must cost nothing.
    private static func setLabel(_ label: NSTextField, text: String, color: NSColor? = nil) {
        if label.stringValue != text { label.stringValue = text }
        if let color, label.textColor != color { label.textColor = color }
    }

    private static func find(_ id: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == id { return view }
        for child in view.subviews {
            if let match = find(id, in: child) { return match }
        }
        return nil
    }
}

/// Workflow agents have no spawning tool call, so their fetched transcripts are keyed by agent id
/// in the same store the spawned ones use — one namespace, no collision with a tool-use id.
enum WorkflowAgentRows {
    static func key(_ agentID: String) -> String { "workflow-agent:\(agentID)" }
}

extension NSFont {
    var bold: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
