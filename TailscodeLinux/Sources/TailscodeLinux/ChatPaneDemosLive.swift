import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    func driverCodeDemo() {
        let now = Date()
        let asked = ChatMessage(
            id: "demo-code-prompt", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("just tell me what to do"))],
            createdAt: now.addingTimeInterval(-120))
        let long = (1...40).map { "step_\($0)() { echo \"stage \($0) of forty\"; }" }.joined(separator: "\n")
        let answer = """
            On the mac (a real terminal, not through me):

            ```
            asc web auth login --apple-id you@example.com --public-provider-id <your team id>
            asc web auth status
            asc web auth export --output-file ~/asc-web-session.json
            ```

            Then from Arch:

            ```bash
            scp mac:~/asc-web-session.json /tmp/ && asc web auth import --input /tmp/asc-web-session.json && asc web auth status && echo "this line is deliberately long enough to run past the pane so the sideways scroll shows itself"
            ```

            One-liner:

            ```sh
            systemctl --user restart claude-bridge
            ```

            And the whole script, which is long enough to fold:

            ```bash
            \(long)
            ```
            """
        let reply = ChatMessage(
            id: "demo-code-answer", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "a", kind: .text(answer))],
            createdAt: now)
        let state = ConversationState(
            messages: [asked, reply], status: .idle, hasLoadedTranscript: true)
        apply(state: state, rows: rowBuilder.rows(state: state))
    }

    func driverTableStreamStep(
        _ upto: Int, of total: Int, asked: ChatMessage, now: Date
    ) {
        let text = Self.tableDemoAnswer.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).prefix(upto).joined(separator: "\n")
        let done = upto == total
        // The Claude bridge's own shape, which is the one that broke: nothing is stamped on the
        // record, and the only thing that says the answer is still being written is the status.
        let reply = ChatMessage(
            id: "demo-tstream-answer", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "a", kind: .text(text))],
            createdAt: now)
        let state = ConversationState(
            messages: [asked, reply], status: done ? .idle : .running, hasLoadedTranscript: true)
        apply(state: state, rows: rowBuilder.rows(state: state))
    }

    /// The table demo written out a row at a time, which is what the draft card and the wash are
    /// for: the whole answer is streamed in with the message left incomplete until the end.
    func driverTableStreamDemo() {
        let now = Date()
        let asked = ChatMessage(
            id: "demo-tstream-prompt", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("wifi networks, everything you can see"))],
            createdAt: now.addingTimeInterval(-30))
        let lines = Self.tableDemoAnswer.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        driverTableStreamStep(1, of: lines.count, asked: asked, now: now)
        let total = lines.count
        for step in 2...total {
            Gtk.after(UInt32(120 * (step - 1))) { [weak self] in
                self?.driverTableStreamStep(step, of: total, asked: asked, now: now)
            }
        }
    }

    func driverCompactionDemo(_ mode: String) {
        let now = Date()
        let compaction = Compaction(
            trigger: .manual, tokensBefore: 148_000, tokensAfter: 11_200, duration: 96,
            preservedMessageCount: 4,
            summary: """
                ## Task
                Refactor the settings store behind a SettingsFile prefix so preferences survive \
                restart on Linux.

                ## State
                The store reads through the prefix; the migration test still fails on the legacy \
                path. Next: keep the failing test names and re-run the suite.
                """)
        let before = ChatMessage(
            id: "demo-cbefore", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "t", kind: .text("Refactor the settings store, keep the tests green."))
            ],
            createdAt: now.addingTimeInterval(-660))
        let seam = ChatMessage(
            id: "demo-compaction", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "c", kind: .compaction(compaction))],
            createdAt: now.addingTimeInterval(-300))
        let after = ChatMessage(
            id: "demo-cafter", role: .assistant, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "t",
                    kind: .text(
                        "Picking up from the summary: the migration test still names the legacy path."
                    ))
            ],
            createdAt: now.addingTimeInterval(-200))
        var state = ConversationState()
        state.hasLoadedTranscript = true
        state.status = .idle
        switch mode {
        case "running":
            state.messages = [before]
            state.status = .running
            state.compaction = CompactionActivity(startedAt: now.addingTimeInterval(-75))
        case "queued":
            state.messages = [before]
            state.status = .running
            state.compaction = CompactionActivity(startedAt: now.addingTimeInterval(-75))
            pending.begin(text: "and while you are at it, run the tests", userMessages: 1)
        case "failed":
            state.messages = [before]
            state.compaction = CompactionActivity(
                startedAt: now.addingTimeInterval(-8),
                failure: "Conversation too small to compact — nothing would be freed.")
        default:
            state.messages = [before, seam, after]
        }
        apply(state: state, rows: rowBuilder.rows(state: state))
    }

    /// Seeds the composer for the headless driver, through the same paths a keystroke takes.
    /// A synthetic conversation carrying one live workflow and one finished one, so the card can be
    /// driven and photographed headlessly without waiting three minutes on a real fan-out.
    /// A conversation whose last send a spent window stopped, so the wait can be driven and
    /// photographed without an account that is actually out of quota. `stale` is the one nobody
    /// was awake for; anything else is a live wait.
    func driverResumeDemo(_ mode: String) {
        let now = Date()
        let asked = ChatMessage(
            id: "demo-resume-user", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("Refactor the settings store."))],
            createdAt: now.addingTimeInterval(-900))
        var state = ConversationState()
        state.hasLoadedTranscript = true
        state.status = .idle
        state.messages = [asked]
        pending.removeAll()
        resume.removeAll()
        let row = pending.begin(
            text: "and while you are at it, run the tests", userMessages: 1, now: now)
        pending.mark(id: row.id, .failed(reason: "Claude usage limit reached"))
        let fires = mode == "stale" ? -(AutoResume.staleAfter + 120) : 2 * 3600 + 45
        resume.hold(
            ResumePlan(
                id: row.id, profileID: entry?.profileID ?? "demo",
                sessionID: entry?.session.id ?? "demo", provider: "Claude", window: "Session",
                resumesAt: now.addingTimeInterval(fires), trustedReset: true, trigger: .refused,
                attempt: mode == "again" ? 2 : 0, plannedAt: now))
        startResumeClock()
        apply(state: state, rows: rowBuilder.rows(state: state))
        reportResumeState()
    }

    /// What the pane is holding, for the headless driver: the rows, the plans, and the line the
    /// first one is wearing.
    func reportResumeState() {
        let now = Date()
        let plan = resume.plans.values.min { $0.resumesAt < $1.resumesAt }
        let line: String
        if let plan {
            line = ResumeReading.caption(plan, now: now)
        } else if let send = pending.sends.first {
            line = PendingSendReading.state(send, now: now)
        } else {
            line = "none"
        }
        FileHandle.standardOutput.write(
            Data("RESUME pending=\(pending.count) plans=\(resume.count) \(line)\n".utf8))
    }

    /// One workflow run, either still out or ended the way the harness ends one, so a headless
    /// harness can look at both halves of the card's life. The ending is the real road — the report
    /// seated back on the launching call — because a demo that ended a run any other way would
    /// prove the card against a road no server drives.
    func driverWorkflowDemo(_ ending: String) {
        let now = Date()
        let script = """
            export const meta = {
              name: 'kaytetty-best',
              description: 'Recommend the best USED-market buy in Finland — priced live across Tori.fi and Huuto.net',
              phases: [
                { title: 'Scope', detail: 'classify the request and build the used-market search plan' },
                { title: 'Hunt', detail: 'pull live listings from Tori.fi + Huuto.net', model: 'claude-haiku-4-5-20251001' },
                { title: 'Appraise', detail: 'compute the fair band, flag scams, pick the best listing' },
              ],
            }
            """
        var call = ToolCall(
            id: "demo-wf", name: "Workflow", status: .completed,
            input: .object(["script": .string(script)]),
            output: "Workflow launched in background. Task ID: demo-task\nRun ID: wf_demo")
        call.background = Self.demoOutcome(ending, at: now.addingTimeInterval(-4))
        let prompt = ChatMessage(
            id: "demo-user", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("/kaytetty-best Pokemon Yellow"))],
            createdAt: now.addingTimeInterval(-104))
        let launch = ChatMessage(
            id: "demo-launch", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .tool(call))],
            createdAt: now.addingTimeInterval(-100))
        agents = [
            SubagentSummary(
                id: "d0", title: "You are scoping a \"best thing to buy SECOND-HAND in Finland\" request",
                agentType: WorkflowRunAssembly.agentType, updatedAt: now.addingTimeInterval(-41),
                isActive: false, isCompleted: true, startedAt: now.addingTimeInterval(-100)),
            SubagentSummary(
                id: "d1", title: "Use the WebFetch tool on this Tori.fi used-marketplace search URL",
                agentType: WorkflowRunAssembly.agentType, updatedAt: now,
                isActive: true, isCompleted: false, startedAt: now.addingTimeInterval(-41),
                toolCount: 3, currentTool: "WebFetch"),
            SubagentSummary(
                id: "d2", title: "Run EXACTLY these commands (Huuto.net public JSON API, two pages)",
                agentType: WorkflowRunAssembly.agentType, updatedAt: now,
                isActive: true, isCompleted: false, startedAt: now.addingTimeInterval(-41),
                toolCount: 2, currentTool: "Bash"),
        ]
        if call.background?.status == .completed { agents = agents.map(Self.settled) }
        var state = ConversationState()
        state.messages = [prompt, launch]
        state.hasLoadedTranscript = true
        state.status = .idle
        apply(state: state, rows: rowBuilder.rows(state: state))
        context.expanded.set("demo-launch:p", open: true)
        refreshWorkflowRuns()
        replaceRows { if case .workflow = $0.kind { return true } else { return false } }
    }

    /// The report the harness would have posted for this ending, or nothing at all for a run that
    /// is still out.
    static func demoOutcome(_ ending: String, at reportedAt: Date) -> BackgroundOutcome? {
        switch ending {
        case "done":
            return BackgroundOutcome(
                taskID: "demo-task", status: .completed,
                summary: "Dynamic workflow \"kaytetty-best\" completed",
                result: "**Buy the boxed Pokémon Yellow at 89 €** — the fair band is 75–110 €.",
                reportedAt: reportedAt)
        case "stopped":
            return BackgroundOutcome(
                taskID: "demo-task", status: .stopped,
                summary: "No completion record was found.", reportedAt: reportedAt)
        case "failed":
            return BackgroundOutcome(
                taskID: "demo-task", status: .failed,
                summary: "The workflow script threw at phase 2.", reportedAt: reportedAt)
        default:
            return nil
        }
    }

    /// An agent as a run that ran to completion leaves it: every sidecar reported finishing, so
    /// every record says so.
    ///
    /// Only that ending. A run the harness died holding leaves its sidecars claiming to be active
    /// for as long as their reporting window lasts, and settling them here by hand would build the
    /// one shape the card is never asked to draw — an ended run holding agents that still say they
    /// are working, which is what the fan-out actually delivers on a stop or a fault.
    static func settled(_ agent: SubagentSummary) -> SubagentSummary {
        SubagentSummary(
            id: agent.id, title: agent.title, agentType: agent.agentType,
            updatedAt: agent.updatedAt, isActive: false, isCompleted: true,
            startedAt: agent.startedAt, toolCount: agent.toolCount)
    }

    /// What the workflow card's mark is doing, for a harness that cannot watch it: the run's state,
    /// the glyph the card is showing, and the rate the mark itself counted. A screenshot proves
    /// neither that a mark stopped nor what tempo it is keeping.
    func reportWorkflowMark() {
        for index in renderedRows.indices {
            guard case .workflow(let call) = renderedRows[index].kind, index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            let state = context.workflowRuns[call.id].map { "\($0.state)" } ?? "none"
            FileHandle.standardOutput.write(
                Data(
                    ("WORKFLOW state=\(state) \(WorkflowCardView.markReading(of: ptr(raw))) "
                        + WorkflowCardView.phaseReading(of: ptr(raw)) + " "
                        + WorkflowCardView.agentReading(of: ptr(raw)) + "\n").utf8))
        }
    }

    func driverType(_ text: String) {
        gtk_widget_grab_focus(entryView)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), text, -1)
    }
}
