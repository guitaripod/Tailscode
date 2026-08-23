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
        header.addArrangedSubview(markLabel(run))
        let word = RowKit.label(
            "\(ToolRowView.disclosureGlyph(expanded)) \(Localized.text("workflow"))", font: MacTheme.Ramp.font(.code),
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
                word.stringValue = "\(ToolRowView.disclosureGlyph(open)) \(Localized.text("workflow"))"
                toggle?(key, open)
                if open { reveal?(row) }
            }
        ) { [weak context] in
            guard let context else { return RowKit.inset(NSStackView(), leading: 26) }
            return body(run, context: context, now: now)
        }
    }

    /// The card restated in place from the run it already shows: the run's mark, headline, elapsed
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
        guard head.count == 5, let mark = head[0] as? ActivityMarkLabel else { return false }
        wear(icon(run), on: mark)
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
            for (phaseRow, phase) in zip(rows, run.phases) {
                let labels = phaseRow.arrangedSubviews.compactMap { $0 as? NSTextField }
                guard labels.count >= 2 else { return false }
                wear(
                    run.phaseStanding, on: labels[0], title: labels[1], phase: phase,
                    of: run.phases.count)
            }
        }

        let agents = find(agentsID, in: body) as? NSStackView
        guard (agents != nil) == !run.agents.isEmpty else { return false }
        if let agents {
            let rows = agents.arrangedSubviews.compactMap { $0 as? DisclosureRow }
            guard rows.count == run.agents.count else { return false }
            for (agentRow, agent) in zip(rows, run.agents) {
                guard restateAgent(agentRow, agent: agent, in: run, now: now) else { return false }
            }
        }

        let hasAnswer = !(run.result ?? "").isEmpty
        guard (find(answerID, in: body) != nil) == hasAnswer else { return false }
        return true
    }

    /// One agent row restated. The mark is read against the run rather than against the agent's own
    /// record: a sidecar goes on calling itself active for up to half an hour after the run around
    /// it ended, and the per-second restate that would ever re-ask is itself gated on the run being
    /// live — so a card left to the record alone sweeps its agents forever under a header that says
    /// the work stopped. The caption and the sentence follow the mark for the same reason: only an
    /// agent the mark shows as out is holding a tool, or is one VoiceOver may call working. The
    /// clock is read against the run for the same reason and by the same road — an agent that never
    /// reported finishing has no ending of its own, so a row timed to its own record alone counts a
    /// four-minute errand as however long ago the run was.
    private static func restateAgent(
        _ row: DisclosureRow, agent: WorkflowAgent, in run: WorkflowRun, now: Date
    ) -> Bool {
        guard let header = row.headerView as? NSStackView,
            let badge = header.arrangedSubviews.first as? ActivityBadgeView
        else { return false }
        let head = header.arrangedSubviews.compactMap { $0 as? NSTextField }
        guard head.count == 3 else { return false }
        let icon = ActivityIcon.workflowAgent(agent, in: run)
        badge.show(icon, spoken: icon == .openWork ? Localized.text("Agent working") : nil)
        let tool = liveTool(agent, wearing: icon)
        setLabel(head[1], text: tool ?? "")
        head[1].isHidden = tool == nil
        let elapsed = agent.elapsed(at: now, in: run)
        setLabel(head[2], text: elapsed.map(WorkflowRun.duration) ?? "")
        head[2].isHidden = elapsed == nil
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
        let marker = RowKit.label(
            "", font: MacTheme.Ramp.font(.toolOutput), color: MacTheme.Color.tertiaryLabel)
        let title = RowKit.label(
            phase.title, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.label)
        wear(run.phaseStanding, on: marker, title: title, phase: phase, of: run.phases.count)
        row.addArrangedSubview(marker)
        row.addArrangedSubview(title)
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

    /// How much of the plan one phase row may claim, in the mark it wears and the word it is read
    /// with.
    ///
    /// An ending is not an achievement. Nothing anywhere records which phase was current when a run
    /// was stopped or when it broke, so a rail filled on `!isLive` drew four finished phases for a
    /// four-phase script killed inside the first — a claim the transcript never made. Core decides
    /// which of the three readings a run has earned and what each looks like, so three cards cannot
    /// disagree about one plan. A filled block and a hollow one are the same silence to a screen
    /// reader, so the standing is spoken over the phase it belongs to rather than by the rule
    /// beside it, which has nothing of its own to say and would only cost the reader a stop.
    private static func wear(
        _ standing: WorkflowPhaseStanding, on marker: NSTextField, title: NSTextField,
        phase: WorkflowPhase, of count: Int
    ) {
        setLabel(
            marker, text: phaseMark(phase, of: count, standing: standing),
            color: standing.tone.color)
        marker.setAccessibilityElement(false)
        title.setAccessibilityLabel("\(phase.title), \(standing.spoken)")
    }

    private static func phaseMark(
        _ phase: WorkflowPhase, of count: Int, standing: WorkflowPhaseStanding
    ) -> String {
        "\(phase.index == count - 1 ? "└" : "├") \(standing.glyph)"
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
        let badge = ActivityBadgeView(pointSize: 11)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let icon = ActivityIcon.workflowAgent(agent, in: run)
        badge.show(icon, spoken: icon == .openWork ? Localized.text("Agent working") : nil)
        header.addArrangedSubview(badge)
        header.addArrangedSubview(
            ToolRowView.detailLabel(
                String(agent.title.replacingOccurrences(of: "\n", with: " ").prefix(120))))
        let working = liveTool(agent, wearing: icon)
        let tool = RowKit.label(
            working ?? "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.accent)
        tool.isHidden = working == nil
        header.addArrangedSubview(tool)
        let elapsed = RowKit.label(
            agent.elapsed(at: now, in: run).map(WorkflowRun.duration) ?? "",
            font: MacTheme.Ramp.font(.workflowMeter), color: MacTheme.Color.secondaryLabel)
        elapsed.isHidden = agent.elapsed(at: now, in: run) == nil
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

    /// What the run is called, restated as well as built. The Workflow tool answers before its run
    /// exists, so a card is routinely made with the placeholder — and a collapsed card is never
    /// rebuilt, which left "Workflow" standing over a live headline for the length of the run.
    private static func name(_ run: WorkflowRun?, _ call: ToolCall) -> String {
        run?.name ?? call.summary.title ?? Localized.text("Workflow")
    }

    /// The mark this card wears, which is the run's own — never a face invented here. A card that
    /// spelled an ending its own way could disagree with the agent rows under it and with the same
    /// card on a phone, and the ending is the whole thing a reader is looking for. A call whose run
    /// has not been assembled yet has not started, and idle is what not started looks like.
    private static func icon(_ run: WorkflowRun?) -> ActivityIcon { run?.activityIcon ?? .idle }

    /// The header's mark, on its own clock rather than on the card's once-a-second tick. A sweep
    /// stepped by that tick was one frame a second — a rate no eye reads as turning — and it was
    /// pinned to the launching call, which answers in milliseconds and never speaks again.
    private static func markLabel(_ run: WorkflowRun?) -> ActivityMarkLabel {
        let label = ActivityMarkLabel(frame: .zero)
        label.font = MacTheme.Ramp.font(.code)
        label.stringValue = icon(run).glyph
        wear(icon(run), on: label)
        return label
    }

    /// Points a mark at its state and leaves it showing that state's own glyph and tone.
    ///
    /// A settled state does not animate, and ``ActivityPulse`` stops a mark without putting words
    /// back — so the still glyph is written here, or a run that ended would keep whichever frame of
    /// the sweep it was on when the report landed, which is the moving record this card exists not
    /// to be. A live mark is left alone: the pulse owns those glyphs, and writing one from the
    /// card's own tick would stutter the turn once a second.
    private static func wear(_ icon: ActivityIcon, on label: ActivityMarkLabel) {
        label.mark(icon)
        if label.textColor != icon.tone.color { label.textColor = icon.tone.color }
        guard !icon.motion.honoring(reduceMotion: !ActivityPulse.motionAllowed).isAnimated else {
            return
        }
        setLabel(label, text: icon.glyph)
    }

    /// One reading of the agent rows, for a harness that has to prove a row under a run that ended
    /// holds still and names nothing, however active the agent's own record still claims to be:
    /// each row's glyph, whether it is on the clock, and the tool it is putting a reader's name to.
    static func agentReading(of card: NSView) -> String {
        guard let agents = find(agentsID, in: card) as? NSStackView else { return "agents=none" }
        let rows = agents.arrangedSubviews.compactMap { row -> String? in
            guard let header = (row as? DisclosureRow)?.headerView as? NSStackView,
                let badge = header.arrangedSubviews.first as? ActivityBadgeView,
                let icon = badge.icon
            else { return nil }
            let labels = header.arrangedSubviews.compactMap { $0 as? NSTextField }
            let tool = labels.count == 3 && !labels[1].isHidden ? labels[1].stringValue : ""
            let moving = icon.motion.honoring(reduceMotion: !ActivityPulse.motionAllowed).isAnimated
            return "\(icon.glyph):\(moving ? "moving" : "still"):\(tool)"
        }
        return "agents=" + rows.joined(separator: ",")
    }

    /// One reading of what the agent rows say about time, for a harness that has to prove a row
    /// under a run that is over reads the same whenever the transcript is opened. The caption is
    /// taken as drawn — an empty one where the row shows none — because a length nobody can see is
    /// not a length this card claimed.
    static func agentClockReading(of card: NSView) -> String {
        guard let agents = find(agentsID, in: card) as? NSStackView else { return "clocks=none" }
        let rows = agents.arrangedSubviews.compactMap { row -> String? in
            guard let header = (row as? DisclosureRow)?.headerView as? NSStackView else {
                return nil
            }
            let labels = header.arrangedSubviews.compactMap { $0 as? NSTextField }
            guard labels.count == 3 else { return nil }
            return labels[2].isHidden ? "" : labels[2].stringValue
        }
        return "clocks=" + rows.joined(separator: ",")
    }

    private static func headlineColor(_ run: WorkflowRun) -> NSColor {
        if run.isLive { return MacTheme.Color.accent }
        return run.activityIcon.tone == .danger
            ? MacTheme.Color.danger : MacTheme.Color.tertiaryLabel
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
