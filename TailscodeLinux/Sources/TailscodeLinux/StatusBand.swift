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
        case connecting
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
    /// from the characters actually in the conversation and always shown with a `~`. Raw fields
    /// only: parsing every tool call's structured summary for a one-significant-digit estimate
    /// was most of the delay between a transcript arriving and the transcript appearing.
    static func estimateContextTokens(_ messages: [ChatMessage]) -> Int? {
        var characters = 0
        for message in messages {
            for part in message.parts {
                switch part.kind {
                case .text(let text), .reasoning(let text):
                    characters += text.count
                case .tool(let call):
                    characters += (call.output?.count ?? 0) + call.name.count + 120
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
            case .connecting: facts.phase = .connecting
            case .reconnecting: facts.phase = .reconnecting
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

        let id: String
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
            result.append(Segment(id: "phase", text: Localized.text("ready"), css: "seg-idle", kind: .plain))
        case .working:
            var text = "◐"
            if let elapsed { text += " " + TranscriptRow.clock(elapsed) }
            if let runningTool { text += " · " + runningTool }
            result.append(Segment(id: "phase", text: text, css: "seg-live", kind: .act(.stop)))
        case .compacting:
            result.append(
                Segment(id: "phase", text: Localized.text("◐ compacting"), css: "seg-warn", kind: .plain))
        case .awaitingApproval:
            result.append(
                Segment(
                    id: "phase", text: Localized.text("⏸ y / a / n"), css: "seg-warn",
                    kind: .act(.scrollToPending)))
        case .awaitingAnswer:
            result.append(
                Segment(
                    id: "phase", text: Localized.text("⏸ answer"), css: "seg-warn",
                    kind: .act(.scrollToPending)))
        case .connecting:
            result.append(
                Segment(id: "phase", text: Localized.text("· connecting"), css: "seg-dim", kind: .plain))
        case .reconnecting:
            result.append(
                Segment(id: "phase", text: Localized.text("· reconnecting"), css: "seg-warn", kind: .plain))
        case .offline:
            result.append(
                Segment(id: "phase", text: Localized.text("✗ offline"), css: "seg-error", kind: .act(.reconnect)))
        case .failed(let message):
            result.append(
                Segment(
                    id: "phase", text: "✗ " + String(message.prefix(60)), css: "seg-error",
                    kind: .plain))
        }

        if !agents.isEmpty {
            let text = activeAgents > 0
                ? "▸ \(activeAgents)" + (finishedAgents > 0 ? " · \(finishedAgents)✓" : "")
                : "▸ \(finishedAgents)✓"
            result.append(
                Segment(
                    id: "agents", text: text, css: activeAgents > 0 ? "seg-agents" : "seg-dim",
                    kind: .menu(agentRows)))
        }

        if let contextTokens {
            result.append(
                Segment(
                    id: "context", text: "~" + TranscriptRow.tokens(contextTokens),
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
                    id: "cost", text: String(format: "$%.2f", lastCostUSD), css: "seg-dim",
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
                    id: "cost", text: TranscriptRow.tokens(lastTurnTokens), css: "seg-dim",
                    kind: .plain))
        }

        if let goal {
            let glyph = goalMet ? "✓" : goalFailed ? "✗" : "⦿"
            let css = goalMet ? "seg-idle" : goalFailed ? "seg-error" : "seg-goal"
            let state = goalMet
                ? Localized.text("met") : goalFailed ? Localized.text("failed") : Localized.text("being pursued")
            result.append(
                Segment(
                    id: "goal", text: glyph, css: css,
                    kind: .menu([
                        Segment.Row(title: goal, detail: state, action: nil),
                        Segment.Row(
                            title: Localized.text("Change the goal…"), detail: nil, action: .goal),
                    ])))
        }
        if attachments > 0 {
            result.append(Segment(id: "attach", text: "📎 \(attachments)", css: "seg-dim", kind: .plain))
        }
        return result
    }

    /// One row per subagent, newest first: what it is, whether it is still working, and how long
    /// ago it last said anything. Clicking one jumps to its card in the transcript. A fan-out
    /// spawns twenty agents whose task descriptions all open the same way; the shared preamble is
    /// trimmed so each row shows the words that make it *this* agent.
    private var agentRows: [Segment.Row] {
        // What is running is the point. Working agents come first with what each is doing right
        // now; recent finishes follow for context; the long tail of a session's past fan-outs —
        // dozens of identical done rows — collapses into one count instead of drowning the list.
        let sorted = agents.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            return lhs.updatedAt > rhs.updatedAt
        }
        let working = sorted.filter(\.isActive)
        let rest = sorted.filter { !$0.isActive }
        let restShown = rest.prefix(working.isEmpty ? 12 : 6)
        let buried = rest.count - restShown.count

        let shared = Self.sharedPrefixLength(of: (working + restShown).map(\.title))
        func trimmed(_ title: String) -> String {
            guard shared > 0, title.count > shared else { return String(title.prefix(60)) }
            return "…"
                + String(title.dropFirst(shared)).trimmingCharacters(in: .whitespaces).prefix(60)
        }

        var rows = working.map { agent in
            let name = agent.agentType ?? SubagentSummary.untitled
            return Segment.Row(
                title: "◐ \(name) — \(trimmed(agent.title))",
                detail: Self.liveDetail(agent),
                action: .agent(agent.toolUseID ?? agent.id))
        }
        rows += restShown.map { agent in
            let glyph = agent.isCompleted ? "✓" : "·"
            let name = agent.agentType ?? SubagentSummary.untitled
            let age = TranscriptRow.age(Date().timeIntervalSince(agent.updatedAt))
            let state = agent.isCompleted
                ? Localized.text("done · %@ ago", age) : Localized.text("idle · %@ ago", age)
            return Segment.Row(
                title: "\(glyph) \(name) — \(trimmed(agent.title))",
                detail: state,
                action: .agent(agent.toolUseID ?? agent.id))
        }
        if buried > 0 {
            rows.append(
                Segment.Row(
                    title: Localized.text("… %@ earlier agents", "\(buried)"),
                    detail: Localized.text("finished in past fan-outs"),
                    action: nil))
        }
        return rows
    }

    /// One line saying what a live agent is doing: its todo position when it keeps a list,
    /// otherwise its tool trail — count, elapsed, and the tool running at this moment.
    static func liveDetail(_ agent: SubagentSummary) -> String {
        var parts: [String] = []
        if let done = agent.todosDone, let total = agent.todosTotal, total > 0 {
            parts.append("\(done)/\(total)")
            if let current = agent.currentTodo, !current.isEmpty {
                parts.append(String(current.prefix(48)))
            }
        } else if let current = agent.currentTool, !current.isEmpty {
            if let count = agent.toolCount { parts.append(Localized.text("%@ tools", "\(count)")) }
            parts.append(String(current.prefix(48)))
        }
        if let started = agent.startedAt {
            parts.append(TranscriptRow.clock(max(0, Date().timeIntervalSince(started))))
        }
        return parts.isEmpty ? Localized.text("working") : parts.joined(separator: " · ")
    }

    /// The character count every title in the list opens with — worth trimming only when the list
    /// is long enough for the repetition to drown the differences, and long enough to matter.
    static func sharedPrefixLength(of titles: [String]) -> Int {
        guard titles.count > 2, let first = titles.first.map(Array.init) else { return 0 }
        var shared = first.count
        for title in titles.dropFirst() {
            let characters = Array(title)
            var index = 0
            while index < min(shared, characters.count), characters[index] == first[index] {
                index += 1
            }
            shared = index
        }
        return shared >= 24 ? shared : 0
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

    /// What the band keeps between renders: the widget for each fact, and the latest facts the
    /// popovers read from. A rebuilt widget is a closed popover, and this band redraws every
    /// second while a turn runs — so a segment that is still on screen is updated in place, and
    /// its list reads the newest facts at the moment it is opened.
    final class State: @unchecked Sendable {
        var facts = StatusFacts()
        fileprivate var widgets: [String: UInt] = [:]

        /// Test-driver access: pops the popover of a menu segment, the way a click would.
        func openMenu(id: String) {
            guard let bits = widgets[id], let raw = UnsafeMutableRawPointer(bitPattern: bits)
            else { return }
            gtk_menu_button_popup(op(raw))
        }
        fileprivate var kinds: [String: String] = [:]
        fileprivate var notice: UInt = 0
        fileprivate var spacer: UInt = 0
    }

    private static func kindTag(_ segment: StatusFacts.Segment) -> String {
        switch segment.kind {
        case .plain: return "plain"
        case .act: return "act"
        case .menu: return "menu"
        }
    }

    static func render(
        into box: UnsafeMutablePointer<GtkWidget>, state: State, facts: StatusFacts,
        notice: String?, perform: @escaping @Sendable (StatusFacts.Action) -> Void
    ) {
        state.facts = facts
        let segments = facts.segments
        let wanted = Set(segments.map(\.id))

        for (id, bits) in state.widgets where !wanted.contains(id) {
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) {
                gtk_box_remove(ptr(box), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
            }
            state.widgets[id] = nil
            state.kinds[id] = nil
        }

        var previous: UnsafeMutablePointer<GtkWidget>?
        for segment in segments {
            let tag = kindTag(segment)
            if let bits = state.widgets[segment.id], state.kinds[segment.id] == tag,
                let raw = UnsafeMutableRawPointer(bitPattern: bits)
            {
                let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
                update(widget, segment: segment)
                previous = widget
                continue
            }
            if let bits = state.widgets[segment.id],
                let raw = UnsafeMutableRawPointer(bitPattern: bits)
            {
                gtk_box_remove(ptr(box), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
            }
            let widget = make(segment, state: state, perform: perform)
            gtk_box_insert_child_after(ptr(box), widget, previous)
            state.widgets[segment.id] = UInt(bitPattern: widget)
            state.kinds[segment.id] = tag
            previous = widget
        }

        if state.spacer == 0 {
            let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_hexpand(spacer, 1)
            gtk_box_append(ptr(box), spacer)
            state.spacer = UInt(bitPattern: spacer)
        }
        if state.notice == 0 {
            let label = Gtk.label("", css: "seg-notice", selectable: false)
            Gtk.addClass(label, "seg")
            gtk_box_append(ptr(box), label)
            state.notice = UInt(bitPattern: label)
        }
        if let raw = UnsafeMutableRawPointer(bitPattern: state.notice) {
            let label: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            gtk_label_set_text(op(label), notice ?? "")
            gtk_widget_set_visible(label, (notice?.isEmpty == false) ? 1 : 0)
        }
    }

    private static func update(
        _ widget: UnsafeMutablePointer<GtkWidget>, segment: StatusFacts.Segment
    ) {
        switch segment.kind {
        case .plain: gtk_label_set_text(op(widget), segment.text)
        case .act: gtk_button_set_label(ptr(widget), segment.text)
        case .menu: gtk_menu_button_set_label(op(widget), segment.text)
        }
        for css in ["seg-idle", "seg-dim", "seg-live", "seg-warn", "seg-error", "seg-agents", "seg-goal"]
        where css != segment.css {
            gtk_widget_remove_css_class(widget, css)
        }
        Gtk.addClass(widget, segment.css)
    }

    private static func make(
        _ segment: StatusFacts.Segment, state: State,
        perform: @escaping @Sendable (StatusFacts.Action) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        switch segment.kind {
        case .plain:
            let label = Gtk.label(segment.text, css: segment.css, selectable: false)
            Gtk.addClass(label, "seg")
            gtk_label_set_max_width_chars(op(label), 48)
            return label
        case .act(let action):
            let button = Gtk.button(segment.text, css: ["flat", "seg", segment.css]) {
                perform(action)
            }
            clamp(button)
            return button
        case .menu:
            let id = segment.id
            let button = Gtk.menuButton(segment.text, css: ["flat", "seg", segment.css]) {
                // Read at open time, so a list opened mid-turn is the list as it is now.
                let rows = state.facts.segments.first { $0.id == id }?.rows ?? []
                return rows.map { row in
                    (row.title, row.detail, { if let action = row.action { perform(action) } })
                }
            }
            clamp(button)
            return button
        }
    }
}
