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

    @Test("Durations read as a person would say them")
    func durationFormatting() {
        #expect(WorkflowRun.duration(9) == "9s")
        #expect(WorkflowRun.duration(84) == "1m24s")
        #expect(WorkflowRun.duration(3_725) == "1h02m")
    }

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
