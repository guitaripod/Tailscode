import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A workflow describes itself in JavaScript and reports itself in prose, so every fact a card
/// shows is read out of text nobody wrote for a parser. These pin what may be trusted.
@Suite("Workflow runs")
struct WorkflowRunTests {

    private static let script = """
        export const meta = {
          name: 'kaytetty-best',
          description:
            'Recommend the best USED-market buy in Finland — priced live across Tori.fi and Huuto.net',
          whenToUse: 'When you want a "what should I buy second-hand" answer.',
          phases: [
            { title: 'Scope', detail: 'classify the request and build the search plan' },
            { title: 'Hunt', detail: 'pull live listings', model: 'claude-haiku-4-5-20251001' },
            { title: 'Appraise', detail: 'compute the fair band, flag scams' },
          ],
        }

        phase('Scope')
        const scope = await agent('…', { schema: SCOPE })
        """

    private static let launchOutput = """
        Workflow launched in background. Task ID: wuzrihlvy
        Summary: Recommend the best USED-market buy in Finland
        Transcript dir: /home/marcus/.claude/projects/-home-marcus/abc/subagents/workflows/wf_dc1f
        Run ID: wf_dc1f1297-0ff
        You will be notified when it completes. Use /workflows to watch live progress.
        """

    @Test("The meta block yields the name, the description and every phase in order")
    func parsesMeta() {
        let meta = WorkflowMeta.parse(script: Self.script)

        #expect(meta?.name == "kaytetty-best")
        #expect(meta?.summary?.hasPrefix("Recommend the best USED-market buy") == true)
        #expect(meta?.phases.map(\.title) == ["Scope", "Hunt", "Appraise"])
        #expect(meta?.phases[0].detail == "classify the request and build the search plan")
        #expect(meta?.phases[1].model == "claude-haiku-4-5-20251001")
        #expect(meta?.phases[2].model == nil)
        #expect(meta?.phases.map(\.index) == [0, 1, 2])
    }

    @Test("A double-quoted phrase inside the meta does not end the block early")
    func quotesInsideMetaDoNotTruncate() {
        let meta = WorkflowMeta.parse(script: Self.script)

        #expect(meta?.phases.count == 3)
    }

    @Test("A script without a meta block is not a workflow description")
    func rejectsScriptWithoutMeta() {
        #expect(WorkflowMeta.parse(script: "const x = 1\nawait agent('hi')") == nil)
    }

    @Test("The launch output names the run, the task and the transcript directory")
    func parsesLaunch() {
        let launch = WorkflowLaunch.parse(output: Self.launchOutput)

        #expect(launch.runID == "wf_dc1f1297-0ff")
        #expect(launch.taskID == "wuzrihlvy")
        #expect(launch.transcriptDirectory?.hasSuffix("workflows/wf_dc1f") == true)
        #expect(launch.isEmpty == false)
    }

    @Test("Output that never launched carries no ids")
    func emptyLaunch() {
        #expect(WorkflowLaunch.parse(output: "Running.").isEmpty)
    }

    @Test("A launched run with agents still working is running, and counts them")
    func assemblesLiveRun() {
        let at = Date(timeIntervalSince1970: 1_000)
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: Self.call(), at: at)],
            agents: [
                Self.agent("a", at: at.addingTimeInterval(2), active: false, completed: true),
                Self.agent("b", at: at.addingTimeInterval(5), active: true, completed: false),
                Self.agent("c", at: at.addingTimeInterval(6), active: true, completed: false),
            ])

        #expect(runs.count == 1)
        #expect(runs[0].name == "kaytetty-best")
        #expect(runs[0].phases.count == 3)
        #expect(runs[0].agents.count == 3)
        #expect(runs[0].doneCount == 1)
        #expect(runs[0].runningCount == 2)
        #expect(runs[0].isLive)
        #expect(runs[0].state == .running)
        #expect(abs(runs[0].progress - 1.0 / 3.0) < 0.0001)
        #expect(runs[0].elapsed(at: at.addingTimeInterval(30)) == 30)
    }

    @Test("Agents that belong to no workflow are left where they are")
    func ignoresNonWorkflowAgents() {
        let at = Date(timeIntervalSince1970: 1_000)
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: Self.call(), at: at)],
            agents: [
                Self.agent("a", at: at.addingTimeInterval(1), active: true, completed: false),
                SubagentSummary(
                    id: "task", title: "Explore", agentType: "general-purpose",
                    updatedAt: at.addingTimeInterval(2), isActive: true),
            ])

        #expect(runs[0].agents.map(\.id) == ["a"])
    }

    @Test("Each agent is seated in the run that had already launched when it appeared")
    func seatsAgentsInTheLaunchThatPrecedesThem() {
        let at = Date(timeIntervalSince1970: 1_000)
        let second = at.addingTimeInterval(100)
        let runs = WorkflowRunAssembly.runs(
            launches: [
                WorkflowRunAssembly.Launch(call: Self.call(id: "one"), at: at),
                WorkflowRunAssembly.Launch(call: Self.call(id: "two"), at: second),
            ],
            agents: [
                Self.agent("early", at: at.addingTimeInterval(5), active: true, completed: false),
                Self.agent(
                    "late", at: second.addingTimeInterval(5), active: true, completed: false),
            ])

        #expect(runs[0].agents.map(\.id) == ["early"])
        #expect(runs[1].agents.map(\.id) == ["late"])
    }

    @Test("A run whose task reported back is finished and carries the answer")
    func completionBindsByTaskID() {
        let at = Date(timeIntervalSince1970: 1_000)
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: Self.call(), at: at)],
            agents: [Self.agent("a", at: at.addingTimeInterval(4), active: false, completed: true)],
            completions: ["wuzrihlvy": "# Pokémon Blue — used market"])

        #expect(runs[0].state == .finished)
        #expect(runs[0].isLive == false)
        #expect(runs[0].progress == 1)
        #expect(runs[0].result?.hasPrefix("# Pokémon") == true)
    }

    @Test("A tool call that errored reports its first line rather than a fabricated state")
    func failureKeepsItsReason() {
        var call = Self.call()
        call.status = .error
        call.output = "Workflow script failed to parse\nat line 3"
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Date())], agents: [])

        #expect(runs[0].state == .failed("Workflow script failed to parse"))
        #expect(runs[0].isLive == false)
    }

    @Test("A saved workflow invoked by name is named even with no script to read")
    func namedInvocationNeedsNoScript() {
        let call = ToolCall(
            id: "t", name: "Workflow", status: .running,
            input: .object(["name": .string("hinta-best")]))
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Date())], agents: [])

        #expect(runs[0].name == "hinta-best")
        #expect(runs[0].phases.isEmpty)
        #expect(runs[0].state == .launching)
    }

    @Test("The completion notification gives up its task and its answer")
    func readsCompletionNotification() {
        let notification = """
            <task-notification>
            <task-id>wuzrihlvy</task-id>
            <status>completed</status>
            <result>"# Pokémon Yellow\\n\\n**60 EUR** — Espoo"</result>
            </task-notification>
            """

        let found = WorkflowRunAssembly.completions(in: ["unrelated text", notification])

        #expect(found.count == 1)
        #expect(found["wuzrihlvy"] == "# Pokémon Yellow\n\n**60 EUR** — Espoo")
    }

    @Test("A result that is not JSON is kept exactly as it came")
    func keepsPlainResultVerbatim() {
        let notification = """
            <task-notification>
            <task-id>t1</task-id>
            <result>{"a":"alpha-ok"}</result>
            </task-notification>
            """

        #expect(WorkflowRunAssembly.completions(in: [notification])["t1"] == #"{"a":"alpha-ok"}"#)
    }

    @Test("A notification with no result still marks the task done, using its summary")
    func fallsBackToSummary() {
        let notification = """
            <task-notification>
            <task-id>t2</task-id>
            <summary>Workflow "probe" completed</summary>
            </task-notification>
            """

        #expect(WorkflowRunAssembly.completions(in: [notification])["t2"] == #"Workflow "probe" completed"#)
    }

    @Test("A reported ending stops the run, and hands the card its answer")
    func reportedCompletionSettlesTheRun() {
        var call = Self.call()
        call.status = .completed
        call.background = BackgroundOutcome(
            taskID: "wuzrihlvy", status: .completed,
            summary: #"Dynamic workflow "kaytetty-best" completed"#,
            result: "**60 EUR** — Espoo", reportedAt: Self.reportedAt)
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)], agents: [])

        #expect(runs[0].state == .finished)
        #expect(runs[0].isLive == false)
        #expect(runs[0].activityIcon.motion == .still)
        #expect(runs[0].result == "**60 EUR** — Espoo")
        #expect(runs[0].finishedAt == Self.reportedAt)
        #expect(runs[0].elapsed(at: Self.startedAt.addingTimeInterval(9_000)) == 252)
        #expect(runs[0].progress == 1)
    }

    @Test("A launch that reported nothing back is still running, however long it has been")
    func silenceIsNotAnEnding() {
        var call = Self.call()
        call.status = .completed
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)],
            agents: [Self.agent("a", at: Self.startedAt, active: true, completed: false)])

        #expect(runs[0].state == .running)
        #expect(runs[0].isLive)
        #expect(runs[0].activityIcon.motion == .turning)
        #expect(runs[0].finishedAt == nil)
    }

    @Test("A run that was stopped is over without being blamed")
    func stoppedIsNotFailed() {
        var call = Self.call()
        call.status = .completed
        call.background = BackgroundOutcome(
            taskID: "wuzrihlvy", status: .stopped,
            summary: "No completion record was found for this run.\nIt may have been stopped.",
            reportedAt: Self.reportedAt)
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)], agents: [])

        #expect(runs[0].state == .stopped("No completion record was found for this run."))
        #expect(runs[0].isLive == false)
        #expect(runs[0].activityIcon.tone == .quiet)
        #expect(runs[0].activityIcon.motion == .still)
        #expect(runs[0].result == nil)
        #expect(runs[0].headline(at: Self.reportedAt) == "No completion record was found for this run.")
    }

    @Test("A run the harness reported as failed wears the fault, not a tick")
    func reportedFailureIsAFailure() {
        var call = Self.call()
        call.status = .completed
        call.background = BackgroundOutcome(
            taskID: "wuzrihlvy", status: .failed, summary: "Script threw at phase 2",
            reportedAt: Self.reportedAt)
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)], agents: [])

        #expect(runs[0].state == .failed("Script threw at phase 2"))
        #expect(runs[0].activityIcon.tone == .danger)
        #expect(runs[0].activityIcon.motion == .still)
    }

    @Test("A backend that hands the notification through as prose still settles the run")
    func rawNotificationStillWorks() {
        let notification = ChatMessage(
            id: "m2", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "text",
                    kind: .text(
                        "<task-notification>\n<task-id>wuzrihlvy</task-id>\n"
                            + "<result>\"done\"</result>\n</task-notification>"))
            ],
            createdAt: Self.reportedAt)
        let launch = ChatMessage(
            id: "m1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "call-1", kind: .tool(Self.call()))],
            createdAt: Self.startedAt)

        let runs = WorkflowRunAssembly.runs(messages: [launch, notification], agents: [])

        #expect(runs[0].state == .finished)
        #expect(runs[0].result == "done")
    }

    @Test("An agent whose sidecar still claims it is working stops when its run does")
    func anEndedRunSettlesItsAgents() {
        var call = Self.call()
        call.status = .completed
        call.background = BackgroundOutcome(
            taskID: "wuzrihlvy", status: .stopped,
            summary: "No completion record was found for this run.", reportedAt: Self.reportedAt)
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)],
            agents: [
                Self.agent("a", at: Self.reportedAt, active: true, completed: false),
                Self.agent("b", at: Self.reportedAt, active: false, completed: true),
            ])
        let run = runs[0]

        #expect(ActivityIcon.workflowAgent(run.agents[0], in: run) == .stopped)
        #expect(ActivityIcon.workflowAgent(run.agents[0], in: run).motion == .still)
        #expect(ActivityIcon.workflowAgent(run.agents[1], in: run) == .finished)
    }

    @Test("The same agent turns while the run it belongs to is still going")
    func aLiveRunLetsItsAgentsTurn() {
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: Self.call(), at: Self.startedAt)],
            agents: [Self.agent("a", at: Self.reportedAt, active: true, completed: false)])
        let run = runs[0]

        #expect(run.isLive)
        #expect(ActivityIcon.workflowAgent(run.agents[0], in: run) == .openWork)
        #expect(ActivityIcon.workflowAgent(run.agents[0], in: run).motion == .turning)
    }

    @Test("An agent that never reported finishing is timed to its run's ending, not to the reader")
    func anEndedRunStopsTheClocksUnderIt() {
        var call = Self.call()
        call.status = .completed
        call.background = BackgroundOutcome(
            taskID: "wuzrihlvy", status: .stopped,
            summary: "No completion record was found for this run.", reportedAt: Self.reportedAt)
        let run = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)],
            agents: [
                Self.agent(
                    "a", at: Self.reportedAt.addingTimeInterval(1_800), active: true,
                    completed: false, from: Self.startedAt),
                Self.agent(
                    "b", at: Self.startedAt.addingTimeInterval(30), active: false, completed: true,
                    from: Self.startedAt),
            ])[0]
        let sidecar = run.agents.first { $0.id == "a" }
        let done = run.agents.first { $0.id == "b" }
        let aWeekLater = Self.reportedAt.addingTimeInterval(604_800)

        #expect(run.finishedAt == Self.reportedAt)
        #expect(sidecar?.elapsed(at: aWeekLater, in: run) == 252)
        #expect(
            sidecar?.elapsed(at: aWeekLater, in: run)
                == sidecar?.elapsed(at: Self.reportedAt, in: run))
        #expect(done?.elapsed(at: aWeekLater, in: run) == 30)
    }

    @Test("An agent still out under a run that is going is the only one timed to now")
    func aLiveRunTimesItsAgentsToNow() {
        let run = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: Self.call(), at: Self.startedAt)],
            agents: [
                Self.agent(
                    "a", at: Self.reportedAt, active: true, completed: false,
                    from: Self.startedAt),
                Self.agent(
                    "b", at: Self.startedAt.addingTimeInterval(30), active: false, completed: true,
                    from: Self.startedAt),
            ])[0]
        let now = Self.startedAt.addingTimeInterval(9_000)

        #expect(run.isLive)
        #expect(run.agents.first { $0.id == "a" }?.elapsed(at: now, in: run) == 9_000)
        #expect(run.agents.first { $0.id == "b" }?.elapsed(at: now, in: run) == 30)
    }

    @Test("An agent under an ending nobody stamped stops where the run was last seen to move")
    func anUntimedEndingStopsItsAgentsToo() {
        let run = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: Self.call(), at: Self.startedAt)],
            agents: [
                Self.agent(
                    "a", at: Self.reportedAt, active: true, completed: false,
                    from: Self.startedAt)
            ],
            completions: ["wuzrihlvy": "done"])[0]
        let aWeekLater = Self.reportedAt.addingTimeInterval(604_800)

        #expect(run.state == .finished)
        #expect(run.agents[0].elapsed(at: aWeekLater, in: run) == 252)
    }

    @Test("An ending nobody timed reads the same however long afterwards it is opened")
    func anUntimedEndingBorrowsNobodysClock() {
        let notification = ChatMessage(
            id: "m2", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "text",
                    kind: .text(
                        "<task-notification>\n<task-id>wuzrihlvy</task-id>\n"
                            + "<result>\"done\"</result>\n</task-notification>"))
            ],
            createdAt: Self.reportedAt)
        let launch = ChatMessage(
            id: "m1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "call-1", kind: .tool(Self.call()))],
            createdAt: Self.startedAt)

        let run = WorkflowRunAssembly.runs(messages: [launch, notification], agents: [])[0]
        let aWeekLater = Self.reportedAt.addingTimeInterval(604_800)

        #expect(run.state == .finished)
        #expect(run.finishedAt == nil)
        #expect(run.elapsed(at: aWeekLater) == nil)
        #expect(run.headline(at: aWeekLater) == run.headline(at: Self.reportedAt))
        #expect(run.headline(at: aWeekLater) == "0 agents")
    }

    @Test("An ending with no time of its own falls back to the last thing that moved")
    func anUntimedEndingUsesTheLastAgentReport() {
        let run = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: Self.call(), at: Self.startedAt)],
            agents: [Self.agent("a", at: Self.reportedAt, active: false, completed: true)],
            completions: ["wuzrihlvy": "done"])[0]

        #expect(run.finishedAt == Self.reportedAt)
        #expect(run.elapsed(at: Self.startedAt.addingTimeInterval(604_800)) == 252)
    }

    @Test("A run that was killed never claims the phases it never recorded running")
    func aKilledRunFillsNoPhase() {
        var call = Self.call()
        call.status = .completed
        call.background = BackgroundOutcome(
            taskID: "wuzrihlvy", status: .stopped, summary: "Stopped during phase 1",
            reportedAt: Self.reportedAt)
        let killed = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)], agents: [])[0]

        #expect(killed.phases.count == 3)
        #expect(killed.isLive == false)
        #expect(killed.phaseStanding == .unfinished)
        #expect(
            killed.phaseStanding
                != WorkflowRun(id: "r", name: "n", state: .finished).phaseStanding)
        #expect(killed.phaseStanding.tone == .quiet)
        #expect(killed.phaseStanding.glyph != WorkflowPhaseStanding.done.glyph)
        #expect(killed.phaseStanding.symbol != WorkflowPhaseStanding.done.symbol)
        #expect(killed.phaseStanding.css != WorkflowPhaseStanding.done.css)
    }

    @Test("The three phase readings are three distinct marks a card cannot conflate")
    func everyPhaseStandingIsItsOwnMark() {
        let all = WorkflowPhaseStanding.allCases

        #expect(Set(all.map(\.glyph)).count == all.count)
        #expect(Set(all.map(\.symbol)).count == all.count)
        #expect(Set(all.map(\.css)).count == all.count)
        #expect(Set(all.map(\.spoken)).count == all.count)
        #expect(all.allSatisfy { $0.glyph.count == 1 })
        #expect(WorkflowPhaseStanding.done.tone == .live)
        #expect(WorkflowRun(id: "r", name: "n", state: .launching).phaseStanding == .planned)
        #expect(WorkflowRun(id: "r", name: "n", state: .running).phaseStanding == .planned)
        #expect(WorkflowRun(id: "r", name: "n", state: .finished).phaseStanding == .done)
        #expect(
            WorkflowRun(id: "r", name: "n", state: .failed("threw")).phaseStanding == .unfinished)
    }

    @Test("The headless check every client runs finds nothing wrong")
    func theCheckPasses() {
        #expect(WorkflowRunCheck.run() == [])
    }

    @Test("Durations read as a person would say them")
    func durationFormatting() {
        #expect(WorkflowRun.duration(9) == "9s")
        #expect(WorkflowRun.duration(84) == "1m24s")
        #expect(WorkflowRun.duration(3_725) == "1h02m")
    }

    private static let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let reportedAt = Date(timeIntervalSince1970: 1_700_000_252)

    private static func call(id: String = "call-1") -> ToolCall {
        ToolCall(
            id: id, name: "Workflow", status: .running,
            input: .object(["script": .string(script)]), output: launchOutput)
    }

    private static func agent(
        _ id: String, at: Date, active: Bool, completed: Bool, from: Date? = nil
    ) -> SubagentSummary {
        SubagentSummary(
            id: id, title: "agent \(id)", agentType: WorkflowRunAssembly.agentType,
            updatedAt: at, isActive: active, isCompleted: completed, startedAt: from ?? at)
    }
}
