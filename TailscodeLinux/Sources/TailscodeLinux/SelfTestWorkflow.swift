import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The card as this transcript would draw it at that moment: the pass stamps the clock, exactly
    /// as the pane's own passes do, and the line is read back off the widget it built.
    static func drawn(_ call: ToolCall, at now: Date, in context: TranscriptContext)
        -> String
    {
        context.liveNow = now
        let card = SubagentRowView.make(call, key: "sub", context: context)
        return SubagentRowView.liveReading(of: card)
    }

    /// A workflow launched in a transcript has to become one card carrying the run: its name, the
    /// phases its script declares, the agents fanned out under it, and — once the task reports back
    /// — the answer. The row kind is what decides whether the card is drawn at all.
    static func checkWorkflowCard() throws -> Int {
        let now = Date()
        let script = """
            export const meta = {
              name: 'kaytetty-best',
              description: 'Best used buy in Finland',
              phases: [
                { title: 'Scope', detail: 'classify the request' },
                { title: 'Hunt', detail: 'pull live listings', model: 'claude-haiku-4-5-20251001' },
                { title: 'Appraise', detail: 'compute the fair band' },
              ],
            }
            """
        let call = ToolCall(
            id: "wf-call", name: "Workflow", status: .running,
            input: .object(["script": .string(script)]),
            output: "Workflow launched in background. Task ID: task-1\nRun ID: wf_abc")
        let launch = ChatMessage(
            id: "m1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p1", kind: .tool(call))], createdAt: now)

        let rows = TranscriptRow.rows(for: [launch])
        guard case .workflow(let rowCall)? = rows.first?.kind, rowCall.id == call.id else {
            throw SelfTestFailure("a Workflow call is not a workflow row")
        }

        var agents: [SubagentSummary] = []
        for index in 0..<3 {
            let offset = Double(index)
            agents.append(
                SubagentSummary(
                    id: "a\(index)", title: "agent \(index)",
                    agentType: WorkflowRunAssembly.agentType,
                    updatedAt: now.addingTimeInterval(offset + 1),
                    isActive: index > 0, isCompleted: index == 0,
                    startedAt: now.addingTimeInterval(offset)))
        }
        let live = WorkflowRunAssembly.runs(messages: [launch], agents: agents)
        guard let run = live.first, live.count == 1 else {
            throw SelfTestFailure("one launch is not one run")
        }
        guard run.name == "kaytetty-best", run.phases.count == 3 else {
            throw SelfTestFailure("run identity: \(run.name) \(run.phases.count) phases")
        }
        guard run.phases[1].model == "claude-haiku-4-5-20251001" else {
            throw SelfTestFailure("phase model lost")
        }
        guard run.agents.count == 3, run.doneCount == 1, run.runningCount == 2 else {
            throw SelfTestFailure("agent counts: \(run.doneCount)/\(run.agents.count)")
        }
        guard run.isLive, run.launch.runID == "wf_abc" else {
            throw SelfTestFailure("live state: \(run.state)")
        }
        guard run.activityIcon.motion == .turning else {
            throw SelfTestFailure("a live run's mark does not turn")
        }

        for (status, expected) in [
            (BackgroundOutcome.Status.completed, ActivityIcon.finished),
            (.stopped, ActivityIcon.stopped),
            (.failed, ActivityIcon.failed),
        ] {
            let ended = try reported(status, on: call, launch: launch, agents: agents, now: now)
            guard !ended.isLive, ended.activityIcon == expected,
                ended.activityIcon.motion == .still
            else {
                throw SelfTestFailure("a \(status.rawValue) run keeps moving: \(ended.state)")
            }
            guard ended.elapsed(at: now.addingTimeInterval(9_000)) == 120 else {
                throw SelfTestFailure(
                    "a \(status.rawValue) run's clock kept climbing: "
                        + "\(ended.elapsed(at: now.addingTimeInterval(9_000)) ?? -1)")
            }
            guard ended.result == (status == .completed ? "# The answer" : nil) else {
                throw SelfTestFailure(
                    "a \(status.rawValue) run's answer: \(ended.result ?? "nil")")
            }
        }

        let marks = try checkWorkflowCardMark(
            call: call, live: run, launch: launch, agents: agents, now: now)

        let notification = ChatMessage(
            id: "m2", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "p2",
                    kind: .text(
                        "<task-notification><task-id>task-1</task-id><result>\"# The answer\"</result></task-notification>"
                    ))
            ], createdAt: now.addingTimeInterval(120))
        let done = WorkflowRunAssembly.runs(messages: [launch, notification], agents: agents)
        guard let finished = done.first, done.count == 1 else {
            throw SelfTestFailure("the finished run vanished")
        }
        guard !finished.isLive, finished.state == .finished, finished.progress == 1 else {
            throw SelfTestFailure("finished state: \(finished.state)")
        }
        guard finished.result == "# The answer" else {
            throw SelfTestFailure("answer not folded in: \(finished.result ?? "nil")")
        }
        guard finished.headline(at: now) == finished.headline(at: now.addingTimeInterval(604_800))
        else {
            throw SelfTestFailure(
                "a run settled by prose alone measures itself against whoever is reading: "
                    + finished.headline(at: now.addingTimeInterval(604_800)))
        }

        return 26 + marks
    }

    /// Everything the card says about a run's ending, read off the widget rather than off the
    /// vocabulary: the header's mark, every agent row's mark, and the phase rail.
    ///
    /// A run reaching an ending is only half of a mark that stops. The label also has to come off
    /// the frame clock and be left showing the ending's own glyph — otherwise the card keeps
    /// whichever frame of the sweep it was holding when the report landed, which is a still picture
    /// of work still going. Both roads a pane takes are walked here, because the fault lived in the
    /// seam rather than in either end: a stop or a fault is restated into the card already on
    /// screen, while an answer arriving changes the card's shape and earns a rebuild.
    ///
    /// The rows and the rail are walked on the same trip because a header that settled while the
    /// card under it went on sweeping and claiming finished phases is the same lie one view lower.
    /// The agents this is handed are deliberately left claiming to be active, which is exactly what
    /// a fan-out delivers for half an hour after the harness that held it died — a check that
    /// settled them by hand would never once build the shape the fault lives in.
    static func checkWorkflowCardMark(
        call: ToolCall, live: WorkflowRun, launch: ChatMessage, agents: [SubagentSummary], now: Date
    ) throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        let context = TranscriptContext()
        context.liveNow = now
        context.workflowRuns[call.id] = live
        context.expanded.set("wf", open: true)
        var card = WorkflowCardView.make(call, key: "wf", context: context)
        guard WorkflowCardView.markReading(of: card).contains("moving=1") else {
            throw SelfTestFailure(
                "a live card's mark holds still: \(WorkflowCardView.markReading(of: card))")
        }
        let planned = WorkflowCardView.phaseReading(of: card)
        guard planned == rail(live) else {
            throw SelfTestFailure("a live card's rail is not the plan: \(planned)")
        }
        guard WorkflowCardView.agentReading(of: card).contains(":moving") else {
            throw SelfTestFailure(
                "no agent is out on a live card: \(WorkflowCardView.agentReading(of: card))")
        }
        let atLaunch = WorkflowCardView.agentClockReading(of: card)
        guard atLaunch == clocks(of: live, at: now) else {
            throw SelfTestFailure("a live card's row clocks: \(atLaunch)")
        }
        card = try restated(card, call: call, context: context, at: now.addingTimeInterval(9_000))
        let anHourOn = WorkflowCardView.agentClockReading(of: card)
        guard anHourOn == clocks(of: live, at: now.addingTimeInterval(9_000)),
            anHourOn != atLaunch
        else {
            throw SelfTestFailure("a live card's rows stopped counting: \(anHourOn)")
        }
        card = try restated(card, call: call, context: context, at: now)

        var claims = 5
        var rails: [String: String] = [:]
        for status in [BackgroundOutcome.Status.stopped, .failed, .completed] {
            let ended = try reported(
                status, on: call, launch: launch, agents: agents, now: now)
            context.workflowRuns[call.id] = ended
            if !WorkflowCardView.restate(card, call: call, context: context) {
                card = WorkflowCardView.make(call, key: "wf", context: context)
            }
            let reading = WorkflowCardView.markReading(of: card)
            guard reading == "mark=\(ended.activityIcon.glyph) moving=0" else {
                throw SelfTestFailure("a \(status.rawValue) card's mark: \(reading)")
            }
            let rows = WorkflowCardView.agentReading(of: card)
            guard rows == settledRows(of: ended) else {
                throw SelfTestFailure("a \(status.rawValue) card's agent rows: \(rows)")
            }
            let drawn = WorkflowCardView.phaseReading(of: card)
            guard drawn == rail(ended) else {
                throw SelfTestFailure("a \(status.rawValue) card's rail: \(drawn)")
            }
            rails[status.rawValue] = drawn
            let stopped = WorkflowCardView.agentClockReading(of: card)
            guard stopped == clocks(of: ended, at: now) else {
                throw SelfTestFailure("a \(status.rawValue) card's row clocks: \(stopped)")
            }
            card = try restated(
                card, call: call, context: context, at: now.addingTimeInterval(604_800))
            let aWeekOn = WorkflowCardView.agentClockReading(of: card)
            guard aWeekOn == stopped else {
                throw SelfTestFailure(
                    "a \(status.rawValue) card's rows kept counting a week later: \(aWeekOn)")
            }
            card = try restated(card, call: call, context: context, at: now)
            claims += 5
        }
        guard rails["stopped"] != rails["completed"], rails["failed"] != rails["completed"],
            rails["stopped"] != planned
        else {
            throw SelfTestFailure(
                "a killed run's rail reads as a finished one: \(rails["stopped"] ?? "none")")
        }
        return claims + 1
    }

    /// The rail this run may honestly draw, spelled the way the widget spells it, from the standing
    /// the vocabulary hands back rather than from a second reading of the run invented here.
    static func rail(_ run: WorkflowRun) -> String {
        let standing = run.phaseStanding
        return "phases="
            + run.phases.map { _ in "\(standing.glyph):\(standing.css)" }.joined(separator: ",")
    }

    /// The card moved on to another moment, by whichever road it would take in the app: restated in
    /// place while its shape holds, rebuilt when it no longer does. Reading a clock at a second
    /// moment is the only way to catch one that grows, and a check that only ever read the card at
    /// the instant it was built would never once ask the question.
    static func restated(
        _ card: UnsafeMutablePointer<GtkWidget>, call: ToolCall, context: TranscriptContext,
        at now: Date
    ) throws -> UnsafeMutablePointer<GtkWidget> {
        context.liveNow = now
        if WorkflowCardView.restate(card, call: call, context: context) { return card }
        return WorkflowCardView.make(call, key: "wf", context: context)
    }

    /// The clock every row of this run may honestly show at that moment, spelled the way the widget
    /// spells it, from the vocabulary that decides it rather than from a second reading of the run
    /// invented here.
    static func clocks(of run: WorkflowRun, at now: Date) -> String {
        "clocks="
            + run.agents.map { $0.elapsed(at: now, in: run).map(WorkflowRun.duration) ?? "" }
            .joined(separator: ",")
    }

    /// Every agent row of an ended run, which is every row holding perfectly still: the one that
    /// reported finishing keeps its tick and the ones the harness died holding wear the ended mark,
    /// whatever their own records still claim.
    static func settledRows(of run: WorkflowRun) -> String {
        "agents="
            + run.agents.map { "\(ActivityIcon.workflowAgent($0, in: run).glyph):still" }
            .joined(separator: ",")
    }

    /// The same launch, ended the way the harness ends one: its report seated back on the call that
    /// started it. This is the only road a real backend delivers an ending on — the prose road
    /// above survives for a server that says less — so it is the one an ending has to be proved
    /// against, or a card can be shipped that never stops moving on the only backend that has
    /// workflows.
    static func reported(
        _ status: BackgroundOutcome.Status, on call: ToolCall, launch: ChatMessage,
        agents: [SubagentSummary], now: Date
    ) throws -> WorkflowRun {
        var ended = call
        ended.status = .completed
        ended.background = BackgroundOutcome(
            taskID: "task-1", status: status, summary: "the run ended",
            result: status == .completed ? "# The answer" : nil,
            reportedAt: now.addingTimeInterval(120))
        let message = ChatMessage(
            id: launch.id, role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p1", kind: .tool(ended))], createdAt: launch.createdAt)
        let runs = WorkflowRunAssembly.runs(messages: [message], agents: agents)
        guard let run = runs.first, runs.count == 1 else {
            throw SelfTestFailure("one ended launch is not one run")
        }
        return run
    }

    /// Two observers on one conversation, which is the whole point of a desktop client that is a
    /// peer of the phone rather than a second app. Until recently the second call to `states()`
    /// tore down the first, so this is the check that the fix holds against a real server.
    static func checkTwoObservers(
        backend: any CodingAgentBackend, session: AgentSession
    ) async throws -> Int {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        async let first = settled(conversation)
        async let second = settled(conversation)
        let (a, b) = try await (first, second)

        guard a == b else {
            throw SelfTestFailure("observers diverged: \(a.count) vs \(b.count) messages")
        }
        return a.count
    }

    /// Bounded from outside the stream: a `for await` whose server never answers receives no
    /// state to check a deadline against, so the deadline must not live inside the loop.
    static func settled(_ conversation: AgentConversation) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                for await state in await conversation.states() {
                    if state.hasLoadedTranscript { return state.messages.map(\.id) }
                }
                throw SelfTestFailure("observer stream ended before a transcript")
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(25))
                throw SelfTestFailure("observer never loaded a transcript in 25s")
            }
            guard let first = try await group.next() else {
                throw SelfTestFailure("no observer outcome")
            }
            group.cancelAll()
            return first
        }
    }

    /// Sends a real prompt through the same path the composer uses and waits for the answer, in a
    /// throwaway session in a throwaway directory. Opt-in, because it spends tokens and starts a
    /// turn on the user's own machine.
    static func checkRoundTrip(_ profiles: [ConnectionProfile]) async throws {
        guard let profile = profiles.first,
            let backend = await ServerDirectory.shared.backend(for: profile)
        else { throw SelfTestFailure("no backend to send through") }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailscode-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let session = try await backend.createSession(
            title: "selftest", directory: scratch.path)
        defer { Task { try? await backend.deleteSession(session.id) } }

        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        let states = await conversation.states()
        try await conversation.send("Reply with the single word PONG and nothing else.")

        let deadline = Date().addingTimeInterval(90)
        for await state in states {
            let answered = state.messages.contains {
                $0.role == .assistant && $0.text.uppercased().contains("PONG")
            }
            if answered { return }
            if Date() > deadline { break }
        }
        throw SelfTestFailure("no answer within the deadline")
    }

    /// Bounded the same way as ``settled(_:)``: the deadline lives outside the stream, and it is
    /// generous — a bridge mid-turn on a large transcript legitimately takes tens of seconds
    /// today, and this test is about correctness, not the latency the sync plan will buy.
    static func firstState(
        of session: AgentSession, on backend: any CodingAgentBackend
    ) async throws -> ConversationState {
        let conversation = AgentConversation(backend: backend, sessionID: session.id)
        return await withTaskGroup(of: ConversationState?.self) { group in
            group.addTask {
                for await state in await conversation.states() where state.hasLoadedTranscript {
                    return state
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(45))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ConversationState()
        }
    }

    /// The newest session that is not mid-turn. An active session's transcript can be enormous
    /// and its server busy running it — that is the wrong subject for a bounded smoke test, and
    /// the two-observer check does not care which conversation it observes.
    static func observable(in sessions: [AgentSession]) -> AgentSession? {
        let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
        return sorted.first { !$0.isWorking } ?? sorted.first
    }

    static func startWatchdog(seconds: Int) {
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            FileHandle.standardOutput.write(Data("SELFTEST_TIMEOUT\n".utf8))
            exit(2)
        }
    }

    static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
