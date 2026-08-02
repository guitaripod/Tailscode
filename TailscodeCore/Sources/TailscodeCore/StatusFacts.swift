import CodingAgentKit
import Foundation

/// Everything true about the turn right now, gathered once so the band that draws it has no logic
/// in it — and so the same facts can be asserted headlessly.
public struct StatusFacts: Sendable {
    public enum Phase: Sendable {
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

    public var phase: Phase = .idle
    public var elapsed: TimeInterval?
    public var runningTool: String?
    public var agents: [SubagentSummary] = []
    public var activeAgents: Int { agents.filter(\.isActive).count }
    public var finishedAgents: Int { agents.filter(\.isCompleted).count }
    public var contextTokens: Int?
    public var lastCostUSD: Double?
    public var lastTurnTokens: Int?
    public var goal: String?
    public var goalMet = false
    public var goalFailed = false
    public var queued: Int = 0
    public var attachments: Int = 0

    public init() {}

    /// The transcript's own size in tokens, near enough to act on. No server reports context fill,
    /// and "you are near a compaction" is worth knowing even approximately — so this is derived
    /// from the characters actually in the conversation and always shown with a `~`. Raw fields
    /// only: parsing every tool call's structured summary for a one-significant-digit estimate
    /// was most of the delay between a transcript arriving and the transcript appearing. A
    /// compaction resets the count: everything before it left the context, and only its summary
    /// survives.
    public static func estimateContextTokens(_ messages: [ChatMessage]) -> Int? {
        var characters = 0
        for message in messages {
            for part in message.parts {
                switch part.kind {
                case .text(let text), .reasoning(let text):
                    characters += text.count
                case .tool(let call):
                    characters += (call.output?.count ?? 0) + call.name.count + 120
                case .compaction(let compaction):
                    characters = compaction.summary?.count ?? 0
                case .file, .unknown:
                    continue
                }
            }
        }
        guard characters > 0 else { return nil }
        return characters / 4
    }

    public static func from(
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
    public struct Segment: Sendable {
        public enum Kind: Sendable {
            case plain
            case act(Action)
            case menu([Row])
        }

        public struct Row: Sendable {
            public let title: String
            public let detail: String?
            public let action: Action?
        }

        public let id: String
        public let text: String
        public let css: String
        public let kind: Kind

        public var action: Action? {
            if case .act(let action) = kind { return action }
            return nil
        }

        public var rows: [Row] {
            if case .menu(let rows) = kind { return rows }
            return []
        }
    }

    public var segments: [Segment] {
        var result: [Segment] = []

        switch phase {
        case .idle:
            result.append(Segment(id: "phase", text: Localized.text("ready"), css: "seg-idle", kind: .plain))
        case .working:
            var text = "◐"
            if let elapsed { text += " " + Self.clock(elapsed) }
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
                    id: "context", text: "~" + Self.tokens(contextTokens),
                    css: contextTokens > 300_000 ? "seg-warn" : "seg-dim",
                    kind: .menu([
                        Segment.Row(
                            title: Localized.text("%@ tokens in this conversation, about",
                                Self.tokens(contextTokens)),
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
                                Localized.text("%@ tokens", Self.tokens($0))
                            },
                            action: nil)
                    ])))
        } else if let lastTurnTokens, lastTurnTokens > 0 {
            result.append(
                Segment(
                    id: "cost", text: Self.tokens(lastTurnTokens), css: "seg-dim",
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

    /// One row per subagent: what it is, whether it is still working, and how long ago it last
    /// said anything. Clicking one jumps to its card in the transcript. What is running is the
    /// point, so working agents come first with what each is doing right now; recent finishes
    /// follow for context; the long tail of a session's past fan-outs — dozens of identical done
    /// rows — collapses into one count instead of drowning the list. A fan-out spawns twenty
    /// agents whose task descriptions all open the same way; the shared preamble is trimmed so
    /// each row shows the words that make it *this* agent.
    private var agentRows: [Segment.Row] {
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
            let age = Self.age(Date().timeIntervalSince(agent.updatedAt))
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
    public static func liveDetail(_ agent: SubagentSummary) -> String {
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
            parts.append(Self.clock(max(0, Date().timeIntervalSince(started))))
        }
        return parts.isEmpty ? Localized.text("working") : parts.joined(separator: " · ")
    }

    /// The character count every title in the list opens with — worth trimming only when the list
    /// is long enough for the repetition to drown the differences, and long enough to matter.
    public static func sharedPrefixLength(of titles: [String]) -> Int {
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

    public static func tokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }

    /// An age reads in the largest sensible unit — "2m", "3h", "2d" — where a stopwatch reading
    /// of "1789m 34s" would be noise.
    public static func age(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    public static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    public enum Action: Equatable, Sendable {
        case stop
        case compact
        case goal
        case scrollToPending
        case scrollToAgents
        case reconnect
        case agent(String)
    }
}
