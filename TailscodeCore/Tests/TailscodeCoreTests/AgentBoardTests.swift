import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func call(
    _ name: String, _ input: [String: JSONValue] = [:], status: ToolStatus = .completed,
    id: String = UUID().uuidString, output: String? = nil
) -> ToolCall {
    ToolCall(id: id, name: name, status: status, input: .object(input), output: output)
}

private func said(_ text: String, ago: TimeInterval = 100) -> ChatMessage {
    ChatMessage(
        id: "u-" + text, role: .user, agentType: .claudeCode,
        parts: [MessagePart(id: "p", kind: .text(text))], createdAt: epoch.addingTimeInterval(-ago))
}

private func worked(_ calls: [ToolCall], open: Bool = true, ago: TimeInterval = 90) -> ChatMessage {
    ChatMessage(
        id: "a-" + (calls.first?.id ?? "none"), role: .assistant, agentType: .claudeCode,
        parts: calls.map { MessagePart(id: "p-" + $0.id, kind: .tool($0)) },
        createdAt: epoch.addingTimeInterval(-ago), completedAt: open ? nil : epoch,
        isStreaming: open)
}

private func state(
    _ messages: [ChatMessage], status: BackendStatus = .running,
    permissions: [PermissionRequest] = [], questions: [QuestionRequest] = [],
    work: BackgroundWork? = nil, failure: BackendFailure? = nil
) -> ConversationState {
    ConversationState(
        messages: messages, status: status, pendingPermissions: permissions,
        pendingQuestions: questions, lastFailure: failure, hasLoadedTranscript: true,
        backgroundWork: work)
}

@Suite struct AgentLineTests {
    @Test func aCallIsSaidAsASentenceInTheTenseItIsIn() {
        let path = ["file_path": JSONValue.string("/repo/Sources/Backoff.swift")]
        #expect(AgentLine.words(for: call("Edit", path, status: .running)) == "Editing Backoff.swift")
        #expect(AgentLine.words(for: call("Edit", path)) == "Edited Backoff.swift")
        #expect(AgentLine.words(for: call("Read", path)) == "Read Backoff.swift")
        #expect(AgentLine.words(for: call("Write", path, status: .running)) == "Writing Backoff.swift")
        #expect(
            AgentLine.words(for: call("Bash", ["command": .string("swift test\nsecond line")]))
                == "Ran swift test")
        #expect(
            AgentLine.words(for: call("Bash", ["command": .string("make")], status: .error))
                == "Ran make, failed")
        #expect(
            AgentLine.words(for: call("Grep", ["pattern": .string("jitter")], status: .running))
                .hasPrefix("Searching"))
        #expect(AgentLine.words(for: call("WebSearch", status: .running)) == "Searching the web")
        #expect(AgentLine.words(for: call("TodoWrite")) == "Updated the plan")
    }

    @Test func aLongCommandIsBoundedNotCut() {
        let long = String(repeating: "word ", count: 40)
        let words = AgentLine.words(for: call("Bash", ["command": .string(long)], status: .running))
        #expect(words.count < 100)
        #expect(words.hasSuffix("…"))
    }

    @Test func whatItIsDoingNowIsTheCallThatIsOut() {
        let running = call("Edit", ["file_path": .string("/a/B.swift")], status: .running, id: "2")
        let done = call("Read", ["file_path": .string("/a/C.swift")], id: "1")
        let now = AgentLine.doing(in: state([said("go"), worked([done, running])]))
        #expect(now == "Editing B.swift")
    }

    @Test func betweenCallsItIsThinkingOrWritingAndNeverBlank() {
        #expect(AgentLine.doing(in: state([said("go")])) == "Thinking")
        #expect(AgentLine.doing(in: state([said("go")], status: .idle)) == nil)
        let ask = PermissionRequest(id: "r", sessionID: "s", title: "Bash", toolName: "Bash")
        #expect(
            AgentLine.doing(in: state([said("go"), worked([call("Bash", status: .pending)])], permissions: [ask]))
                == "Waiting for you")
    }

    @Test func stepsAreNewestFirstAndBounded() {
        let calls = (1...8).map { call("Read", ["file_path": .string("/a/F\($0).swift")], id: "c\($0)") }
        let steps = AgentLine.steps(in: state([said("go"), worked(calls)]), limit: 3)
        #expect(steps.map(\.words) == ["Read F8.swift", "Read F7.swift", "Read F6.swift"])
        #expect(steps.allSatisfy { $0.outcome == .done })
    }

    @Test func touchedIsEachEditedFileOnceInTheOrderItChanged() {
        let calls = [
            call("Edit", ["file_path": .string("/a/B.swift")], id: "1"),
            call("Read", ["file_path": .string("/a/R.swift")], id: "2"),
            call("Write", ["file_path": .string("/a/N.swift")], id: "3"),
            call("Edit", ["file_path": .string("/z/B.swift")], id: "4"),
        ]
        #expect(AgentLine.touched(in: state([said("go"), worked(calls)])) == ["B.swift", "N.swift"])
    }
}

@Suite struct AgentBeatTests {
    @Test func stampsFallIntoTheirSlicesAndOldOnesDropOut() {
        let now = epoch
        let stamps = [0.2, 0.4, 2.0, 30.0, 59.0, 61.0, 500.0].map { now.addingTimeInterval(-$0) }
        let beat = AgentBeat.read(stamps: stamps, now: now)
        #expect(beat.count == 24)
        #expect(beat.last == 3)
        #expect(beat[23 - 12] == 1)
        #expect(beat.reduce(0, +) == 5)
    }

    @Test func aBusySliceStopsAtTheCeiling() {
        let stamps = (0..<30).map { epoch.addingTimeInterval(-Double($0) * 0.01) }
        #expect(AgentBeat.read(stamps: stamps, now: epoch).last == AgentBeat.ceiling)
    }

    @Test func prunedKeepsOnlyTheLastMinute() {
        let stamps = [10, 59, 61, 600].map { epoch.addingTimeInterval(-Double($0)) }
        #expect(AgentBeat.pruned(stamps, now: epoch).count == 2)
    }
}

@Suite struct AgentWatchTests {
    private func candidate(
        _ key: String, running: Bool = true, waiting: Bool = false, age: TimeInterval = 0,
        held: Bool = false, pinned: Bool = false, lingering: Bool = false
    ) -> AgentWatch.Candidate {
        AgentWatch.Candidate(
            key: key, isRunning: running, waiting: waiting,
            updatedAt: epoch.addingTimeInterval(-age), held: held, pinned: pinned,
            lingering: lingering)
    }

    @Test func nothingRunningWatchesNothing() {
        let plan = AgentWatch.plan(candidates: [candidate("a", running: false), candidate("b", running: false)])
        #expect(plan.attach.isEmpty && plan.release.isEmpty && plan.listedOnly.isEmpty)
    }

    @Test func nineRunningWatchSixAndSayTheRest() {
        let nine = (0..<9).map { candidate("s\($0)", age: Double($0)) }
        let plan = AgentWatch.plan(candidates: nine)
        #expect(plan.attach.count == 6)
        #expect(plan.attach == ["s0", "s1", "s2", "s3", "s4", "s5"])
        #expect(plan.listedOnly == ["s6", "s7", "s8"])
    }

    @Test func aSessionWaitingOnYouIsNeverLeftUnwatched() {
        var all = (0..<8).map { candidate("s\($0)", age: Double($0)) }
        all.append(candidate("asks", waiting: true, age: 9_000))
        #expect(AgentWatch.plan(candidates: all).attach.contains("asks"))
        #expect(AgentWatch.plan(candidates: all).attach.first == "asks")
    }

    @Test func heldSessionsAreStickyAgainstNewerOnes() {
        var all = (0..<6).map { candidate("held\($0)", age: 500 + Double($0), held: true) }
        all.append(candidate("newer", age: 1))
        let plan = AgentWatch.plan(candidates: all)
        #expect(plan.attach.isEmpty)
        #expect(plan.release.isEmpty)
        #expect(plan.listedOnly == ["newer"])
    }

    @Test func aPinnedRowTakesTheLeastRecentSlotButNeverOneWaitingOnYou() {
        var all = (0..<6).map { candidate("held\($0)", age: 500 + Double($0), held: true) }
        all.append(candidate("listed", age: 9_000, pinned: true))
        let plan = AgentWatch.plan(candidates: all)
        #expect(plan.attach == ["listed"])
        #expect(plan.release == ["held5"])
        all[0] = candidate("asks", waiting: true, age: 9_000, held: true)
        let waiting = AgentWatch.plan(candidates: all)
        #expect(waiting.release.contains("held5") && !waiting.release.contains("asks"))
    }

    @Test func aWatchThatStoppedIsReleasedAfterItLingers() {
        let lingering = candidate("a", running: false, held: true, lingering: true)
        #expect(AgentWatch.plan(candidates: [lingering]).release.isEmpty)
        let over = candidate("a", running: false, held: true, lingering: false)
        #expect(AgentWatch.plan(candidates: [over]).release == ["a"])
    }
}

@Suite struct AgentFactsTests {
    @Test func aRunningTurnIsWorkingWithItsStepsAndTouchedFiles() {
        let edit = call("Edit", ["file_path": .string("/r/Backoff.swift")], status: .running, id: "e")
        let read = call("Read", ["file_path": .string("/r/Tests.swift")], id: "r")
        let facts = AgentFacts.read(
            state: state([said("go"), worked([read, edit])]), agents: [], seen: ["e": epoch],
            stamps: [epoch], now: epoch)
        #expect(facts.phase == .working && facts.isRunning)
        #expect(facts.doing == "Editing Backoff.swift")
        #expect(facts.steps.first?.seen == epoch)
        #expect(facts.toolCount == 2)
        #expect(facts.beat.last == 1)
        #expect(facts.startedAt != nil)
    }

    @Test func aPendingApprovalIsNeedsYouWithTheCommand() {
        let bash = call("Bash", ["command": .string("rm -rf build")], status: .pending, id: "b")
        let ask = PermissionRequest(id: "perm", sessionID: "s", title: "Bash", toolName: "Bash")
        let facts = AgentFacts.read(
            state: state([said("go"), worked([bash])], permissions: [ask]), agents: [],
            seen: ["perm": epoch.addingTimeInterval(-120)], now: epoch)
        #expect(facts.phase == .needsYou)
        #expect(facts.ask?.object == "rm -rf build")
        #expect(facts.ask?.isApproval == true)
        #expect(facts.ask?.since == epoch.addingTimeInterval(-120))
    }

    @Test func backgroundWorkWithNoTurnOpenIsBackground() {
        let work = BackgroundWork(tasks: 2, task: nil, since: epoch.addingTimeInterval(-300), stalled: true)
        let facts = AgentFacts.read(state: state([said("go")], status: .idle, work: work), agents: [], now: epoch)
        #expect(facts.phase == .background(tasks: 2, stalled: true))
        #expect(!facts.isRunning)
        #expect(facts.children.first?.kind == .background)
    }

    @Test func liveAgentsHangUnderTheTurnWithTheirTodos() {
        let agent = SubagentSummary(
            id: "a1", title: "Explore", updatedAt: epoch, isActive: true, startedAt: epoch.addingTimeInterval(-60),
            toolCount: 4, currentTool: "Read", todosDone: 4, todosTotal: 6, currentTodo: "reading")
        let done = SubagentSummary(id: "a2", title: "Old", updatedAt: epoch, isActive: false, isCompleted: true)
        let facts = AgentFacts.read(state: state([said("go")]), agents: [agent, done], now: epoch)
        #expect(facts.children.map(\.title) == ["Explore"])
        #expect(facts.children.first?.todos?.done == 4)
        #expect(facts.children.first?.todos?.total == 6)
    }

    @Test func aFailedTurnIsFlaggedAndIdle() {
        let facts = AgentFacts.read(
            state: state([said("go")], status: .idle, failure: BackendFailure(message: "boom", retryable: false)),
            agents: [], now: epoch)
        #expect(facts.phase == .idle && facts.failed)
    }
}

@Suite struct AgentBoardTests {
    private func entry(
        _ id: String, profile: String = "p1", machine: String = "studio", title: String? = nil,
        active: Bool = false, agents: Int? = nil, task: String? = nil, work: BackgroundWork? = nil,
        parent: String? = nil, updated: TimeInterval = 0
    ) -> SessionEntry {
        var session = AgentSession(
            id: id, agentType: .claudeCode, title: title ?? "Chat \(id)", parentID: parent,
            createdAt: epoch, updatedAt: epoch.addingTimeInterval(-updated), isActive: active)
        session.activeAgents = agents
        session.agentTask = task
        session.backgroundWork = work
        return SessionEntry(
            profileID: profile, profileName: machine, host: machine, backendType: .claudeCode,
            session: session)
    }

    private func facts(_ state: ConversationState, agents: [SubagentSummary] = []) -> AgentFacts {
        AgentFacts.read(state: state, agents: agents, now: epoch)
    }

    private var working: AgentFacts {
        facts(state([said("go"), worked([call("Edit", ["file_path": .string("/a/B.swift")], status: .running)])]))
    }

    private var asking: AgentFacts {
        let bash = call("Bash", ["command": .string("rm -rf build")], status: .pending, id: "b")
        let ask = PermissionRequest(id: "perm", sessionID: "s", title: "Bash", toolName: "Bash")
        return facts(state([said("go"), worked([bash])], permissions: [ask]))
    }

    @Test func eachSessionStandsOnceInTheMostUrgentPlace() {
        let board = AgentBoard.read(
            sources: [
                AgentSource(entry: entry("w"), facts: working, reachable: true, unread: false),
                AgentSource(entry: entry("n"), facts: asking, reachable: true, unread: false),
                AgentSource(entry: entry("l", active: true, agents: 2, task: "explore"), facts: nil, reachable: true, unread: false),
                AgentSource(entry: entry("b", work: BackgroundWork(tasks: 1, task: "swift test")), facts: nil, reachable: true, unread: false),
                AgentSource(entry: entry("sub", active: true, parent: "w"), facts: nil, reachable: true, unread: false),
            ], now: epoch)
        #expect(board.needsYou.map(\.sessionID) == ["n"])
        #expect(board.working.map(\.sessionID).sorted() == ["l", "w"])
        #expect(board.background.map(\.sessionID) == ["b"])
        #expect(board.headline.working == 2 && board.headline.needsYou == 1)
        #expect(board.sentence == "2 working · 1 needs you")
        #expect(!board.working.contains { $0.sessionID == "sub" })
    }

    @Test func aWatchedRowKnowsMoreThanAListedOne() {
        let board = AgentBoard.read(
            sources: [
                AgentSource(entry: entry("w"), facts: working, reachable: true, unread: false),
                AgentSource(entry: entry("l", active: true, agents: 2, task: "explore"), facts: nil, reachable: true, unread: false),
            ], now: epoch)
        let watched = board.working.first { $0.sessionID == "w" }
        let listed = board.working.first { $0.sessionID == "l" }
        #expect(watched?.isWatched == true && watched?.line == "Editing B.swift" && watched?.beat != nil)
        #expect(listed?.isWatched == false && listed?.line == "explore" && listed?.listedAgents == 2)
        #expect(board.working.first?.sessionID == "w")
    }

    @Test func machinesAreNamedOnlyWhenThereIsMoreThanOne() {
        let one = AgentBoard.read(
            sources: [AgentSource(entry: entry("w"), facts: working, reachable: true, unread: false)], now: epoch)
        #expect(!one.showsMachines)
        let two = AgentBoard.read(
            sources: [
                AgentSource(entry: entry("w"), facts: working, reachable: true, unread: false),
                AgentSource(entry: entry("x", profile: "p2", machine: "homelab", active: true), facts: nil, reachable: false, unread: false),
            ], now: epoch)
        #expect(two.showsMachines)
        #expect(two.machines.map(\.name) == ["studio", "homelab"])
        #expect(two.working.first { $0.sessionID == "x" }?.isAway == true)
        #expect(two.watchLine.contains("studio, homelab"))
    }

    @Test func theWatchLineSaysWhatItCouldNotAfford() {
        var sources: [AgentSource] = []
        for index in 0..<9 {
            sources.append(
                AgentSource(
                    entry: entry("s\(index)", active: true), facts: index < 6 ? working : nil,
                    reachable: true, unread: false))
        }
        let board = AgentBoard.read(sources: sources, now: epoch)
        #expect(board.running == 9 && board.watched == 6)
        #expect(board.watchLine.hasPrefix("Watching 6 of 9 running"))
    }

    @Test func nothingRunningSaysSo() {
        let board = AgentBoard.read(sources: [], now: epoch)
        #expect(board.sentence == "Nothing is running")
        #expect(board.isEmpty)
        #expect(board.watchLine == "Nothing to watch")
    }

    @Test func theLastHoursEndingsAreListedUnreadAndOlderOnesAreNot() {
        let mine = AgentFinish(
            id: "p1/w", profileID: "p1", sessionID: "w", title: "Chat w", machine: "studio",
            outcome: .done, line: "Done in 6m", endedAt: epoch.addingTimeInterval(-600), unread: true)
        let old = AgentFinish(
            id: "p1/o", profileID: "p1", sessionID: "o", title: "Old", machine: "studio",
            outcome: .done, line: "Done", endedAt: epoch.addingTimeInterval(-7200), unread: true)
        let board = AgentBoard.read(
            sources: [
                AgentSource(entry: entry("quiet", updated: 300), facts: nil, reachable: true, unread: true),
                AgentSource(entry: entry("read", updated: 300), facts: nil, reachable: true, unread: false),
                AgentSource(entry: entry("ancient", updated: 9000), facts: nil, reachable: true, unread: true),
            ], finished: [mine, old], now: epoch)
        #expect(board.finished.map(\.sessionID) == ["quiet", "w"])
        #expect(board.finished.first?.outcome == .unknown)
        #expect(board.headline.unread == 2)
    }

    @Test func theFinishLineCountsWhatItDid() {
        #expect(AgentFinish.line(outcome: .done, duration: 372, tools: 14, files: 3) == "Done in 6m · 14 tools · edited 3 files")
        #expect(AgentFinish.line(outcome: .done, duration: 40, tools: 0, files: 1) == "Done in 40s · edited 1 file")
        #expect(AgentFinish.line(outcome: .failed, duration: 5, tools: 1, files: 0, failure: "build exited 1") == "Failed: build exited 1")
        #expect(AgentFinish.line(outcome: .stopped, duration: nil, tools: 0, files: 0) == "Stopped")
    }
}

@Suite struct AgentHourTests {
    private func note(_ log: inout AgentHourLog, _ phase: AgentHourPhase?, at offset: TimeInterval, id: String = "a", parent: String? = nil) {
        log.note(
            id: id, parentID: parent, profileID: "p", sessionID: "s", title: id, machine: "m",
            phase: phase, at: epoch.addingTimeInterval(offset))
    }

    @Test func phasesBecomeSpansAndTheOpenOneRunsToNow() {
        var log = AgentHourLog()
        log.beginObserving(at: epoch.addingTimeInterval(-3000))
        note(&log, .working, at: -1000)
        note(&log, .working, at: -900)
        note(&log, .needsYou, at: -500)
        note(&log, nil, at: -300)
        note(&log, .working, at: -100)
        let hour = log.hour(now: epoch)
        let lane = hour.lanes.first
        #expect(lane?.spans.map(\.phase) == [.working, .needsYou, .working])
        #expect(lane?.spans.last?.end == epoch)
        #expect(lane?.spans.first?.start == epoch.addingTimeInterval(-1000))
    }

    @Test func spansAreClippedToTheHourAndMarksKept() {
        var log = AgentHourLog()
        log.beginObserving(at: epoch.addingTimeInterval(-9000))
        note(&log, .working, at: -5000)
        note(&log, nil, at: -1200)
        log.end(id: "a", outcome: .failed, at: epoch.addingTimeInterval(-1200))
        let lane = log.hour(now: epoch).lanes.first
        #expect(lane?.spans.first?.start == epoch.addingTimeInterval(-3600))
        #expect(lane?.marks.first?.outcome == .failed)
    }

    @Test func whatTheDeviceDidNotWatchIsUnseenNotEmpty() {
        var log = AgentHourLog()
        log.beginObserving(at: epoch.addingTimeInterval(-2400))
        log.endObserving(at: epoch.addingTimeInterval(-1800))
        log.beginObserving(at: epoch.addingTimeInterval(-600))
        let unseen = log.hour(now: epoch).unseen
        #expect(unseen.count == 2)
        #expect(unseen[0].start == epoch.addingTimeInterval(-3600) && unseen[0].end == epoch.addingTimeInterval(-2400))
        #expect(unseen[1].start == epoch.addingTimeInterval(-1800) && unseen[1].end == epoch.addingTimeInterval(-600))
    }

    @Test func agentsHangUnderTheirSessionsLane() {
        var log = AgentHourLog()
        log.beginObserving(at: epoch.addingTimeInterval(-3000))
        note(&log, .working, at: -900, id: "a")
        note(&log, .working, at: -800, id: "a#x", parent: "a")
        note(&log, .working, at: -700, id: "b")
        let lanes = log.hour(now: epoch).lanes
        #expect(lanes.map(\.id) == ["a", "a#x", "b"])
        #expect(lanes[1].parentID == "a")
    }

    @Test func aSessionThatNeverWorkedHasNoLane() {
        var log = AgentHourLog()
        note(&log, nil, at: -100)
        #expect(log.hour(now: epoch).lanes.isEmpty)
    }
}

private final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@Suite struct AgentTowerTests {
    private func runningScript() -> [MockScriptStep] {
        let edit = call("Edit", ["file_path": .string("/r/Backoff.swift")], status: .running, id: "e1")
        let message = ChatMessage(
            id: "a1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p1", kind: .tool(edit))], createdAt: Date(), isStreaming: true)
        return [
            MockScriptStep(.messageUpserted(said("go", ago: 5), replaceParts: true)),
            MockScriptStep(.status(.running)),
            MockScriptStep(.messageUpserted(message, replaceParts: true)),
        ]
    }

    @Test func aRunningSessionIsWatchedReadAndPublishedThenReleased() async throws {
        let backend = MockBackend(agentType: .claudeCode, script: runningScript(), interactive: true)
        let tower = AgentTower(
            setup: AgentTowerSetup(backend: { _ in backend }, catalog: { _ in [] }))
        var session = AgentSession(
            id: "s1", agentType: .claudeCode, title: "Fix the thing", createdAt: Date(),
            updatedAt: Date(), isActive: true)
        session.activeAgents = nil
        let entry = SessionEntry(
            profileID: "p1", profileName: "studio", host: "studio", backendType: .claudeCode,
            session: session)
        await tower.update(entries: [entry], reachability: ["p1": true], unread: [])
        await tower.open()
        var line: String?
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            line = await tower.current.working.first?.line
            if line == "Editing Backoff.swift" { break }
        }
        #expect(line == "Editing Backoff.swift")
        let board = await tower.current
        #expect(board.working.first?.isWatched == true)
        #expect(board.watched == 1)
        var heard: AgentFacts?
        for await facts in await tower.facts(for: "p1/s1") {
            heard = facts
            break
        }
        #expect(heard?.doing == "Editing Backoff.swift")
        await tower.close()
        try await Task.sleep(for: .milliseconds(1200))
        let closed = await tower.current
        #expect(closed.working.first?.isWatched == false)
        let hour = await tower.hour()
        #expect(hour.lanes.first?.spans.first?.phase == .working)
    }

    @Test func aQuietSessionsHeartbeatGoesFlatOnThePoll() async throws {
        let clock = TickingClock()
        let backend = MockBackend(agentType: .claudeCode, script: runningScript(), interactive: true)
        let tower = AgentTower(
            setup: AgentTowerSetup(backend: { _ in backend }, catalog: { _ in [] }),
            poll: .milliseconds(50), clock: { clock.now })
        let session = AgentSession(
            id: "s1", agentType: .claudeCode, title: "t", createdAt: Date(), updatedAt: Date(),
            isActive: true)
        let entry = SessionEntry(
            profileID: "p1", profileName: "studio", host: "studio", backendType: .claudeCode,
            session: session)
        await tower.update(entries: [entry], reachability: ["p1": true], unread: [])
        await tower.open()
        var beat: [Int]?
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            beat = await tower.current.working.first?.beat
            if beat?.contains(where: { $0 > 0 }) == true { break }
        }
        #expect(beat?.contains(where: { $0 > 0 }) == true)
        clock.advance(120)
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            beat = await tower.current.working.first?.beat
            if beat?.allSatisfy({ $0 == 0 }) == true { break }
        }
        #expect(beat?.allSatisfy { $0 == 0 } == true)
        await tower.close()
    }

    @Test func anApprovalShowsEveryLineOfTheCommand() {
        let command = "ls\nrm -rf ~"
        let bash = call("Bash", ["command": .string(command)], status: .pending, id: "b1")
        let message = ChatMessage(
            id: "a1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p1", kind: .tool(bash))], createdAt: Date(), isStreaming: true)
        let state = ConversationState(
            messages: [said("go", ago: 5), message], status: .running,
            pendingPermissions: [PermissionRequest(id: "perm", sessionID: "s1", title: "Bash", toolName: "Bash")],
            hasLoadedTranscript: true)
        #expect(AgentAsk.reading(in: state)?.object == command)
        #expect(ApprovalAsk.reading(in: state)?.object == "ls")
    }

    @Test func nothingIsWatchedWhileTheBoardIsClosed() async throws {
        let backend = MockBackend(agentType: .claudeCode, script: runningScript(), interactive: true)
        let tower = AgentTower(
            setup: AgentTowerSetup(backend: { _ in backend }, catalog: { _ in [] }))
        let session = AgentSession(
            id: "s1", agentType: .claudeCode, title: "t", createdAt: Date(), updatedAt: Date(),
            isActive: true)
        let entry = SessionEntry(
            profileID: "p1", profileName: "studio", host: "studio", backendType: .claudeCode,
            session: session)
        await tower.update(entries: [entry], reachability: [:], unread: [])
        try await Task.sleep(for: .milliseconds(1500))
        let board = await tower.current
        #expect(board.working.first?.isWatched == false)
        #expect(board.working.first?.line == nil)
    }
}

@Suite struct AgentDemoTests {
    @Test func theDemoBoardIsTheDesignsBoard() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let board = AgentDemo.board(now: now)
        #expect(board.sentence == "2 working · 1 needs you")
        #expect(board.needsYou.map(\.title) == ["CI migration"])
        #expect(board.needsYou.first?.ask.object == "rm -rf build && swift build -c release")
        #expect(board.working.first?.title == "Fix reconnect test")
        #expect(board.working.first?.line == "Editing Backoff.swift")
        #expect(board.working.first?.children.count == 2)
        #expect(board.background.map(\.title) == ["Release notes"])
        #expect(board.finished.first?.title == "Deploy check")
        #expect(board.showsMachines)
    }

    @Test func theDemoPeekAndHourHaveWhatTheyDraw() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let facts = AgentDemo.facts(now: now)
        #expect(facts.steps.count == 4 && facts.steps.first?.words == "Editing Backoff.swift")
        #expect(facts.touched == ["Backoff.swift"])
        #expect(facts.object == AgentObject(kind: .path, text: "/repo/Sources/Reconnect/Backoff.swift", added: 9, removed: 3))
        #expect(facts.children.map(\.title).contains("Explore"))
        let hour = AgentDemo.hour(now: now)
        #expect(hour.lanes.contains { $0.parentID != nil })
        let board = AgentDemo.board(now: now)
        let keys = Set((board.needsYou.map(\.id) + board.working.map(\.id) + board.background.map(\.id)))
        #expect(hour.lanes.filter { $0.parentID == nil }.allSatisfy { lane in
            lane.profileID + "/" + lane.sessionID == lane.id
        })
        #expect(keys.isSubset(of: Set(hour.lanes.map(\.id))))
        #expect(hour.lanes.flatMap(\.marks).map(\.outcome).contains(.failed))
        #expect(hour.unseen.count == 1)
    }
}
