import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("What a busy session looks like")
struct ActivityTests {
    private static let everyKind = ActivityKind.everyState

    @Test("Every state has a symbol, a glyph and words — nothing renders as a blank")
    func everyStateIsDrawable() {
        for kind in Self.everyKind {
            let icon = kind.icon
            #expect(!icon.symbol.isEmpty, "\(kind) has no symbol")
            #expect(icon.glyph.count == 1, "\(kind) glyph is not one column: \(icon.glyph)")
            #expect(!kind.title.isEmpty)
            #expect(!kind.bandWord.isEmpty)
            #expect(!kind.spoken.isEmpty)
            #expect(!icon.glyphCSS.isEmpty && !icon.bandCSS.isEmpty)
        }
    }

    @Test("A sweep cycles through frames that are all one column wide, so nothing re-measures")
    func sweepFramesShareAWidth() {
        for kind in Self.everyKind where kind.icon.motion == .turning {
            #expect(kind.icon.cycle.count > 1, "\(kind) sweeps with nothing to sweep through")
            for frame in kind.icon.cycle {
                #expect(frame.count == 1, "\(kind) frame \(frame) is not one column")
            }
        }
        var seen = Set<String>()
        for step in stride(from: 0.0, to: ActivityTuning.sweepPeriod, by: 0.05) {
            seen.insert(ActivityKind.compacting.icon.glyph(at: step))
        }
        #expect(seen == Set(ActivityIcon.sweepCycle))
    }

    @Test("A live workflow agent turns; a finished one, and any agent of an ended run, holds still")
    func workflowAgentMark() {
        let now = Date()
        let live = WorkflowAgent(
            id: "a", title: "agent", isActive: true, isCompleted: false, updatedAt: now)
        let done = WorkflowAgent(
            id: "b", title: "agent", isActive: false, isCompleted: true, updatedAt: now)
        let running = WorkflowRun(id: "r", name: "n", agents: [live, done], state: .running)
        #expect(ActivityIcon.workflowAgent(live, in: running) == .openWork)
        #expect(ActivityIcon.workflowAgent(live, in: running).motion == .turning)
        #expect(ActivityIcon.workflowAgent(done, in: running) == .finished)
        #expect(ActivityIcon.workflowAgent(done, in: running).motion == .still)
        for state: WorkflowRun.State in [.finished, .stopped("gone"), .failed("threw")] {
            let over = WorkflowRun(id: "r", name: "n", agents: [live, done], state: state)
            #expect(ActivityIcon.workflowAgent(live, in: over) == .stopped)
            #expect(ActivityIcon.workflowAgent(live, in: over).motion == .still)
            #expect(ActivityIcon.workflowAgent(done, in: over) == .finished)
        }
        #expect(ActivityTuning.frameRate == 30)
        let start = ActivityMotion.turning.rotation(at: 0)
        let later = ActivityMotion.turning.rotation(at: ActivityTuning.sweepPeriod / 4)
        #expect(abs(later - start) > 0.5)
    }

    @Test("Work breathes, attention knocks twice, and everything settled holds still")
    func motionCarriesTheMeaning() {
        #expect(ActivityKind.working.icon.motion == .working)
        #expect(ActivityKind.usingTool(name: "Edit", kind: .fileEdit).icon.motion == .working)
        #expect(ActivityKind.needsApproval.icon.motion == .attention)
        #expect(ActivityKind.needsAnswer.icon.motion == .attention)
        #expect(ActivityKind.failed.icon.motion == .still)
        #expect(ActivityKind.offline.icon.motion == .still)
        #expect(ActivityKind.queued(1).icon.motion == .still)
    }

    @Test("A swell stays inside its floor and its ceiling, whenever it is asked")
    func pulseStaysInBounds() {
        let pulses = [
            ActivityPulse(period: ActivityTuning.breathPeriod, floor: ActivityTuning.breathFloor),
            ActivityPulse(
                period: ActivityTuning.heartbeatPeriod, floor: ActivityTuning.heartbeatFloor,
                beats: 2),
        ]
        for pulse in pulses {
            for step in stride(from: -3.0, through: 12.0, by: 0.011) {
                let value = pulse.intensity(at: step)
                #expect(value >= pulse.floor - 0.0001 && value <= 1.0001, "out of bounds at \(step)")
            }
        }
    }

    @Test("Breathing peaks once a period and is smooth across the seam")
    func breathIsOneSmoothSwell() {
        let pulse = ActivityPulse(
            period: ActivityTuning.breathPeriod, floor: ActivityTuning.breathFloor)
        #expect(abs(pulse.intensity(at: 0) - 1) < 0.0001)
        #expect(abs(pulse.intensity(at: ActivityTuning.breathPeriod / 2) - pulse.floor) < 0.0001)
        let before = pulse.intensity(at: ActivityTuning.breathPeriod - 0.001)
        #expect(abs(before - pulse.intensity(at: 0)) < 0.01, "the swell ticks at the wrap")

        var peaks = 0
        let step = 0.005
        var previous = pulse.intensity(at: -step)
        var current = pulse.intensity(at: 0)
        for time in stride(from: step, to: ActivityTuning.breathPeriod, by: step) {
            let next = pulse.intensity(at: time)
            if current > previous, current >= next { peaks += 1 }
            previous = current
            current = next
        }
        #expect(peaks == 1, "a breath peaked \(peaks) times")
    }

    @Test("A heartbeat is two beats and then a real rest")
    func heartbeatRests() {
        let pulse = ActivityPulse(
            period: ActivityTuning.heartbeatPeriod, floor: ActivityTuning.heartbeatFloor, beats: 2)
        var peaks = 0
        let step = 0.002
        var previous = pulse.intensity(at: -step)
        var current = pulse.intensity(at: 0)
        var restingSamples = 0
        var samples = 0
        for time in stride(from: step, to: ActivityTuning.heartbeatPeriod, by: step) {
            let next = pulse.intensity(at: time)
            if current > previous, current >= next, current > pulse.floor + 0.2 { peaks += 1 }
            if current <= pulse.floor + 0.0001 { restingSamples += 1 }
            samples += 1
            previous = current
            current = next
        }
        #expect(peaks == 2, "a heartbeat beat \(peaks) times")
        #expect(Double(restingSamples) / Double(samples) > 0.5, "the rest is not a rest")
    }

    @Test("Reduced motion loses the movement and nothing else")
    func reducedMotionKeepsTheFacts() {
        for kind in Self.everyKind {
            let icon = kind.icon
            #expect(icon.motion.honoring(reduceMotion: true) == .still)
            #expect(icon.glyph(at: 4.2, reduceMotion: true) == icon.glyph)
            #expect(ActivityMotion.still.intensity(at: 4.2) == 1)
            #expect(ActivityMotion.still.scale(at: 4.2) == 1)
            #expect(ActivityMotion.still.rotation(at: 4.2) == 0)
            #expect(!kind.title.isEmpty)
        }
    }

    @Test("A breathing badge grows a little and never shrinks below its own size")
    func scaleIsAnchored() {
        let motion = ActivityMotion.working
        for step in stride(from: 0.0, to: 4.0, by: 0.01) {
            let scale = motion.scale(at: step)
            #expect(scale >= 1 - 0.0001 && scale <= 1 + ActivityTuning.lift + 0.0001)
        }
        #expect(abs(motion.scale(at: 0) - (1 + ActivityTuning.lift)) < 0.0001)
        #expect(ActivityMotion.attention.scale(at: 0.1) == 1)
    }

    @Test("A row says what a listing can know and never more")
    func rowStatesMapToActivity() {
        #expect(SessionRowState.idle.activity == nil)
        #expect(SessionRowState.live.activity == .working)
        #expect(SessionRowState.awaitingApproval.activity == .needsApproval)
        #expect(SessionRowState.failed.activity == .failed)
        #expect(SessionRowState.offline.activity == .offline)
        #expect(SessionRowState.idle.icon.motion == .still)
        #expect(SessionRowState.live.glyph.css == "glyph-running")
        #expect(SessionRowState.awaitingApproval.glyph.css == "glyph-needs")
        #expect(SessionRowState.failed.glyph.css == "glyph-error")
        #expect(SessionRowState.offline.glyph.css == "glyph-pending")
        #expect(SessionRowState.offline.icon.bandCSS == "seg-offline")
    }

    @Test("A running turn is read down to what it is actually doing")
    func inFlightReadsTheTranscript() {
        #expect(ActivityKind.inFlight(in: Self.state(status: .idle)) == nil)
        #expect(ActivityKind.inFlight(in: Self.state(status: .running)) == .thinking)

        let writing = Self.state(
            status: .running,
            messages: [Self.assistant(parts: [MessagePart(id: "p", kind: .text("half an ans"))])])
        #expect(ActivityKind.inFlight(in: writing) == .writing)

        let tooling = Self.state(
            status: .running,
            messages: [
                Self.assistant(parts: [
                    MessagePart(id: "p", kind: .text("about to run it")),
                    MessagePart(
                        id: "t",
                        kind: .tool(ToolCall(id: "t", name: "Bash", status: .running))),
                ])
            ])
        #expect(ActivityKind.inFlight(in: tooling) == .usingTool(name: "Bash", kind: .shell))

        var asking = Self.state(status: .running)
        asking.pendingPermissions = [
            PermissionRequest(id: "p", sessionID: "s", title: "run it", toolName: "Bash")
        ]
        #expect(ActivityKind.inFlight(in: asking) == .needsApproval)
    }

    @Test("A tool call left running from a past turn is a stale record, not work")
    func staleToolCallsDoNotCount() {
        let state = Self.state(
            status: .running,
            messages: [
                Self.assistant(parts: [
                    MessagePart(
                        id: "t", kind: .tool(ToolCall(id: "t", name: "Bash", status: .running)))
                ]),
                ChatMessage(id: "u", role: .user, agentType: .claudeCode, createdAt: Date()),
                Self.assistant(parts: []),
            ])
        #expect(ActivityKind.inFlight(in: state) == .thinking)
    }

    @Test("A fan-out counts its agents rather than naming the call that spawned them")
    func fanOutReadsAsAgents() {
        let state = Self.state(
            status: .running,
            messages: [
                Self.assistant(parts: [
                    MessagePart(
                        id: "t", kind: .tool(ToolCall(id: "t", name: "Task", status: .running)))
                ])
            ])
        let agents = (0..<3).map {
            SubagentSummary(id: "\($0)", title: "agent \($0)", updatedAt: Date(), isActive: true)
        }
        let facts = StatusFacts.from(
            state: state, turnStartedAt: nil, agents: agents, usage: nil, attachments: 0)
        #expect(facts.activity == .delegating(active: 3))
    }

    @Test("The band's phase segment carries the icon it draws inside its own text")
    func bandSegmentsCarryTheirIcon() {
        var facts = StatusFacts()
        facts.phase = .working
        facts.activity = .usingTool(name: "Bash", kind: .shell)
        facts.elapsed = 72
        let phase = facts.segments.first { $0.id == "phase" }
        #expect(phase?.icon == ActivityKind.usingTool(name: "Bash", kind: .shell).icon)
        #expect(phase?.text.contains("Bash") == true)
        #expect(phase?.text.contains("1m 12s") == true)
        #expect(phase?.text.hasPrefix(ActivityKind.usingTool(name: "Bash", kind: .shell).icon.glyph) == true)
        #expect(phase?.css == "seg-live")

        var waiting = StatusFacts()
        waiting.phase = .awaitingApproval
        #expect(waiting.segments.first?.icon?.tone == .attention)
        #expect(waiting.segments.first?.css == "seg-warn")

        var offline = StatusFacts()
        offline.phase = .offline
        #expect(offline.segments.first?.css == "seg-offline")
        #expect(offline.segments.first?.icon?.motion == .still)
    }

    @Test("Messages waiting behind a running turn are a fact the band states")
    func queuedMessagesAreVisible() {
        var facts = StatusFacts()
        facts.phase = .working
        facts.queued = 2
        let queued = facts.segments.first { $0.id == "queued" }
        #expect(queued?.text.contains("2") == true)
        #expect(queued?.css == "seg-dim")
        #expect(StatusFacts().segments.contains { $0.id == "queued" } == false)
    }

    @Test("Every class an icon can wear is one the band already styles")
    func classesStayInsideTheKnownSet() {
        let known = Set(StatusFacts.Segment.allCSS)
        for kind in Self.everyKind {
            #expect(known.contains(kind.icon.bandCSS), "\(kind) wears \(kind.icon.bandCSS)")
        }
    }

    private static func state(
        status: BackendStatus, messages: [ChatMessage] = []
    ) -> ConversationState {
        ConversationState(
            messages: messages, status: status, connection: .live, hasLoadedTranscript: true)
    }

    private static func assistant(parts: [MessagePart]) -> ChatMessage {
        ChatMessage(
            id: "a", role: .assistant, agentType: .claudeCode, parts: parts, createdAt: Date(),
            isStreaming: true)
    }
}

@Suite("What the band says about the connection")
struct ConnectionPhaseTests {
    private func state(
        _ phase: ConnectionPhase, changedAgo: TimeInterval, status: BackendStatus = .idle
    ) -> ConversationState {
        ConversationState(
            messages: [], status: status, connection: phase, hasLoadedTranscript: true,
            connectionChangedAt: Date().addingTimeInterval(-changedAgo))
    }

    private func facts(_ state: ConversationState) -> StatusFacts {
        StatusFacts.from(
            state: state, turnStartedAt: nil, agents: [], usage: nil, attachments: 0)
    }

    @Test("A live idle conversation is ready, and says nothing about connecting")
    func liveReadsReady() {
        let band = facts(state(.live, changedAgo: 300)).segments.first
        #expect(band?.text.contains("ready") == true)
        #expect(band?.css == "seg-idle")
    }

    @Test("A dial that has only just started shows no clock")
    func youngDialIsQuiet() {
        let band = facts(state(.connecting, changedAgo: 0.2)).segments.first
        #expect(band?.text.contains("connecting") == true)
        #expect(band?.text.contains("·") == false)
    }

    @Test("A dial that is taking a while says how long it has been taking")
    func stuckDialCountsUp() {
        let band = facts(state(.connecting, changedAgo: 45)).segments.first
        #expect(band?.text.contains("connecting") == true)
        #expect(band?.text.contains("45s") == true)
    }

    @Test("Reconnecting counts up too, and can be kicked by hand")
    func reconnectingIsActionable() {
        let band = facts(state(.reconnecting, changedAgo: 90)).segments.first
        #expect(band?.text.contains("1m 30s") == true)
        #expect(band?.action == .reconnect)
    }

    @Test("A server that is not answering holds still and offers the retry")
    func offlineIsSettled() {
        let band = facts(state(.offline, changedAgo: 600)).segments.first
        #expect(band?.icon?.motion == .still)
        #expect(band?.action == .reconnect)
        #expect(band?.text.contains("600") == false)
    }

    @Test("A panel whose tick lands on the boundary draws thirty frames a second, not twenty")
    func boundaryTicksAreNotDropped() {
        for hz in [60.0, 120.0, 240.0] {
            var drawn = 0
            var last = -1.0
            for tick in 0..<Int(hz) {
                let time = quantised(Double(tick) / hz)
                guard ActivityTuning.wantsFrame(at: time, lastDrawn: last) else { continue }
                drawn += 1
                last = time
            }
            #expect(drawn == 30, "\(hz)Hz stepped \(drawn) frames in a second")
        }
    }

    @Test("A panel that cannot land on the tempo runs under it rather than over it")
    func anAwkwardPanelNeverOverdraws() {
        var drawn = 0
        var last = -1.0
        for tick in 0..<144 {
            let time = quantised(Double(tick) / 144)
            guard ActivityTuning.wantsFrame(at: time, lastDrawn: last) else { continue }
            drawn += 1
            last = time
        }
        #expect(drawn == 29)
        #expect(drawn <= Int(ActivityTuning.frameRate))
    }

    /// The clock a GTK frame clock reads is whole microseconds, and the whole bug lived in the
    /// third of a microsecond that rounding takes off a 60 Hz pair of ticks.
    private func quantised(_ seconds: Double) -> Double {
        (seconds * 1_000_000).rounded(.down) / 1_000_000
    }

    @Test("A workflow run wears one mark, and every ending of it holds still")
    func aRunHasOneMark() {
        let run: (WorkflowRun.State) -> WorkflowRun = { state in
            WorkflowRun(id: "r", name: "kaytetty-best", state: state)
        }
        #expect(run(.launching).activityIcon.motion == .turning)
        #expect(run(.running).activityIcon.motion == .turning)
        #expect(run(.finished).activityIcon == ActivityIcon.finished)
        #expect(run(.stopped("gone")).activityIcon == ActivityIcon.stopped)
        #expect(run(.failed("threw")).activityIcon == ActivityIcon.failed)
        for state: WorkflowRun.State in [.finished, .stopped("gone"), .failed("threw")] {
            #expect(run(state).activityIcon.motion == .still)
            #expect(run(state).activityIcon.glyph.count == 1)
            #expect(run(state).isLive == false)
        }
    }

    @Test("A state from a client that never stamped the change shows no invented clock")
    func unstampedStateInventsNothing() {
        let bare = ConversationState(connection: .connecting)
        #expect(StatusFacts.from(
            state: bare, turnStartedAt: nil, agents: [], usage: nil, attachments: 0)
            .connectionFor == nil)
        #expect(StatusFacts.dialClock(nil) == nil)
        #expect(StatusFacts.dialClock(0.5) == nil)
        #expect(StatusFacts.dialClock(9) == 9)
    }
}

@Suite("What an agent row's clock is measured against")
struct AgentClockTests {
    private static let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let reportedAt = startedAt.addingTimeInterval(252)
    private static let now = startedAt.addingTimeInterval(9_000)
    private static let aWeekLater = reportedAt.addingTimeInterval(604_800)

    private static let errand = SubagentSummary(
        id: "c", title: "hunt", updatedAt: reportedAt, isActive: true, isCompleted: false,
        startedAt: startedAt)
    private static let early = SubagentSummary(
        id: "d", title: "scope", updatedAt: startedAt.addingTimeInterval(30), isActive: false,
        isCompleted: true, startedAt: startedAt)
    private static let stale = SubagentSummary(
        id: "e", title: "appraise", updatedAt: reportedAt.addingTimeInterval(1_800),
        isActive: true, isCompleted: false, startedAt: startedAt)

    private static func call(_ status: ToolStatus, reporting: Bool = false) -> ToolCall {
        ToolCall(
            id: "t", name: "Task", status: status,
            background: reporting
                ? BackgroundOutcome(
                    taskID: "task-1", status: .stopped, summary: "No completion was recorded.",
                    reportedAt: reportedAt)
                : nil)
    }

    @Test("An agent still out under a call that is running is the only one timed to the reader")
    func aRunningCallTimesItsAgentToNow() {
        let going = AgentHold(Self.call(.running))
        #expect(Self.errand.elapsed(at: Self.now, under: going) == 9_000)
        #expect(Self.early.elapsed(at: Self.now, under: going) == 30)
        #expect(
            SubagentSummary(id: "f", title: "unstarted", updatedAt: Self.now, isActive: true)
                .elapsed(at: Self.now, under: going) == nil)
    }

    @Test("An agent under a call that is over stops where the work stopped, forever")
    func anEndedCallStopsTheClocksUnderIt() {
        let over = AgentHold(Self.call(.completed))
        #expect(Self.errand.elapsed(at: Self.now, under: over) == 252)
        #expect(
            Self.errand.elapsed(at: Self.aWeekLater, under: over)
                == Self.errand.elapsed(at: Self.reportedAt, under: over))
        #expect(Self.early.elapsed(at: Self.aWeekLater, under: over) == 30)
        for status: ToolStatus in [.pending, .completed, .error] {
            let hold = AgentHold(Self.call(status))
            #expect(
                Self.errand.elapsed(at: Self.now, under: hold)
                    == Self.errand.elapsed(at: Self.aWeekLater, under: hold))
        }
    }

    @Test("A sidecar still claiming to work after the report is credited to the report")
    func aStaleSidecarIsCreditedToTheEnding() {
        let stamped = AgentHold(Self.call(.completed, reporting: true))
        #expect(Self.stale.elapsed(at: Self.now, under: stamped) == 252)
        #expect(Self.early.elapsed(at: Self.now, under: stamped) == 30)
        #expect(
            Self.stale.elapsed(at: Self.now, under: AgentHold(Self.call(.completed))) == 2_052)
    }

    @Test("The live line prints the agent's clock, not the reader's")
    func liveDetailReadsTheGivenMoment() {
        #expect(
            StatusFacts.liveDetail(Self.errand, at: Self.now, under: AgentHold(Self.call(.running)))
                .contains("150m 0s"))
        #expect(
            StatusFacts.liveDetail(
                Self.errand, at: Self.aWeekLater, under: AgentHold(Self.call(.completed)))
                .contains("4m 12s"))
        #expect(
            StatusFacts.liveDetail(
                SubagentSummary(id: "g", title: "quiet", updatedAt: Self.now, isActive: true),
                at: Self.now, under: AgentHold(Self.call(.running))) == Localized.text("working"))
    }

    @Test("The band measures every duration against the moment its facts were read")
    func theBandHoldsOneMoment() {
        let facts = Self.facts(status: .running, connection: .live)
        #expect(facts.readAt == Self.now)
        #expect(facts.connectionFor == 9_000)
        #expect(facts.elapsed == 9_000)
        #expect(Self.agentDetail(facts)?.contains("150m 0s") == true)
    }

    @Test("A turn that is not open settles the agent rows under it")
    func anIdleBandSettlesItsRows() {
        for facts in [
            Self.facts(status: .idle, connection: .live),
            Self.facts(status: .running, connection: .offline),
            Self.facts(status: .running, connection: .reconnecting),
        ] {
            #expect(Self.agentDetail(facts)?.contains("4m 12s") == true)
            #expect(Self.agentDetail(facts)?.contains("150m 0s") == false)
        }
    }

    @Test("An agent's age on the band is read at the same moment as its clock")
    func agesReadTheSameMoment() {
        let facts = Self.facts(status: .idle, connection: .live, agents: [Self.early])
        #expect(Self.agentDetail(facts) == Localized.text("done · %@ ago", "2h"))
    }

    private static func facts(
        status: BackendStatus, connection: ConnectionPhase, agents: [SubagentSummary] = [errand]
    ) -> StatusFacts {
        StatusFacts.from(
            state: ConversationState(
                messages: [], status: status, connection: connection, hasLoadedTranscript: true,
                connectionChangedAt: startedAt),
            turnStartedAt: startedAt, agents: agents, usage: nil, attachments: 0, now: now)
    }

    private static func agentDetail(_ facts: StatusFacts) -> String? {
        facts.segments.first { $0.id == "agents" }?.rows.first?.detail
    }
}
