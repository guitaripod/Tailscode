import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let landscape = 16.0 / 9.0
private let portrait = 9.0 / 16.0

private func crewman(
    _ id: String, started: TimeInterval = 100, moved: TimeInterval = 2, tool: String? = "Read",
    todos: (Int, Int)? = nil, current: String? = nil, at now: Date = epoch
) -> SubagentSummary {
    SubagentSummary(
        id: id, title: id.capitalized, updatedAt: now.addingTimeInterval(-moved), isActive: true,
        startedAt: now.addingTimeInterval(-started), toolCount: 6, currentTool: tool,
        todosDone: todos?.0, todosTotal: todos?.1, currentTodo: current)
}

private func session(
    _ id: String = "s", crew: [SubagentSummary], work: BackgroundWork? = nil,
    permissions: [PermissionRequest] = [], at now: Date = epoch
) -> AgentSource {
    let said = ChatMessage(
        id: "u", role: .user, agentType: .claudeCode,
        parts: [MessagePart(id: "p", kind: .text("go"))], createdAt: now.addingTimeInterval(-300))
    var messages = [said]
    if !permissions.isEmpty {
        let bash = ToolCall(
            id: "b", name: "Bash", status: .pending, input: .object(["command": .string("make")]))
        messages.append(
            ChatMessage(
                id: "a", role: .assistant, agentType: .claudeCode,
                parts: [MessagePart(id: "pb", kind: .tool(bash))],
                createdAt: now.addingTimeInterval(-200), isStreaming: true))
    }
    let state = ConversationState(
        messages: messages, status: .running, pendingPermissions: permissions,
        hasLoadedTranscript: true, backgroundWork: work)
    var listing = AgentSession(
        id: id, agentType: .claudeCode, title: "Chat \(id)", createdAt: now, updatedAt: now,
        isActive: true)
    listing.backgroundWork = work
    let stamps = (0..<40).map { now.addingTimeInterval(-Double($0) * 1.4) }
    return AgentSource(
        entry: SessionEntry(
            profileID: "p1", profileName: "studio", host: "studio", backendType: .claudeCode,
            session: listing),
        facts: AgentFacts.read(state: state, agents: crew, stamps: stamps, now: now),
        reachable: true, unread: false)
}

private func wall(
    _ sources: [AgentSource], now: Date = epoch, aspect: Double = landscape,
    previous: AgentWall? = nil
) -> AgentWall {
    AgentWall.read(
        board: AgentBoard.read(sources: sources, now: now), hour: nil, now: now, aspect: aspect,
        previous: previous)
}

private func crewOf(_ wall: AgentWall, _ id: String = "s") -> [WallWorker] {
    wall.tiles.first { $0.id == "p1/" + id }?.workers ?? []
}

@Suite struct WallWorkerReadingTests {
    @Test func aSessionsSubAgentsBecomeWorkersWithTheirWordsAndTodos() throws {
        let read = wall([
            session(crew: [
                crewman("explore", started: 190, tool: "Read", todos: (4, 6), current: "reading the retry paths")
            ])
        ])
        let explore = try #require(crewOf(read).first)
        #expect(explore.id == "p1/s#explore" && explore.kind == .agent)
        #expect(explore.title == "Explore" && explore.words == "reading the retry paths")
        #expect(explore.state == .working && explore.progress == 4.0 / 6.0)
        #expect(explore.toolCount == 6 && explore.startedAt == epoch.addingTimeInterval(-190))
        #expect(explore.statusWord(at: epoch) == "Working")
    }

    @Test func anAgentWithNoTodoSaysWhichToolItHasOut() throws {
        let read = wall([session(crew: [crewman("plan", tool: "Grep")])])
        #expect(crewOf(read).first?.words == "Searching the code")
        #expect(crewOf(read).first?.progress == nil)
    }

    @Test func backgroundWorkIsAWorkerAndTheLongestRunningComesFirst() throws {
        let work = BackgroundWork(
            tasks: 1, task: "swift test", since: epoch.addingTimeInterval(-1320), stalled: true)
        let read = wall([session(crew: [crewman("a"), crewman("b")], work: work)])
        let line = crewOf(read)
        #expect(line.map(\.title) == ["Running the tests", "A", "B"])
        #expect(line[0].state == .background(stuck: true) && line[0].kind == .background)
        #expect(line[0].words.isEmpty && line[0].statusWord(at: epoch) == "stuck")
    }

    @Test func workingAgentsKeepTheOrderOfWhoStartedFirst() {
        let read = wall([
            session(crew: [
                crewman("late", started: 30), crewman("early", started: 300), crewman("mid", started: 90),
            ])
        ])
        #expect(crewOf(read).map(\.title) == ["Early", "Mid", "Late"])
    }

    @Test(arguments: [(89.0, false), (90.0, true), (200.0, true)])
    func anAgentTheListingHasNotSeenMoveForNinetySecondsIsQuiet(moved: Double, quiet: Bool) {
        let worker = crewOf(wall([session(crew: [crewman("t", moved: moved)])])).first
        #expect((worker?.state == .quiet(since: epoch.addingTimeInterval(-moved))) == quiet)
    }

    @Test func aQuietAgentCountsFromWhenItLastMovedAndKeepsItsPlace() {
        let read = wall([session(crew: [crewman("busy", started: 400), crewman("stalled", moved: 200)])])
        #expect(crewOf(read).map(\.title) == ["Busy", "Stalled"])
        let stalled = crewOf(read).last
        #expect(stalled?.statusWord(at: epoch) == "quiet for 3m")
        #expect(stalled?.state.needsEyes == true)
    }

    @Test func anAgentThatGoesQuietStaysWhereItWasAmongTheOthers() {
        let one = wall([session(crew: [crewman("a", started: 300), crewman("b", started: 200), crewman("c", started: 100)])])
        let later = epoch.addingTimeInterval(1)
        let two = wall(
            [
                session(
                    crew: [
                        crewman("a", started: 301, at: later), crewman("b", started: 201, moved: 300, at: later),
                        crewman("c", started: 101, at: later),
                    ], at: later)
            ], now: later, previous: one)
        #expect(crewOf(two).map(\.title) == ["A", "B", "C"])
        #expect(crewOf(two)[1].state.needsEyes)
    }

    @Test func nothingIsCalledQuietBehindAnAsk() {
        let request = PermissionRequest(id: "perm", sessionID: "s", title: "Bash", toolName: "Bash")
        let read = wall([session(crew: [crewman("t", moved: 400)], permissions: [request])])
        #expect(crewOf(read).first?.state == .working)
    }

    @Test func aSessionNobodyWatchesFirstHandHasNoWorkersButItsListingCount() {
        var listing = AgentSession(
            id: "x", agentType: .claudeCode, title: "Elsewhere", createdAt: epoch, updatedAt: epoch,
            isActive: true)
        listing.activeAgents = 2
        listing.agentTask = "Searching the footer"
        let source = AgentSource(
            entry: SessionEntry(
                profileID: "p1", profileName: "homelab", host: "homelab", backendType: .claudeCode,
                session: listing),
            facts: nil, reachable: true, unread: false)
        let read = wall([source])
        #expect(read.tiles.isEmpty)
        #expect(read.listed.first?.agents == 2)
    }

    @Test func theWallCountsSubAgentsAndSaysSoOnlyWhenThereAreSome() {
        let work = BackgroundWork(tasks: 1, task: "swift test", since: epoch, stalled: false)
        #expect(wall([session(crew: [])]).subagentsLine == nil)
        #expect(wall([session(crew: [crewman("a")])]).subagentsLine == "one sub-agent")
        let several = wall([session(crew: [crewman("a"), crewman("b"), crewman("c")], work: work)])
        #expect(several.subagents == 3 && several.subagentsLine == "3 sub-agents")
    }
}

@Suite struct WallWorkerLifetimeTests {
    private func read(_ crew: [SubagentSummary], at now: Date, after previous: AgentWall?) -> AgentWall {
        wall([session(crew: crew, at: now)], now: now, previous: previous)
    }

    @Test func anAgentThatLeavesTheRosterCoolsForHalfAMinuteThenGoes() throws {
        let one = read([crewman("a"), crewman("b")], at: epoch, after: nil)
        let leaving = epoch.addingTimeInterval(3)
        let two = read([crewman("a", at: leaving)], at: leaving, after: one)
        let gone = try #require(crewOf(two).first { $0.title == "B" })
        #expect(gone.state.isFinished && gone.stateSince == leaving && gone.fade == 0)
        #expect(gone.statusWord(at: leaving) == "Finished")
        let later = leaving.addingTimeInterval(15)
        let three = read([crewman("a", at: later)], at: later, after: two)
        let cooling = try #require(crewOf(three).first { $0.title == "B" })
        #expect(cooling.stateSince == leaving && cooling.fade == 0.5)
        let end = leaving.addingTimeInterval(30)
        let four = read([crewman("a", at: end)], at: end, after: three)
        #expect(crewOf(four).map(\.title) == ["A"])
    }

    @Test func aFinishedWorkerCoolsInItsOwnPlace() {
        let one = read([crewman("a", started: 500), crewman("b", started: 10)], at: epoch, after: nil)
        let next = epoch.addingTimeInterval(2)
        let two = read([crewman("b", started: 12, at: next)], at: next, after: one)
        #expect(crewOf(two).map(\.title) == ["A", "B"])
        #expect(crewOf(two).map(\.state.isFinished) == [true, false])
    }

    @Test func aWorkerThatComesBackIsWorkingAgainAndNotAlsoFinished() {
        let one = read([crewman("a")], at: epoch, after: nil)
        let gap = epoch.addingTimeInterval(2)
        let two = read([], at: gap, after: one)
        let back = epoch.addingTimeInterval(4)
        let three = read([crewman("a", at: back)], at: back, after: two)
        #expect(crewOf(three).count == 1 && crewOf(three).first?.state == .working)
    }

    @Test func aSessionThatEndsTakesItsWorkersWithIt() {
        let one = read([crewman("a")], at: epoch, after: nil)
        let next = epoch.addingTimeInterval(2)
        let two = wall([], now: next, previous: one)
        #expect(two.tiles.isEmpty && two.subagents == 0)
    }

    @Test func aFinishedWorkerIsNotCountedAsRunning() {
        let one = read([crewman("a"), crewman("b")], at: epoch, after: nil)
        let next = epoch.addingTimeInterval(2)
        let two = read([crewman("a", at: next)], at: next, after: one)
        #expect(two.subagents == 1)
    }
}

@Suite struct WallSquadTests {
    private func workers(_ count: Int, quietAt: Int? = nil) -> [WallWorker] {
        let crew = (0..<count).map {
            crewman("w\($0)", started: Double(1000 - $0), moved: $0 == quietAt ? 300 : 2)
        }
        return crewOf(wall([session(crew: crew)]))
    }

    @Test(arguments: [(1, 6), (2, 5), (3, 4), (4, 3), (6, 3)])
    func theFewerSessionsShareTheWallTheMoreWorkersACellAffords(sessions: Int, capacity: Int) {
        #expect(WallSquad.capacity(sessions: sessions) == capacity)
    }

    @Test func aSessionWithNoWorkersHasNoSquad() {
        #expect(WallSquad.plan(workers: [], sessions: 1, cellAspect: 1.8) == nil)
        #expect(wall([session(crew: [])]).tiles.first?.squad == nil)
    }

    @Test func everyWorkerThatFitsGetsASlotAndNothingIsHidden() throws {
        let squad = try #require(WallSquad.plan(workers: workers(4), sessions: 2, cellAspect: 1.6))
        #expect(squad.slots.count == 4 && squad.hidden == 0 && squad.more == nil)
    }

    @Test func pastTheCapacityTheLastSlotCountsWhatDidNotFit() throws {
        let squad = try #require(WallSquad.plan(workers: workers(7), sessions: 4, cellAspect: 1.6))
        #expect(squad.slots.count == 2 && squad.hidden == 5 && squad.more != nil)
        #expect(!squad.moreNeedsEyes)
    }

    @Test func theCountTileSaysSoWhenTheFirstHiddenAgentIsQuiet() throws {
        let crew = (0..<5).map { crewman("w\($0)", started: 1000 - Double($0), moved: $0 < 4 ? 300 : 2) }
        let squad = try #require(
            WallSquad.plan(workers: crewOf(wall([session(crew: crew)])), sessions: 4, cellAspect: 1.6))
        #expect(squad.moreNeedsEyes)
    }

    @Test func aWideCellPutsTheSessionLeftAndAnArrowCellPutsItOnTop() throws {
        let wide = try #require(WallSquad.plan(workers: workers(3), sessions: 2, cellAspect: 1.8))
        #expect(wide.parent.x == 0 && wide.parent.height == 1 && wide.parent.width < 0.6)
        #expect(wide.slots.allSatisfy { $0.x > wide.parent.width })
        let tall = try #require(WallSquad.plan(workers: workers(3), sessions: 2, cellAspect: 0.9))
        #expect(tall.parent.y == 0 && tall.parent.width == 1)
        #expect(tall.slots.allSatisfy { $0.y > tall.parent.height })
    }

    @Test(arguments: [(1, 1.8), (2, 1.8), (3, 1.0), (5, 0.6), (6, 2.4), (9, 1.6)])
    func theFramesStayInsideTheCellAndNeverOverlap(count: Int, aspect: Double) throws {
        let squad = try #require(WallSquad.plan(workers: workers(count), sessions: 1, cellAspect: aspect))
        let frames = [squad.parent] + squad.slots + [squad.more].compactMap { $0 }
        for frame in frames {
            #expect(frame.x >= -0.0001 && frame.y >= -0.0001)
            #expect(frame.x + frame.width <= 1.0001 && frame.y + frame.height <= 1.0001)
            #expect(frame.width > 0.05 && frame.height > 0.05)
        }
        for (index, first) in frames.enumerated() {
            for second in frames[(index + 1)...] {
                let apart =
                    first.x + first.width <= second.x + 0.0001
                    || second.x + second.width <= first.x + 0.0001
                    || first.y + first.height <= second.y + 0.0001
                    || second.y + second.height <= first.y + 0.0001
                #expect(apart)
            }
        }
    }

    @Test func theGridPlacesTheSquadInTheCellsRealShape() throws {
        let single = wall([session(crew: [crewman("a"), crewman("b")])], aspect: landscape)
        #expect(single.tiles.first?.squad?.parent.height == 1)
        let tall = wall([session(crew: [crewman("a"), crewman("b")])], aspect: portrait)
        #expect(tall.tiles.first?.squad?.parent.width == 1)
    }
}

@Suite struct WallWorkerDemoTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scene(_ name: String) -> AgentWall {
        AgentDemo.wallScenes(now: now).first { $0.name == name }!.wall
    }

    @Test func theSquadSceneHasEveryWorkerState() throws {
        let squad = scene("squad")
        let fixing = try #require(squad.tiles.first { $0.title == "Fix reconnect test" })
        #expect(
            fixing.workers.map(\.state) == [
                .background(stuck: true), .quiet(since: now.addingTimeInterval(-200)), .working,
                .finished, .working,
            ])
        let finished = try #require(fixing.workers.first { $0.state.isFinished })
        #expect(finished.title == "Lint sweep" && finished.fade > 0.3 && finished.fade < 0.5)
        #expect(fixing.squad?.slots.count == 5 && fixing.squad?.hidden == 0)
        #expect(squad.subagents == 5)
    }

    @Test func theCrowdedSceneSpillsOneSessionsCrewIntoACount() throws {
        let crowded = scene("crowded")
        let busy = try #require(crowded.tiles.first { $0.title == "Fix reconnect test" })
        #expect(busy.workers.count == 5)
        #expect(busy.squad?.slots.count == 2 && busy.squad?.hidden == 3)
        #expect(busy.workers.first?.title == "Test runner")
    }
}

@Suite struct WallReflowTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aSceneFitsAnotherScreenWithItsTilesAndTheirSquadsRecut() throws {
        let squad = try #require(AgentDemo.wallScenes(now: now).first { $0.name == "squad" }?.wall)
        let tall = squad.reflowed(aspect: portrait)
        #expect(tall.tiles.map(\.id) == squad.tiles.map(\.id))
        #expect(tall.columns == 1 && tall.rows == 2)
        #expect(tall.tiles.allSatisfy { $0.squad?.parent.width == 1 })
        #expect(tall.reflowed(aspect: landscape) == squad)
    }

    @Test func theAreasShapeNotTheScreensShapeCutsTheCell() throws {
        let squad = try #require(AgentDemo.wallScenes(now: now).first { $0.name == "squad" }?.wall)
        let stretched = squad.reflowed(aspect: landscape, gridAspect: 4)
        #expect(stretched.tiles.first?.squad?.parent.height == 1)
        let boxy = squad.reflowed(aspect: landscape, gridAspect: 0.5)
        #expect(boxy.tiles.first?.squad?.parent.width == 1)
    }
}
