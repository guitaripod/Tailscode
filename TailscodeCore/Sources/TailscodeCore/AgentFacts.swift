import CodingAgentKit
import Foundation

/// What an agent is waiting on a person for, with the words to answer it in place.
public struct AgentAsk: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A tool the agent will not run until it is allowed: approve or deny it.
        case approval(PermissionRequest)
        /// A question the agent put to the person, with the options it offered.
        case question(QuestionRequest)
    }

    public let kind: Kind
    public let lead: String
    public let object: String?
    public let options: [String]
    public let since: Date?

    public init(kind: Kind, lead: String, object: String?, options: [String], since: Date?) {
        self.kind = kind
        self.lead = lead
        self.object = object
        self.options = options
        self.since = since
    }

    public var id: String {
        switch kind {
        case .approval(let request): return request.id
        case .question(let request): return request.id
        }
    }

    public var isApproval: Bool {
        if case .approval = kind { return true }
        return false
    }

    /// The ask a conversation holds, if it holds one: a question outranks an approval the way the
    /// status band's own order says.
    public static func reading(in state: ConversationState, since: Date? = nil) -> AgentAsk? {
        guard let said = ApprovalAsk.reading(in: state, whole: true) else { return nil }
        if let question = state.pendingQuestions.first {
            let options = question.questions.first?.options.map(\.label) ?? []
            return AgentAsk(
                kind: .question(question), lead: said.lead, object: said.object, options: options,
                since: since)
        }
        guard let permission = state.pendingPermissions.first else { return nil }
        return AgentAsk(
            kind: .approval(permission), lead: said.lead, object: said.object, options: [],
            since: since)
    }
}

/// One agent working for a session: a subagent, or the work the process is carrying on its own.
public struct AgentChild: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case agent
        case background
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let line: String
    public let todos: (done: Int, total: Int)?
    public let startedAt: Date?
    public let isActive: Bool

    public init(
        id: String, kind: Kind, title: String, line: String, todos: (done: Int, total: Int)?,
        startedAt: Date?, isActive: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.line = line
        self.todos = todos
        self.startedAt = startedAt
        self.isActive = isActive
    }

    public static func == (lhs: AgentChild, rhs: AgentChild) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.line == rhs.line
            && lhs.todos?.done == rhs.todos?.done && lhs.todos?.total == rhs.todos?.total
            && lhs.startedAt == rhs.startedAt && lhs.isActive == rhs.isActive
    }
}

/// What a session this device is watching first-hand says right now, distilled once from its
/// conversation so a board, its peek and its hour read the same facts.
public struct AgentFacts: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case working
        case needsYou
        case retrying(attempt: Int)
        case background(tasks: Int, stalled: Bool)
        case idle
    }

    public let phase: Phase
    public let detail: LiveActivityDetail
    public let doing: String?
    public let object: AgentObject?
    public let tool: String?
    public let steps: [AgentStep]
    public let touched: [String]
    public let toolCount: Int
    public let startedAt: Date?
    public let endedAt: Date?
    public let ask: AgentAsk?
    public let children: [AgentChild]
    public let fill: ContextFill?
    public let tokens: Int?
    public let cost: Double?
    public let model: ModelSelection?
    public let effort: String?
    public let beat: [Int]
    public let failed: Bool
    /// What the open turn is doing, nil when none is open: the reading that tells a turn thinking
    /// from one whose tool is out.
    public let activity: ActivityKind?

    public var isRunning: Bool {
        switch phase {
        case .working, .needsYou, .retrying: return true
        case .background, .idle: return false
        }
    }

    /// Reads a conversation. `seen` is when this device first saw each call, and `stamps` when it
    /// saw the conversation move: both are facts about the watcher, not the server.
    public static func read(
        state: ConversationState, agents: [SubagentSummary], seen: [String: Date] = [:],
        stamps: [Date] = [], now: Date, catalog: [ModelInfo] = []
    ) -> AgentFacts {
        let live = LiveActivityReading.live(in: state)
        let ask = AgentAsk.reading(in: state, since: ask(since: state, seen: seen))
        let phase: Phase
        if ask != nil {
            phase = .needsYou
        } else if let retry = state.retry, state.status == .running {
            phase = .retrying(attempt: retry.attempt)
        } else if state.status == .running || state.compaction?.isRunning == true {
            phase = .working
        } else if let work = state.backgroundWork {
            phase = .background(tasks: work.tasks, stalled: work.stalled)
        } else {
            phase = .idle
        }
        let settled = phase == .idle ? LiveActivityReading.settled(from: state) : nil
        var steps = AgentLine.steps(in: state)
        for index in steps.indices { steps[index].seen = seen[steps[index].id] }
        let assistant = state.messages.last { $0.role == .assistant }
        let selection = assistant?.modelID.map {
            ModelSelection(providerID: assistant?.providerID ?? "", modelID: $0)
        }
        let turn = turnMessages(in: state)
        let tokens = turn.compactMap { $0.usage?.total ?? $0.totalTokens }.reduce(0, +)
        let cost = turn.compactMap(\.costUSD).reduce(0, +)
        return AgentFacts(
            phase: phase, detail: settled?.detail ?? live.detail,
            doing: phase == .idle ? nil : AgentLine.doing(in: state),
            object: phase == .idle ? nil : AgentLine.object(in: state), tool: live.tool, steps: steps,
            touched: AgentLine.touched(in: state), toolCount: live.toolCount,
            startedAt: live.startedAt, endedAt: settled?.endedAt, ask: ask,
            children: children(agents: agents, background: state.backgroundWork, now: now),
            fill: ContextFill.read(messages: state.messages, catalog: catalog),
            tokens: tokens > 0 ? tokens : nil, cost: cost > 0 ? cost : nil, model: selection,
            effort: assistant?.reasoningEffort, beat: AgentBeat.read(stamps: stamps, now: now),
            failed: state.lastFailure != nil,
            activity: phase == .idle ? nil : ActivityKind.inFlight(in: state))
    }

    private static func ask(since state: ConversationState, seen: [String: Date]) -> Date? {
        let id = state.pendingQuestions.first?.id ?? state.pendingPermissions.first?.id
        return id.flatMap { seen[$0] }
    }

    private static func turnMessages(in state: ConversationState) -> [ChatMessage] {
        var turn: [ChatMessage] = []
        for message in state.messages.reversed() {
            if message.role == .user { break }
            turn.append(message)
        }
        return turn
    }

    private static func children(
        agents: [SubagentSummary], background: BackgroundWork?, now: Date
    ) -> [AgentChild] {
        var children = agents.filter { $0.isActive && !$0.isCompleted }.map { agent in
            AgentChild(
                id: agent.id, kind: .agent,
                title: agent.title.isEmpty ? SubagentSummary.untitled : agent.title,
                line: StatusFacts.liveDetail(agent, at: now, under: .going),
                todos: agent.todosTotal.flatMap { total in
                    total > 0 ? (agent.todosDone ?? 0, total) : nil
                },
                startedAt: agent.startedAt, isActive: true)
        }
        if let work = background, work.tasks > 0 {
            children.append(
                AgentChild(
                    id: "background", kind: .background,
                    title: work.task ?? Localized.text("Background work"),
                    line: work.stalled
                        ? Localized.text("stuck")
                        : Localized.text("in the background"),
                    todos: nil, startedAt: work.since, isActive: !work.stalled))
        }
        return children
    }
}
