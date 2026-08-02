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
    var activeAgents: Int = 0
    var finishedAgents: Int = 0
    var agentTitles: [String] = []
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
        usage: AgentUsage?, attachments: Int
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
        facts.activeAgents = agents.filter(\.isActive).count
        facts.finishedAgents = agents.filter(\.isCompleted).count
        facts.agentTitles = agents.filter(\.isActive).map { $0.agentType ?? $0.title }
        facts.contextTokens = estimateContextTokens(state.messages)
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

    /// The band as text, in the order it is drawn. One segment per fact that is true, and nothing
    /// for the facts that are not — a status line that always shows every field is a status line
    /// nobody reads.
    var segments: [(text: String, css: String, action: Action?)] {
        var result: [(String, String, Action?)] = []

        switch phase {
        case .idle:
            result.append((Localized.text("ready"), "seg-idle", nil))
        case .working:
            var text = "◐ " + Localized.text("working")
            if let elapsed { text += " " + TranscriptRow.clock(elapsed) }
            if let runningTool { text += " · " + runningTool }
            result.append((text, "seg-live", .stop))
        case .compacting:
            result.append((Localized.text("◐ compacting — minutes, not seconds"), "seg-warn", nil))
        case .awaitingApproval:
            result.append((Localized.text("⏸ needs you · y / a / n"), "seg-warn", .scrollToPending))
        case .awaitingAnswer:
            result.append((Localized.text("⏸ waiting for your answer"), "seg-warn", .scrollToPending))
        case .reconnecting:
            result.append((Localized.text("· reconnecting"), "seg-warn", nil))
        case .offline:
            result.append((Localized.text("✗ offline"), "seg-error", .reconnect))
        case .failed(let message):
            result.append(("✗ " + message, "seg-error", nil))
        }

        if activeAgents > 0 {
            var text = "▸ " + Localized.text("%@ agents", "\(activeAgents)")
            let named = agentTitles.prefix(2).joined(separator: ", ")
            if !named.isEmpty { text += " · " + named }
            if finishedAgents > 0 { text += " · \(finishedAgents) done" }
            result.append((text, "seg-agents", .scrollToAgents))
        } else if finishedAgents > 0 {
            result.append(
                ("▸ " + Localized.text("%@ agents done", "\(finishedAgents)"), "seg-dim", .scrollToAgents))
        }

        if let contextTokens {
            let text = "~" + TranscriptRow.tokens(contextTokens) + " " + Localized.text("in context")
            let css = contextTokens > 300_000 ? "seg-warn" : "seg-dim"
            result.append((text, css, .compact))
        }
        if let lastCostUSD, lastCostUSD > 0 {
            result.append((String(format: "$%.2f", lastCostUSD), "seg-dim", nil))
        } else if let lastTurnTokens, lastTurnTokens > 0 {
            result.append(
                (TranscriptRow.tokens(lastTurnTokens) + " " + Localized.text("last turn"),
                 "seg-dim", nil))
        }

        if let goal {
            let glyph = goalMet ? "✓" : goalFailed ? "✗" : "⦿"
            let css = goalMet ? "seg-idle" : goalFailed ? "seg-error" : "seg-goal"
            result.append(("\(glyph) \(goal)", css, .goal))
        }
        if attachments > 0 {
            result.append(
                ("📎 " + Localized.text("%@ attached", "\(attachments)"), "seg-dim", nil))
        }
        return result
    }

    enum Action {
        case stop
        case compact
        case goal
        case scrollToPending
        case scrollToAgents
        case reconnect
    }
}

/// The band itself: a strip of clickable facts above the prompt box. Everything on it is either
/// something happening now or something you would act on — and clicking a fact does the obvious
/// thing to it, so reading the status and steering the turn are the same gesture.
enum StatusBand {
    static func render(
        into box: UnsafeMutablePointer<GtkWidget>, facts: StatusFacts,
        notice: String?, perform: @escaping @Sendable (StatusFacts.Action) -> Void
    ) {
        Gtk.removeChildren(of: box)
        for segment in facts.segments {
            if let action = segment.action {
                let button = Gtk.button(segment.text, css: ["flat", "seg", segment.css]) {
                    perform(action)
                }
                // A segment must never widen the column it sits in: the band ellipsizes, the
                // conversation keeps its width.
                if let child = gtk_button_get_child(ptr(button)) {
                    gtk_label_set_ellipsize(op(child), PANGO_ELLIPSIZE_END)
                    gtk_label_set_max_width_chars(op(child), 48)
                }
                gtk_box_append(ptr(box), button)
            } else {
                let label = Gtk.label(segment.text, css: segment.css, selectable: false)
                Gtk.addClass(label, "seg")
                gtk_label_set_max_width_chars(op(label), 48)
                gtk_box_append(ptr(box), label)
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
