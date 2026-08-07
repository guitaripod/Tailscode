import AppKit
import CodingAgentKit
import TailscodeCore

/// A workflow is a run, not a receipt. The Workflow tool answers the instant it hands the work to
/// the background, so the call itself has nothing left to say while its agents spend minutes on it —
/// the card says it instead: what the run is, the phases its script declares, every agent that has
/// appeared and what it is doing, how far through the fan-out in hand it is, and how long it has
/// been going. The answer arrives later as its own message and is folded into the same card.
@MainActor
enum WorkflowCardView {
    static func make(_ call: ToolCall, key: String, context: TranscriptContext) -> NSView {
        let run = context.workflowRuns[call.id]
        let now = context.workflowNow
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = MacTheme.Spacing.s
        header.addArrangedSubview(
            RowKit.label(glyph(run, now), font: MacTheme.Font.mono(12), color: glyphColor(run)))
        header.addArrangedSubview(
            RowKit.label("▸ workflow", font: MacTheme.Font.mono(12), color: MacTheme.Color.label))
        header.addArrangedSubview(
            RowKit.label(
                run?.name ?? call.summary.title ?? Localized.text("Workflow"),
                font: MacTheme.Font.mono(12).bold, color: MacTheme.Color.accent))
        if let run {
            header.addArrangedSubview(
                RowKit.label(
                    run.headline(at: now), font: MacTheme.Font.caption(),
                    color: headlineColor(run)))
            if let elapsed = run.elapsed(at: now) {
                header.addArrangedSubview(
                    RowKit.label(
                        WorkflowRun.duration(elapsed), font: MacTheme.Font.caption(),
                        color: MacTheme.Color.tertiaryLabel))
            }
        }

        let toggle = context.onToggle
        return DisclosureRow(
            header: header, expanded: context.isExpanded(key),
            onToggle: { open in toggle?(key, open) }
        ) { [weak context] in
            guard let context else { return RowKit.inset(NSStackView(), leading: 26) }
            return body(run, context: context, now: now)
        }
    }

    private static func body(_ run: WorkflowRun?, context: TranscriptContext, now: Date) -> NSView {
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        body.wantsLayer = true
        body.layer?.backgroundColor = MacTheme.Color.subagentBackground.cgColor
        body.layer?.cornerRadius = MacTheme.Radius.control
        guard let run else {
            body.addArrangedSubview(
                RowKit.label(
                    Localized.text("Starting…"), font: MacTheme.Font.caption(),
                    color: MacTheme.Color.tertiaryLabel))
            return RowKit.inset(body, leading: 26)
        }

        if let summary = run.summary {
            body.addArrangedSubview(
                RowKit.wrapping(
                    summary, font: MacTheme.Font.caption(), color: MacTheme.Color.secondaryLabel))
        }
        body.addArrangedSubview(meter(run))
        for phase in run.phases { body.addArrangedSubview(phaseRow(phase, run: run)) }
        for agent in run.agents {
            body.addArrangedSubview(agentRow(agent, run: run, context: context, now: now))
        }
        if let result = run.result, !result.isEmpty {
            body.addArrangedSubview(RowKit.hairline(verticalPadding: 4))
            body.addArrangedSubview(answer(result, name: run.name, context: context))
        }
        return RowKit.inset(body, leading: 26)
    }

    /// Progress over the agents in hand. A run never promises how many it will spawn, so the meter
    /// is labelled with what it actually counts rather than implying a total nobody has stated.
    private static func meter(_ run: WorkflowRun) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        let slots = 18
        let filled = Int((Double(slots) * run.progress).rounded())
        row.addArrangedSubview(
            RowKit.label(
                String(repeating: "▰", count: filled)
                    + String(repeating: "▱", count: slots - filled),
                font: MacTheme.Font.mono(11),
                color: run.isLive ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel))
        let caption =
            run.agents.isEmpty
            ? Localized.text("no agents yet")
            : Localized.text("%@ of %@ agents", "\(run.doneCount)", "\(run.agents.count)")
        row.addArrangedSubview(
            RowKit.label(
                caption, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        return row
    }

    /// The phases the script declares, as the plan it is. Which phase an agent belongs to is only
    /// recorded by a finished run, so a live card never points at one — claiming a position the
    /// data cannot support is worse than showing the plan and the agents separately.
    private static func phaseRow(_ phase: WorkflowPhase, run: WorkflowRun) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        let done = !run.isLive
        let marker = phase.index == run.phases.count - 1 ? "└" : "├"
        row.addArrangedSubview(
            RowKit.label(
                "\(marker) \(done ? "▰" : "▱")", font: MacTheme.Font.mono(11),
                color: done ? MacTheme.Color.accent : MacTheme.Color.tertiaryLabel))
        row.addArrangedSubview(
            RowKit.label(phase.title, font: MacTheme.Font.mono(12), color: MacTheme.Color.label))
        if let detail = phase.detail {
            row.addArrangedSubview(
                RowKit.label(
                    detail, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
        }
        if let model = phase.model {
            row.addArrangedSubview(
                RowKit.label(
                    shortModel(model), font: MacTheme.Font.mono(10), color: MacTheme.Color.mark))
        }
        return row
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
                agentGlyph(agent, now: now), font: MacTheme.Font.mono(11),
                color: agentColor(agent)))
        header.addArrangedSubview(
            ToolRowView.detailLabel(
                String(agent.title.replacingOccurrences(of: "\n", with: " ").prefix(120))))
        if agent.isActive, let tool = agent.currentTool {
            header.addArrangedSubview(
                RowKit.label(
                    tool, font: MacTheme.Font.caption(), color: MacTheme.Color.accent))
        }
        if let elapsed = agent.elapsed(at: now) {
            header.addArrangedSubview(
                RowKit.label(
                    WorkflowRun.duration(elapsed), font: MacTheme.Font.caption(),
                    color: MacTheme.Color.tertiaryLabel))
        }

        let key = "wf:\(run.id):\(agent.id)"
        let rowKey = WorkflowAgentRows.key(agent.id)
        let toggle = context.onToggle
        let request = context.requestWorkflowAgent
        let agentID = agent.id
        return DisclosureRow(
            header: header, expanded: context.isExpanded(key),
            onToggle: { [weak context] open in
                toggle?(key, open)
                if open, context?.subagentRows[rowKey] == nil { request?(agentID) }
            }
        ) { [weak context] in
            let body = NSStackView()
            body.orientation = .vertical
            body.alignment = .width
            body.spacing = 6
            body.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            guard let context else { return RowKit.inset(body, leading: 20) }
            if let rows = context.subagentRows[rowKey] {
                if rows.isEmpty {
                    body.addArrangedSubview(
                        RowKit.label(
                            Localized.text("No transcript for this agent."),
                            font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel))
                }
                for row in rows.suffix(160) {
                    body.addArrangedSubview(row.makeView(context: context))
                }
            } else {
                body.addArrangedSubview(
                    RowKit.label(
                        Localized.text("Loading transcript…"), font: MacTheme.Font.caption(),
                        color: MacTheme.Color.tertiaryLabel))
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
