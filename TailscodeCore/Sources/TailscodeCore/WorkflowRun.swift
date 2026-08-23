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
/// real progress is its agents arriving, working and finishing, and its ending arrives long
/// afterwards as the harness's own report of the task, carried on the call that started it. Nothing here infers which phase an agent belongs to: only the finished run
/// records that, so a live card shows the plan and the agents, never a guessed position in it.
public struct WorkflowRun: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case launching
        case running
        case finished
        /// Over without an answer and without a fault: a timeout, a teardown, someone pressing
        /// stop, a harness that died holding the run. Kept apart from ``failed`` because a card
        /// that paints a stop as a fault claims a cause the transcript cannot show.
        case stopped(String)
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
        case .finished, .stopped, .failed: return false
        }
    }

    /// The mark this run wears, from the one vocabulary all three clients read. A run that has
    /// stopped for any reason holds perfectly still — which is the whole point of asking here
    /// rather than each card deciding for itself, because a card that keeps sweeping after the
    /// work ended is a record that reads as work that never ended.
    public var activityIcon: ActivityIcon { ActivityIcon.workflowRun(self) }

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
        case .stopped(let reason), .failed(let reason):
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

    /// Every workflow launched in a transcript, in the order the conversation made them.
    ///
    /// The kind comes from the tool's name rather than from its summary: this runs over every tool
    /// call in the conversation every time a token arrives, and a summary parses the call's input
    /// and strips the markup off its entire output. On a long agent transcript that was megabytes
    /// of string work per arrival to answer a question the name already answers.
    public static func launches(in messages: [ChatMessage]) -> [Launch] {
        messages.flatMap { message in
            message.parts.compactMap { part -> Launch? in
                guard case .tool(let call) = part.kind, call.summaryKind == .workflow else {
                    return nil
                }
                return Launch(call: call, at: message.createdAt)
            }
        }
    }

    /// The runs a whole conversation knows about: its launches, the agents fanned out under them,
    /// and the notifications that reported the answers back. One call is the client's whole job.
    public static func runs(messages: [ChatMessage], agents: [SubagentSummary], now: Date)
        -> [WorkflowRun]
    {
        let launches = launches(in: messages)
        guard !launches.isEmpty else { return [] }
        return runs(
            launches: launches, agents: agents, completions: completions(in: messages), now: now)
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
        let ending = ending(
            of: call, output: output, launchIDs: launchIDs, completions: completions,
            agents: agents, now: now)
        return WorkflowRun(
            id: call.id, name: name, summary: meta?.summary, phases: meta?.phases ?? [],
            launch: launchIDs, agents: agents, state: ending.state, startedAt: launch.at,
            finishedAt: ending.finishedAt, result: ending.result)
    }

    /// Everything a run's ending decides, read from the only two places an ending can come from.
    ///
    /// The tool call answers the moment the run is handed to the background, so its own status can
    /// only say that a launch worked; what settles the run arrives long afterwards as the harness's
    /// report of the task, seated back on the call that started it (``ToolCall/background``). A
    /// backend that hands the report through as its raw text instead still settles the run through
    /// `completions`, which is why both roads are read here rather than in three cards.
    private static func ending(
        of call: ToolCall, output: String, launchIDs: WorkflowLaunch,
        completions: [String: String], agents: [WorkflowAgent], now: Date
    ) -> (state: WorkflowRun.State, finishedAt: Date?, result: String?) {
        if call.status == .error {
            return (.failed(firstLine(output) ?? Localized.text("Workflow failed")), nil, nil)
        }
        if let reported = call.background {
            return (
                state(of: reported), reported.reportedAt ?? agents.map(\.updatedAt).max() ?? now,
                reported.isSuccess ? reported.answer : nil
            )
        }
        if let answer = launchIDs.taskID.flatMap({ completions[$0] }) {
            return (.finished, agents.map(\.updatedAt).max() ?? now, answer)
        }
        if launchIDs.isEmpty, call.status == .running { return (.launching, nil, nil) }
        return (.running, nil, nil)
    }

    private static func state(of reported: BackgroundOutcome) -> WorkflowRun.State {
        switch reported.status {
        case .completed: return .finished
        case .stopped:
            return .stopped(
                reported.summary.flatMap(firstLine) ?? Localized.text("Workflow stopped"))
        case .failed:
            return .failed(
                reported.summary.flatMap(firstLine) ?? Localized.text("Workflow failed"))
        }
    }

    /// The same ending read the long way round, for a backend that hands the harness's
    /// `<task-notification>` through as raw text rather than as the call's own
    /// ``ToolCall/background``. Kept because a transcript is only ever as structured as the server
    /// that served it, and a card must still stop on one that says less.
    ///
    /// A message's `text` joins all its text parts into a new string, so asking every message in a
    /// conversation for it rebuilds the whole transcript's prose on every arrival. Almost no
    /// message carries a notification, and whether one does can be read off the parts without
    /// building anything.
    public static func completions(in messages: [ChatMessage]) -> [String: String] {
        var found: [String: String] = [:]
        for message in messages {
            let carries = message.parts.contains { part in
                guard case .text(let value) = part.kind else { return false }
                return value.contains("<task-notification>")
            }
            guard carries else { continue }
            let text = message.text
            guard let taskID = tag("task-id", in: text) else { continue }
            found[taskID] = tag("result", in: text).map(unquoted) ?? tag("summary", in: text) ?? ""
        }
        return found
    }

    public static func completions(in texts: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for text in texts {
            guard text.contains("<task-notification>"),
                let taskID = tag("task-id", in: text)
            else { continue }
            found[taskID] = tag("result", in: text).map(unquoted) ?? tag("summary", in: text) ?? ""
        }
        return found
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
            let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let body = String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// The harness writes a returned value as JSON, so a workflow answering with prose arrives
    /// wrapped in quotes with its newlines escaped. A value that is not a JSON string is its own.
    private static func unquoted(_ body: String) -> String {
        guard body.hasPrefix("\""),
            let data = body.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(String.self, from: data)
        else { return body }
        return decoded
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

/// The rules a workflow card lives by, checked headlessly so all three clients are proved against
/// one set of answers — above all the one that was never checked: that a run which ended can be
/// seen to have ended through the road the real backend actually delivers it on.
public enum WorkflowRunCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let reported = started.addingTimeInterval(252)
        let now = started.addingTimeInterval(9_000)

        let live = folded(reporting: nil)
        expect(live.state == .running, "a run nothing reported on is still running")
        expect(live.isLive, "and reads as live")
        expect(live.activityIcon.motion == .turning, "so its mark turns")
        expect(live.finishedAt == nil, "and it has not ended")

        let done = folded(
            reporting: BackgroundOutcome(
                taskID: "task-1", status: .completed, summary: "Workflow completed",
                result: "# The answer", reportedAt: reported))
        expect(done.state == .finished, "a reported completion finishes the run")
        expect(!done.isLive, "which is not live")
        expect(done.activityIcon.motion == .still, "so its mark holds perfectly still")
        expect(done.activityIcon == ActivityIcon.finished, "wearing the face a done thing wears")
        expect(done.result == "# The answer", "and the answer is folded into the card")
        expect(done.finishedAt == reported, "ended when the report landed, not when looked at")
        expect(done.progress == 1, "a finished run is whole")
        expect(done.elapsed(at: now) == 252, "and its clock stopped with it")

        let stopped = folded(
            reporting: BackgroundOutcome(
                taskID: "task-1", status: .stopped, summary: "No completion record was found.",
                reportedAt: reported))
        expect(stopped.state == .stopped("No completion record was found."), "a stop is a stop")
        expect(!stopped.isLive, "and is over")
        expect(stopped.activityIcon.motion == .still, "so it stops moving too")
        expect(stopped.activityIcon.tone == .quiet, "without being blamed for a fault")
        expect(stopped.result == nil, "and claims no answer it never got")

        let broke = folded(
            reporting: BackgroundOutcome(
                taskID: "task-1", status: .failed, summary: "Script threw at phase 2",
                reportedAt: reported))
        expect(broke.state == .failed("Script threw at phase 2"), "a fault keeps its reason")
        expect(broke.activityIcon.tone == .danger, "and wears it")
        expect(broke.activityIcon.motion == .still, "still, because a fault is a record")

        expect(
            everyEnding.allSatisfy { !WorkflowRun(id: "r", name: "n", state: $0).isLive },
            "no ending is live")
        expect(
            everyEnding.allSatisfy {
                ActivityIcon.workflowRun(WorkflowRun(id: "r", name: "n", state: $0)).motion == .still
            },
            "no ending moves")

        expect(framesDrawn(atHz: 60) == 30, "a 60Hz panel draws the tempo, not two thirds of it")
        expect(framesDrawn(atHz: 120) == 30, "and so does a 120Hz one")
        expect(
            framesDrawn(atHz: 144) <= Int(ActivityTuning.frameRate),
            "a panel that cannot land on the tempo stays under it")

        return failures
    }

    private static let everyEnding: [WorkflowRun.State] = [
        .finished, .stopped("stopped"), .failed("failed"),
    ]

    /// One launch, folded the way a client folds it, with whatever the harness reported back.
    private static func folded(reporting outcome: BackgroundOutcome?) -> WorkflowRun {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        var call = ToolCall(
            id: "call-1", name: "Workflow", status: .completed,
            input: .object(["name": .string("kaytetty-best")]),
            output: "Workflow launched in background. Task ID: task-1\nRun ID: wf_abc")
        call.background = outcome
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: started)], agents: [],
            now: started.addingTimeInterval(9_000))
        return runs[0]
    }

    /// How many frames one second of a panel's own ticks is allowed to draw. The clock a frame
    /// callback reads is whole microseconds, and the bug this pins lived entirely in the third of a
    /// microsecond rounding takes off a pair of 60Hz ticks.
    private static func framesDrawn(atHz hz: Double) -> Int {
        var drawn = 0
        var last = -1.0
        for tick in 0..<Int(hz) {
            let time = ((Double(tick) / hz) * 1_000_000).rounded(.down) / 1_000_000
            guard ActivityTuning.wantsFrame(at: time, lastDrawn: last) else { continue }
            drawn += 1
            last = time
        }
        return drawn
    }
}
