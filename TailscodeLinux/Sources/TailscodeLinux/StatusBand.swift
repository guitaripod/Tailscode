import CAdw
import CodingAgentKit
import Foundation
import TailscodeCore

/// Everything true about the turn right now, gathered once so the band that draws it has no logic
/// in it — and so the same facts can be asserted headlessly.
struct StatusFacts {
    enum Phase {
        case idle
        case working
        case compacting
        case awaitingApproval
        case awaitingAnswer
        case reconnecting
        case offline
        case failed(String)
    }

    var phase: Phase = .idle
    var elapsed: TimeInterval?
    var runningTool: String?
    var agents: [SubagentSummary] = []
    var activeAgents: Int { agents.filter(\.isActive).count }
    var finishedAgents: Int { agents.filter(\.isCompleted).count }
    var contextTokens: Int?
    var lastCostUSD: Double?
    var lastTurnTokens: Int?
    var goal: String?
    var goalMet = false
    var goalFailed = false
    var queued: Int = 0
    var attachments: Int = 0

    /// The transcript's own size in tokens, near enough to act on. No server reports context fill,
    /// and "you are near a compaction" is worth knowing even approximately — so this is derived
    /// from the characters actually in the conversation and always shown with a `~`.
    static func estimateContextTokens(_ messages: [ChatMessage]) -> Int? {
        var characters = 0
        for message in messages {
            for part in message.parts {
                switch part.kind {
                case .text(let text), .reasoning(let text):
                    characters += text.count
                case .tool(let call):
                    characters += (call.summary.displayOutput?.count ?? 0) + call.name.count
                        + (call.summary.command?.count ?? 0)
                case .compaction(let compaction):
                    // Everything before a compaction left the context; only its summary survives.
                    characters = compaction.summary?.count ?? 0
                case .file, .unknown:
                    continue
                }
            }
        }
        guard characters > 0 else { return nil }
        return characters / 4
    }

    static func from(
        state: ConversationState, turnStartedAt: Date?, agents: [SubagentSummary],
        usage: AgentUsage?, attachments: Int, contextTokens: Int? = nil
    ) -> StatusFacts {
        var facts = StatusFacts()
        if let failure = state.lastFailure {
            facts.phase = .failed(failure.message)
        } else {
            switch state.connection {
            case .offline: facts.phase = .offline
            case .reconnecting, .connecting: facts.phase = .reconnecting
            case .live:
                if state.compaction?.isRunning == true {
                    facts.phase = .compacting
                } else if !state.pendingPermissions.isEmpty {
                    facts.phase = .awaitingApproval
                } else if !state.pendingQuestions.isEmpty {
                    facts.phase = .awaitingAnswer
                } else if state.status == .running {
                    facts.phase = .working
                } else {
                    facts.phase = .idle
                }
            }
        }
        if let turnStartedAt { facts.elapsed = Date().timeIntervalSince(turnStartedAt) }
        facts.runningTool = Self.runningTool(in: state)
        facts.agents = agents
        facts.contextTokens = contextTokens
        facts.lastCostUSD = usage?.costUSD
        facts.lastTurnTokens = usage?.tokens
        if let goal = state.goal {
            facts.goal = goal.condition
            facts.goalMet = goal.isMet
            facts.goalFailed = goal.didFail
        }
        facts.attachments = attachments
        return facts
    }

    private static func runningTool(in state: ConversationState) -> String? {
        for message in state.messages.reversed() {
            for part in message.parts.reversed() {
                if case .tool(let call) = part.kind, call.status == .running { return call.name }
            }
            if message.role == .user { break }
        }
        return nil
    }

    /// What one fact on the band is: a glyph and a number, plus what happens when it is clicked —
    /// nothing, an action, or a list that unfolds. The band stays a line of counters; the detail
    /// lives one click away, which is the only way a status line survives a busy turn.
    struct Segment {
        enum Kind {
            case plain
            case act(Action)
            case menu([Row])
        }

        struct Row {
            let title: String
            let detail: String?
            let action: Action?
        }

        let text: String
        let css: String
        let kind: Kind

        var action: Action? {
            if case .act(let action) = kind { return action }
            return nil
        }

        var rows: [Row] {
            if case .menu(let rows) = kind { return rows }
            return []
        }
    }

    var segments: [Segment] {
        var result: [Segment] = []

        switch phase {
        case .idle:
            result.append(Segment(text: Localized.text("ready"), css: "seg-idle", kind: .plain))
        case .working:
            var text = "◐"
            if let elapsed { text += " " + TranscriptRow.clock(elapsed) }
            if let runningTool { text += " · " + runningTool }
            result.append(Segment(text: text, css: "seg-live", kind: .act(.stop)))
        case .compacting:
            result.append(
                Segment(text: Localized.text("◐ compacting"), css: "seg-warn", kind: .plain))
        case .awaitingApproval:
            result.append(
                Segment(
                    text: Localized.text("⏸ y / a / n"), css: "seg-warn",
                    kind: .act(.scrollToPending)))
        case .awaitingAnswer:
            result.append(
                Segment(
                    text: Localized.text("⏸ answer"), css: "seg-warn",
                    kind: .act(.scrollToPending)))
        case .reconnecting:
            result.append(
                Segment(text: Localized.text("· reconnecting"), css: "seg-warn", kind: .plain))
        case .offline:
            result.append(
                Segment(text: Localized.text("✗ offline"), css: "seg-error", kind: .act(.reconnect)))
        case .failed(let message):
            result.append(
                Segment(
                    text: "✗ " + String(message.prefix(60)), css: "seg-error", kind: .plain))
        }

        if !agents.isEmpty {
            let text = activeAgents > 0
                ? "▸ \(activeAgents)" + (finishedAgents > 0 ? " · \(finishedAgents)✓" : "")
                : "▸ \(finishedAgents)✓"
            result.append(
                Segment(
                    text: text, css: activeAgents > 0 ? "seg-agents" : "seg-dim",
                    kind: .menu(agentRows)))
        }

        if let contextTokens {
            result.append(
                Segment(
                    text: "~" + TranscriptRow.tokens(contextTokens),
                    css: contextTokens > 300_000 ? "seg-warn" : "seg-dim",
                    kind: .menu([
                        Segment.Row(
                            title: Localized.text("%@ tokens in this conversation, about",
                                TranscriptRow.tokens(contextTokens)),
                            detail: Localized.text("Estimated from the transcript itself"),
                            action: nil),
                        Segment.Row(
                            title: Localized.text("Compact…"),
                            detail: Localized.text("Trade the transcript for a summary"),
                            action: .compact),
                    ])))
        }
        if let lastCostUSD, lastCostUSD > 0 {
            result.append(
                Segment(
                    text: String(format: "$%.2f", lastCostUSD), css: "seg-dim",
                    kind: .menu([
                        Segment.Row(
                            title: Localized.text("Last turn cost %@", String(format: "$%.2f", lastCostUSD)),
                            detail: lastTurnTokens.map {
                                Localized.text("%@ tokens", TranscriptRow.tokens($0))
                            },
                            action: nil)
                    ])))
        } else if let lastTurnTokens, lastTurnTokens > 0 {
            result.append(
                Segment(
                    text: TranscriptRow.tokens(lastTurnTokens), css: "seg-dim", kind: .plain))
        }

        if let goal {
            let glyph = goalMet ? "✓" : goalFailed ? "✗" : "⦿"
            let css = goalMet ? "seg-idle" : goalFailed ? "seg-error" : "seg-goal"
            let state = goalMet
                ? Localized.text("met") : goalFailed ? Localized.text("failed") : Localized.text("being pursued")
            result.append(
                Segment(
                    text: glyph, css: css,
                    kind: .menu([
                        Segment.Row(title: goal, detail: state, action: nil),
                        Segment.Row(
                            title: Localized.text("Change the goal…"), detail: nil, action: .goal),
                    ])))
        }
        if attachments > 0 {
            result.append(Segment(text: "📎 \(attachments)", css: "seg-dim", kind: .plain))
        }
        return result
    }

    /// One row per subagent, newest first: what it is, whether it is still working, and how long
    /// ago it last said anything. Clicking one jumps to its card in the transcript.
    private var agentRows: [Segment.Row] {
        agents.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.updatedAt > rhs.updatedAt
        }.prefix(20).map { agent in
            let glyph = agent.isActive ? "◐" : agent.isCompleted ? "✓" : "·"
            let name = agent.agentType ?? SubagentSummary.untitled
            let age = TranscriptRow.clock(max(0, Date().timeIntervalSince(agent.updatedAt)))
            let state = agent.isActive
                ? Localized.text("working · %@ ago", age)
                : agent.isCompleted
                    ? Localized.text("done · %@ ago", age) : Localized.text("idle · %@ ago", age)
            return Segment.Row(
                title: "\(glyph) \(name) — \(String(agent.title.prefix(60)))",
                detail: state,
                action: .agent(agent.toolUseID ?? agent.id))
        }
    }

    enum Action: Equatable {
        case stop
        case compact
        case goal
        case scrollToPending
        case scrollToAgents
        case reconnect
        case agent(String)
    }
}

/// The band itself: a strip of clickable facts above the prompt box. Everything on it is either
/// something happening now or something you would act on — and clicking a fact does the obvious
/// thing to it, so reading the status and steering the turn are the same gesture.
enum StatusBand {
    /// A segment must never widen the column it sits in: the band ellipsizes, the conversation
    /// keeps its width.
    private static func clamp(_ widget: UnsafeMutablePointer<GtkWidget>) {
        gtk_widget_set_hexpand(widget, 0)
    }

    static func render(
        into box: UnsafeMutablePointer<GtkWidget>, facts: StatusFacts,
        notice: String?, perform: @escaping @Sendable (StatusFacts.Action) -> Void
    ) {
        Gtk.removeChildren(of: box)
        for segment in facts.segments {
            switch segment.kind {
            case .plain:
                let label = Gtk.label(segment.text, css: segment.css, selectable: false)
                Gtk.addClass(label, "seg")
                gtk_label_set_max_width_chars(op(label), 48)
                gtk_box_append(ptr(box), label)
            case .act(let action):
                let button = Gtk.button(segment.text, css: ["flat", "seg", segment.css]) {
                    perform(action)
                }
                clamp(button)
                gtk_box_append(ptr(box), button)
            case .menu(let rows):
                let button = Gtk.menuButton(segment.text, css: ["flat", "seg", segment.css]) {
                    rows.map { row in
                        (row.title, row.detail, { if let action = row.action { perform(action) } })
                    }
                }
                clamp(button)
                gtk_box_append(ptr(box), button)
            }
        }
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(box), spacer)
        if let notice, !notice.isEmpty {
            let label = Gtk.label(notice, css: "seg-notice", selectable: false)
            Gtk.addClass(label, "seg")
            gtk_box_append(ptr(box), label)
        }
    }
}
