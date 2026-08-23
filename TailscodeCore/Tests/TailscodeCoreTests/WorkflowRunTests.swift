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
            ],
            now: at.addingTimeInterval(30))

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
            ],
            now: at.addingTimeInterval(10))

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
            ],
            now: second.addingTimeInterval(10))

        #expect(runs[0].agents.map(\.id) == ["early"])
        #expect(runs[1].agents.map(\.id) == ["late"])
    }

    @Test("A run whose task reported back is finished and carries the answer")
    func completionBindsByTaskID() {
        let at = Date(timeIntervalSince1970: 1_000)
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: Self.call(), at: at)],
            agents: [Self.agent("a", at: at.addingTimeInterval(4), active: false, completed: true)],
            completions: ["wuzrihlvy": "# Pokémon Blue — used market"],
            now: at.addingTimeInterval(60))

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
            launches: [WorkflowRunAssembly.Launch(call: call, at: Date())], agents: [],
            now: Date())

        #expect(runs[0].state == .failed("Workflow script failed to parse"))
        #expect(runs[0].isLive == false)
    }

    @Test("A saved workflow invoked by name is named even with no script to read")
    func namedInvocationNeedsNoScript() {
        let call = ToolCall(
            id: "t", name: "Workflow", status: .running,
            input: .object(["name": .string("hinta-best")]))
        let runs = WorkflowRunAssembly.runs(
            launches: [WorkflowRunAssembly.Launch(call: call, at: Date())], agents: [], now: Date())

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
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)], agents: [],
            now: Self.startedAt.addingTimeInterval(9_000))

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
            agents: [Self.agent("a", at: Self.startedAt, active: true, completed: false)],
            now: Self.startedAt.addingTimeInterval(9_000))

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
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)], agents: [],
            now: Self.reportedAt)

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
            launches: [WorkflowRunAssembly.Launch(call: call, at: Self.startedAt)], agents: [],
            now: Self.reportedAt)

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

        let runs = WorkflowRunAssembly.runs(
            messages: [launch, notification], agents: [], now: Self.reportedAt)

        #expect(runs[0].state == .finished)
        #expect(runs[0].result == "done")
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
        _ id: String, at: Date, active: Bool, completed: Bool
    ) -> SubagentSummary {
        SubagentSummary(
            id: id, title: "agent \(id)", agentType: WorkflowRunAssembly.agentType,
            updatedAt: at, isActive: active, isCompleted: completed, startedAt: at)
    }
}
