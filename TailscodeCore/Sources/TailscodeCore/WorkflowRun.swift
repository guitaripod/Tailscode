import CodingAgentKit
import Foundation

/// One `phase()` group a workflow script declares in its `meta`, in the order the script lists it.
public struct WorkflowPhase: Sendable, Hashable, Identifiable {
    public let index: Int
    public let title: String
    public let detail: String?
    public let model: String?

    public var id: Int { index }

    public init(index: Int, title: String, detail: String? = nil, model: String? = nil) {
        self.index = index
        self.title = title
        self.detail = detail
        self.model = model
    }
}

/// The `export const meta = {…}` header every workflow script opens with. The block is a JavaScript
/// literal rather than JSON — unquoted keys, single quotes, trailing commas — so it is read with a
/// scanner that takes what it recognises and leaves the rest, never a parser that fails whole.
public struct WorkflowMeta: Sendable, Hashable {
    public let name: String?
    public let summary: String?
    public let phases: [WorkflowPhase]

    public init(name: String?, summary: String? = nil, phases: [WorkflowPhase] = []) {
        self.name = name
        self.summary = summary
        self.phases = phases
    }

    public static func parse(script: String) -> WorkflowMeta? {
        guard let body = metaBody(in: script) else { return nil }
        return WorkflowMeta(
            name: value(of: "name", in: body),
            summary: value(of: "description", in: body),
            phases: phases(in: body))
    }

    /// The braces of the `meta` object literal, matched by depth so a brace inside one of its
    /// strings or a nested phase entry does not end the block early.
    private static func metaBody(in script: String) -> Substring? {
        guard let marker = script.range(of: "meta"),
            let open = script[marker.upperBound...].firstIndex(of: "{")
        else { return nil }
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = open
        while index < script.endIndex {
            let character = script[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return script[script.index(after: open)..<index] }
            }
            index = script.index(after: index)
        }
        return nil
    }

    /// A `key: 'value'` pair at any depth of the block, honouring both quote styles and backslash
    /// escapes. Multi-line template strings keep their newlines; the caller decides how to show one.
    private static func value(of key: String, in body: Substring) -> String? {
        var search = body.startIndex
        while let found = body.range(of: key, range: search..<body.endIndex) {
            search = found.upperBound
            var index = found.upperBound
            while index < body.endIndex, body[index] == " " { index = body.index(after: index) }
            guard index < body.endIndex, body[index] == ":" else { continue }
            index = body.index(after: index)
            while index < body.endIndex, body[index] == " " || body[index] == "\n" {
                index = body.index(after: index)
            }
            guard index < body.endIndex else { return nil }
            let opener = body[index]
            guard opener == "'" || opener == "\"" || opener == "`" else { continue }
            var text = ""
            var escaped = false
            index = body.index(after: index)
            while index < body.endIndex {
                let character = body[index]
                if escaped {
                    text.append(character == "n" ? "\n" : character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == opener {
                    return text
                } else {
                    text.append(character)
                }
                index = body.index(after: index)
            }
            return text
        }
        return nil
    }

    private static func phases(in body: Substring) -> [WorkflowPhase] {
        guard let list = arrayBody(of: "phases", in: body) else { return [] }
        return objectBodies(in: list).enumerated().compactMap { index, entry in
            guard let title = value(of: "title", in: entry) else { return nil }
            return WorkflowPhase(
                index: index, title: title, detail: value(of: "detail", in: entry),
                model: value(of: "model", in: entry))
        }
    }

    private static func arrayBody(of key: String, in body: Substring) -> Substring? {
        guard let found = body.range(of: "\(key):") ?? body.range(of: "\(key) :"),
            let open = body[found.upperBound...].firstIndex(of: "[")
        else { return nil }
        var depth = 0
        var index = open
        while index < body.endIndex {
            if body[index] == "[" { depth += 1 }
            if body[index] == "]" {
                depth -= 1
                if depth == 0 { return body[body.index(after: open)..<index] }
            }
            index = body.index(after: index)
        }
        return nil
    }

    private static func objectBodies(in list: Substring) -> [Substring] {
        var bodies: [Substring] = []
        var depth = 0
        var start: Substring.Index?
        var index = list.startIndex
        while index < list.endIndex {
            if list[index] == "{" {
                if depth == 0 { start = list.index(after: index) }
                depth += 1
            } else if list[index] == "}" {
                depth -= 1
                if depth == 0, let open = start { bodies.append(list[open..<index]) }
            }
            index = list.index(after: index)
        }
        return bodies
    }
}

/// What the Workflow tool answers with the moment it hands the run to the background: the ids that
/// name the run everywhere else, so a card can bind the agents and the completion to the call.
public struct WorkflowLaunch: Sendable, Hashable {
    public let runID: String?
    public let taskID: String?
    public let transcriptDirectory: String?

    public init(runID: String? = nil, taskID: String? = nil, transcriptDirectory: String? = nil) {
        self.runID = runID
        self.taskID = taskID
        self.transcriptDirectory = transcriptDirectory
    }

    public var isEmpty: Bool { runID == nil && taskID == nil }

    public static func parse(output: String) -> WorkflowLaunch {
        WorkflowLaunch(
            runID: field("Run ID:", in: output),
            taskID: field("Task ID:", in: output),
            transcriptDirectory: field("Transcript dir:", in: output))
    }

    private static func field(_ label: String, in output: String) -> String? {
        guard let range = output.range(of: label) else { return nil }
        let rest = output[range.upperBound...]
        let line = rest.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }
}

/// One agent inside a run, as the transcript can describe it while it is still working.
public struct WorkflowAgent: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let model: String?
    public let isActive: Bool
    public let isCompleted: Bool
    public let currentTool: String?
    public let toolCount: Int?
    public let startedAt: Date?
    public let updatedAt: Date

    public init(
        id: String, title: String, model: String? = nil, isActive: Bool, isCompleted: Bool,
        currentTool: String? = nil, toolCount: Int? = nil, startedAt: Date? = nil, updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.model = model
        self.isActive = isActive
        self.isCompleted = isCompleted
        self.currentTool = currentTool
        self.toolCount = toolCount
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public init(_ summary: SubagentSummary) {
        self.init(
            id: summary.id, title: summary.title, model: nil, isActive: summary.isActive,
            isCompleted: summary.isCompleted, currentTool: summary.currentTool,
            toolCount: summary.toolCount, startedAt: summary.startedAt,
            updatedAt: summary.updatedAt)
    }

    public func elapsed(at now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (isCompleted ? updatedAt : now).timeIntervalSince(startedAt))
    }
}

/// A workflow run as the conversation can know it. The Workflow tool returns the moment the run is
/// handed to the background, so the tool call's own status says only that it launched; the run's
/// real progress is its agents arriving, working and finishing, and its answer comes back later as
/// its own message. Nothing here infers which phase an agent belongs to: only the finished run
/// records that, so a live card shows the plan and the agents, never a guessed position in it.
public struct WorkflowRun: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case launching
        case running
        case finished
        case failed(String)
    }

    public let id: String
    public let name: String
    public let summary: String?
    public let phases: [WorkflowPhase]
    public let launch: WorkflowLaunch
    public let agents: [WorkflowAgent]
    public let state: State
    public let startedAt: Date?
    public let finishedAt: Date?
    public let result: String?

    public init(
        id: String, name: String, summary: String? = nil, phases: [WorkflowPhase] = [],
        launch: WorkflowLaunch = WorkflowLaunch(), agents: [WorkflowAgent] = [],
        state: State, startedAt: Date? = nil, finishedAt: Date? = nil, result: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.phases = phases
        self.launch = launch
        self.agents = agents
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.result = result
    }

    public var doneCount: Int { agents.count(where: \.isCompleted) }
    public var runningCount: Int { agents.count(where: { $0.isActive && !$0.isCompleted }) }
    public var isLive: Bool {
        switch state {
        case .launching, .running: return true
        case .finished, .failed: return false
        }
    }

    /// Fraction of the agents seen so far that have finished. A run does not announce how many it
    /// will spawn, so this is honest about what it measures: progress through the fan-out in hand,
    /// not through a total nobody has yet promised. A finished run is whole by definition.
    public var progress: Double {
        if case .finished = state { return 1 }
        guard !agents.isEmpty else { return 0 }
        return Double(doneCount) / Double(agents.count)
    }

    public func elapsed(at now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    /// The one line a collapsed card wears: what the run is doing, in the run's own terms.
    public func headline(at now: Date) -> String {
        switch state {
        case .launching:
            return Localized.text("Starting…")
        case .running:
            if runningCount > 0, doneCount > 0 {
                return Localized.text("%lld done", doneCount) + " · "
                    + Localized.text("%lld running", runningCount)
            }
            if runningCount > 0 { return Localized.text("%lld running", runningCount) }
            if doneCount > 0 { return Localized.text("%lld done", doneCount) }
            return Localized.text("Working…")
        case .finished:
            let agents = Localized.text("%lld agents", self.agents.count)
            guard let elapsed = elapsed(at: now) else { return agents }
            return agents + " · " + Self.duration(elapsed)
        case .failed(let reason):
            return reason
        }
    }

    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds >= 3600 {
            return "\(seconds / 3600)h\(String(format: "%02d", (seconds % 3600) / 60))m"
        }
        if seconds >= 60 { return "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s" }
        return "\(seconds)s"
    }
}

/// Folds a conversation's Workflow tool calls and the agents trailing them into runs. Workflow
/// agents carry no spawning call of their own, so they are seated against the run that could have
/// fanned them out: the newest launch that had already been made when the agent first appeared.
public enum WorkflowRunAssembly {
    public static let agentType = "workflow-subagent"

    public struct Launch: Sendable {
        public let call: ToolCall
        public let at: Date?

        public init(call: ToolCall, at: Date?) {
            self.call = call
            self.at = at
        }
    }

    public static func runs(
        launches: [Launch], agents: [SubagentSummary], completions: [String: String] = [:],
        now: Date
    ) -> [WorkflowRun] {
        let ordered = launches.sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        let workflowAgents = agents
            .filter { $0.agentType == agentType }
            .sorted { $0.updatedAt < $1.updatedAt }
        var seated: [String: [WorkflowAgent]] = [:]
        for agent in workflowAgents {
            guard let owner = owner(of: agent, among: ordered) else { continue }
            seated[owner, default: []].append(WorkflowAgent(agent))
        }
        return ordered.map { launch in
            run(launch, agents: seated[launch.call.id] ?? [], completions: completions, now: now)
        }
    }

    private static func owner(of agent: SubagentSummary, among launches: [Launch]) -> String? {
        let started = agent.startedAt ?? agent.updatedAt
        let candidate = launches.last { ($0.at ?? .distantPast) <= started } ?? launches.last
        return candidate?.call.id
    }

    private static func run(
        _ launch: Launch, agents: [WorkflowAgent], completions: [String: String], now: Date
    ) -> WorkflowRun {
        let call = launch.call
        let script = string(call.input, "script")
        let meta = script.flatMap(WorkflowMeta.parse)
        let name =
            string(call.input, "name") ?? meta?.name ?? call.title
            ?? Localized.text("Workflow")
        let output = call.output ?? ""
        let launchIDs = WorkflowLaunch.parse(output: output)
        let result = launchIDs.taskID.flatMap { completions[$0] }
        let state: WorkflowRun.State
        if call.status == .error {
            state = .failed(firstLine(output) ?? Localized.text("Workflow failed"))
        } else if result != nil {
            state = .finished
        } else if launchIDs.isEmpty, call.status == .running {
            state = .launching
        } else {
            state = .running
        }
        return WorkflowRun(
            id: call.id, name: name, summary: meta?.summary, phases: meta?.phases ?? [],
            launch: launchIDs, agents: agents, state: state, startedAt: launch.at,
            finishedAt: result != nil ? agents.map(\.updatedAt).max() ?? now : nil,
            result: result)
    }

    private static func string(_ input: JSONValue?, _ key: String) -> String? {
        guard case .object(let fields)? = input, case .string(let value)? = fields[key],
            !value.isEmpty
        else { return nil }
        return value
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return (line?.isEmpty ?? true) ? nil : line
    }
}
