import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let landscape = 16.0 / 9.0
private let portrait = 9.0 / 16.0
private let squarish = 1.0

private func said(_ text: String) -> ChatMessage {
    ChatMessage(
        id: "u-" + text, role: .user, agentType: .claudeCode,
        parts: [MessagePart(id: "p", kind: .text(text))], createdAt: epoch.addingTimeInterval(-300))
}

private func worked(_ calls: [ToolCall]) -> ChatMessage {
    ChatMessage(
        id: "a-" + (calls.first?.id ?? "none"), role: .assistant, agentType: .claudeCode,
        parts: calls.map { MessagePart(id: "p-" + $0.id, kind: .tool($0)) },
        createdAt: epoch.addingTimeInterval(-200), isStreaming: true)
}

private func editing(_ id: String = "e") -> ToolCall {
    ToolCall(
        id: id, name: "Edit", status: .running,
        input: .object([
            "file_path": .string("/r/Backoff.swift"), "old_string": .string("a"),
            "new_string": .string("b\nc"),
        ]))
}

private func entry(
    _ id: String, profile: String = "p1", machine: String = "studio", active: Bool = false,
    work: BackgroundWork? = nil, task: String? = nil, updated: TimeInterval = 0
) -> SessionEntry {
    var session = AgentSession(
        id: id, agentType: .claudeCode, title: "Chat \(id)", createdAt: epoch,
        updatedAt: epoch.addingTimeInterval(-updated), isActive: active)
    session.backgroundWork = work
    session.agentTask = task
    return SessionEntry(
        profileID: profile, profileName: machine, host: machine, backendType: .claudeCode,
        session: session)
}

private func facts(
    _ state: ConversationState, beating: Bool = true, seen: [String: Date] = [:],
    at now: Date = epoch
) -> AgentFacts {
    let stamps = beating ? (0..<40).map { now.addingTimeInterval(-Double($0) * 1.4) } : []
    return AgentFacts.read(state: state, agents: [], seen: seen, stamps: stamps, now: now)
}

private func running(_ calls: [ToolCall] = [editing()], status: BackendStatus = .running) -> ConversationState {
    ConversationState(
        messages: calls.isEmpty ? [said("go")] : [said("go"), worked(calls)], status: status,
        hasLoadedTranscript: true)
}

private func working(
    _ id: String, beating: Bool = true, away: Bool = false, calls: [ToolCall] = [editing()],
    machine: String = "studio", at now: Date = epoch
) -> AgentSource {
    AgentSource(
        entry: entry(id, machine: machine, active: true, updated: 240),
        facts: facts(running(calls), beating: beating, at: now), reachable: away ? false : true,
        unread: false)
}

private func asking(
    _ id: String, waited: TimeInterval, command: String = "rm -rf build\nswift build"
) -> AgentSource {
    let bash = ToolCall(id: "b", name: "Bash", status: .pending, input: .object(["command": .string(command)]))
    let request = PermissionRequest(id: "perm-" + id, sessionID: id, title: "Bash", toolName: "Bash")
    let state = ConversationState(
        messages: [said("go"), worked([bash])], status: .running, pendingPermissions: [request],
        hasLoadedTranscript: true)
    return AgentSource(
        entry: entry(id, active: true),
        facts: facts(state, seen: [request.id: epoch.addingTimeInterval(-waited)]), reachable: true,
        unread: false)
}

private func background(_ id: String, stalled: Bool = false) -> AgentSource {
    let work = BackgroundWork(
        tasks: 1, task: "swift test", since: epoch.addingTimeInterval(-1320), stalled: stalled)
    let state = ConversationState(messages: [said("go")], status: .idle, hasLoadedTranscript: true, backgroundWork: work)
    return AgentSource(entry: entry(id), facts: facts(state), reachable: true, unread: false)
}

private func finish(
    _ id: String, _ outcome: AgentFinish.Outcome, ago: TimeInterval, reason: String? = nil
) -> AgentFinish {
    AgentFinish(
        id: "p1/" + id, profileID: "p1", sessionID: id, title: "Chat \(id)", machine: "studio",
        outcome: outcome,
        line: AgentFinish.line(outcome: outcome, duration: 372, tools: 14, files: 3, failure: reason),
        endedAt: epoch.addingTimeInterval(-ago), unread: true, reason: reason)
}

private func wall(
    _ sources: [AgentSource], finished: [AgentFinish] = [], hour: AgentHour? = nil,
    now: Date = epoch, aspect: Double = landscape, previous: AgentWall? = nil
) -> AgentWall {
    let board = AgentBoard.read(sources: sources, finished: finished, now: now)
    return AgentWall.read(board: board, hour: hour, now: now, aspect: aspect, previous: previous)
}

private func tile(_ wall: AgentWall, _ id: String) -> WallTile? {
    wall.tiles.first { $0.id == "p1/" + id }
}

@Suite struct AgentWallStateTests {
    @Test func aRunningTurnWithEventsIsWorkingWithItsWordsAndTheFileItIsAbout() {
        let read = wall([working("w")])
        let one = tile(read, "w")
        #expect(one?.state == .working)
        #expect(one?.words == "Changing Backoff.swift")
        #expect(one?.detail == nil && one?.rewritable == nil)
        #expect(one?.steps.count == 1)
        #expect(one?.beat?.last ?? 0 > 0)
        #expect(one?.fade == 0)
    }

    @Test func aTurnWithNoToolOutIsThinking() {
        let thinking = AgentSource(
            entry: entry("t", active: true), facts: facts(running([])), reachable: true, unread: false)
        let one = tile(wall([thinking]), "t")
        #expect(one?.state == .thinking)
        #expect(one?.words == "Thinking")
        #expect(one?.detail == nil)
        #expect(one?.statusWord(at: epoch) == "Thinking")
    }

    @Test func anApprovalCarriesTheWholeCommandAndTheWaitingVerb() {
        let one = tile(wall([asking("n", waited: 90)]), "n")
        #expect(one?.state == .needsYou(.waiting))
        #expect(one?.words == "Wants to run")
        #expect(one?.detail == "rm -rf build\nswift build")
        #expect(one?.ask?.isApproval == true)
        #expect(one?.stateSince == epoch.addingTimeInterval(-90))
        #expect(one?.statusWord(at: epoch) == "waiting 1m")
    }

    @Test func aQuestionCarriesItsWordsAndOptions() {
        let question = QuestionRequest(
            id: "q", sessionID: "s",
            questions: [
                QuestionRequest.Item(
                    question: "Which branch?", header: "Branch",
                    options: [
                        QuestionRequest.Option(label: "main", description: ""),
                        QuestionRequest.Option(label: "dev", description: ""),
                    ])
            ])
        let state = ConversationState(
            messages: [said("go"), worked([editing()])], status: .running, pendingQuestions: [question],
            hasLoadedTranscript: true)
        let source = AgentSource(
            entry: entry("q", active: true), facts: facts(state, seen: ["q": epoch]), reachable: true,
            unread: false)
        let one = tile(wall([source]), "q")
        #expect(one?.state == .needsYou(.fresh))
        #expect(one?.words == "Has a question")
        #expect(one?.detail == "Which branch?")
        #expect(one?.ask?.options == ["main", "dev"])
    }

    @Test func aProviderWaitIsRetryingWithItsAttempt() {
        let state = ConversationState(
            messages: [said("go"), worked([editing()])], status: .running, hasLoadedTranscript: true,
            retry: TurnRetry(attempt: 2, reason: "rate limited"))
        let source = AgentSource(entry: entry("r", active: true), facts: facts(state), reachable: true, unread: false)
        let one = tile(wall([source]), "r")
        #expect(one?.state == .retrying(attempt: 2))
        #expect(one?.words == "The AI service is busy, trying again")
        #expect(one?.statusWord(at: epoch) == "Waiting on the provider · try 2")
    }

    @Test func backgroundWorkIsBackgroundAndStuckWhenTheServerSaysSo() {
        let calm = tile(wall([background("b")]), "b")
        #expect(calm?.state == .background(stuck: false))
        #expect(calm?.words == "Running the tests")
        #expect(calm?.statusWord(at: epoch) == "in the background · 22m")
        let stuck = tile(wall([background("b", stalled: true)]), "b")
        #expect(stuck?.state == .background(stuck: true))
        #expect(stuck?.statusWord(at: epoch) == "stuck")
    }

    @Test func aMachineThatStoppedAnsweringIsAwayNotFailed() {
        let read = wall([working("a", away: true, machine: "attic")])
        let one = tile(read, "a")
        #expect(one?.state == .away(lastSeen: epoch.addingTimeInterval(-240)))
        #expect(one?.words == "attic not answering")
        #expect(one?.statusWord(at: epoch) == "last seen 4m ago")
        #expect(read.mood == .calm)
    }

    @Test func anAwayMachineKeepsItsFirstLastSeenAcrossReads() {
        let first = wall([working("a")], now: epoch)
        let down = wall([working("a", away: true)], now: epoch.addingTimeInterval(10), previous: first)
        #expect(tile(down, "a")?.state == .away(lastSeen: epoch))
        let later = wall([working("a", away: true)], now: epoch.addingTimeInterval(90), previous: down)
        #expect(tile(later, "a")?.state == .away(lastSeen: epoch))
    }

    @Test func endingsCarryTheirLineOrTheirReason() {
        let read = wall(
            [],
            finished: [
                finish("d", .done, ago: 10), finish("s", .stopped, ago: 10),
                finish("f", .failed, ago: 10, reason: "build exited 1"),
            ])
        #expect(tile(read, "d")?.state == .finished(.done))
        #expect(tile(read, "d")?.words == "Done in 6m · 14 tools · edited 3 files")
        #expect(tile(read, "d")?.detail == nil)
        #expect(tile(read, "s")?.words == "Stopped")
        #expect(tile(read, "f")?.words == "build exited 1")
        #expect(tile(read, "f")?.detail == "build exited 1")
        #expect(tile(read, "f")?.statusWord(at: epoch) == "Failed")
    }
}

@Suite struct AgentWallRowTests {
    @Test func aWatchedRowCarriesItsLastThreeStepsItsObjectAndItsContextShare() {
        let calls = (1...5).map {
            ToolCall(
                id: "c\($0)", name: "Read", status: .completed,
                input: .object(["file_path": .string("/r/F\($0).swift")]))
        } + [editing("e")]
        var state = running(calls)
        state.messages[1].context = MessageUsage(cacheRead: 100_000)
        state.messages[1].modelID = "claude-opus-5"
        let source = AgentSource(entry: entry("w", active: true), facts: facts(state), reachable: true, unread: false)
        let board = AgentBoard.read(sources: [source], now: epoch)
        let row = board.working.first
        #expect(row?.steps.map(\.words) == ["Editing Backoff.swift", "Read F5.swift", "Read F4.swift"])
        #expect(row?.object == AgentObject(kind: .path, text: "/r/Backoff.swift", added: 2, removed: 1))
        #expect(row?.contextShare == 0.5)
        #expect(row?.activity == .usingTool(name: "Edit", kind: .fileEdit))
        #expect(row?.retryAttempt == nil && row?.isStuck == false)
        #expect(tile(wall([source]), "w")?.contextShare == 0.5)
    }

    @Test func aStuckBackgroundRowAndAnAskCarryTheirFacts() {
        let board = AgentBoard.read(sources: [background("b", stalled: true), asking("n", waited: 5)], now: epoch)
        #expect(board.background.first?.isStuck == true)
        #expect(board.needsYou.first?.startedAt != nil)
        #expect(board.needsYou.first?.beat != nil)
        #expect(board.needsYou.first?.steps.count == 1)
    }
}

@Suite struct AgentWallUrgencyTests {
    @Test(arguments: [(0.0, WallUrgency.fresh), (59, .fresh), (60, .waiting), (299, .waiting), (300, .overdue), (4000, .overdue)])
    func theLevelIsMeasuredFromTheAsksSince(waited: Double, level: WallUrgency) {
        let one = tile(wall([asking("n", waited: waited)]), "n")
        #expect(one?.state == .needsYou(level))
    }

    @Test func anAskNobodySawStartIsFresh() {
        let bash = ToolCall(id: "b", name: "Bash", status: .pending, input: .object(["command": .string("ls")]))
        let request = PermissionRequest(id: "p", sessionID: "n", title: "Bash", toolName: "Bash")
        let state = ConversationState(
            messages: [said("go"), worked([bash])], status: .running, pendingPermissions: [request],
            hasLoadedTranscript: true)
        let source = AgentSource(entry: entry("n", active: true), facts: facts(state), reachable: true, unread: false)
        #expect(tile(wall([source]), "n")?.state == .needsYou(.fresh))
    }
}

@Suite struct AgentWallMoodTests {
    @Test func theMoodTable() {
        #expect(wall([]).mood == .calm)
        #expect(wall([working("w")]).mood == .busy)
        #expect(wall([background("b")]).mood == .busy)
        #expect(wall([asking("n", waited: 30), working("w")]).mood == .attention)
        #expect(wall([asking("n", waited: 299)]).mood == .attention)
        #expect(wall([asking("n", waited: 300), working("w")]).mood == .alarm)
        #expect(wall([], finished: [finish("f", .failed, ago: 60, reason: "x")]).mood == .alarm)
        #expect(wall([], finished: [finish("f", .failed, ago: 899, reason: "x")]).mood == .alarm)
        #expect(wall([], finished: [finish("f", .failed, ago: 900, reason: "x")]).mood == .calm)
        #expect(wall([], finished: [finish("d", .done, ago: 20)]).mood == .calm)
        #expect(wall([working("w")], finished: [finish("f", .failed, ago: 10, reason: "x")]).mood == .alarm)
    }

    @Test func theHeadlineIsTheBoardsSentenceOrAllQuiet() {
        #expect(wall([]).headline == "All quiet")
        #expect(wall([working("w"), asking("n", waited: 5)]).headline == "1 working · 1 needs you")
        #expect(wall([], finished: [finish("f", .failed, ago: 5, reason: "x")]).headline == "1 failed")
        #expect(wall([working("w")]).watchLine == "Watching the one running · studio")
    }
}

@Suite struct AgentWallQuietTests {
    @Test func aFlatBeatForFortyFiveSecondsIsQuietSinceFortyFiveSecondsAgo() {
        let read = wall([working("q", beating: false)])
        #expect(tile(read, "q")?.state == .quiet(since: epoch.addingTimeInterval(-45)))
        #expect(tile(read, "q")?.statusWord(at: epoch) == "quiet for 45s")
    }

    @Test func aPulseFortySecondsAgoIsStillWorkingAndOneFiftySecondsAgoIsQuiet() {
        func source(pulse: TimeInterval) -> AgentSource {
            AgentSource(
                entry: entry("q", active: true),
                facts: AgentFacts.read(
                    state: running(), agents: [], stamps: [epoch.addingTimeInterval(-pulse)], now: epoch),
                reachable: true, unread: false)
        }
        #expect(tile(wall([source(pulse: 40)]), "q")?.state == .working)
        #expect(tile(wall([source(pulse: 50)]), "q")?.state == .quiet(since: epoch.addingTimeInterval(-45)))
    }

    @Test func theSinceDateSurvivesReadsAndAnEventEndsIt() {
        let first = wall([working("q", beating: false)], now: epoch)
        let later = epoch.addingTimeInterval(135)
        let second = wall([working("q", beating: false, at: later)], now: later, previous: first)
        #expect(tile(second, "q")?.state == .quiet(since: epoch.addingTimeInterval(-45)))
        #expect(tile(second, "q")?.statusWord(at: later) == "quiet for 3m")
        let moving = wall([working("q", at: later)], now: later, previous: second)
        #expect(tile(moving, "q")?.state == .working)
        let again = wall([working("q", beating: false, at: later)], now: later, previous: moving)
        #expect(tile(again, "q")?.state == .quiet(since: later.addingTimeInterval(-45)))
    }

    @Test func aListedRowWithNoHeartbeatIsNeverCalledQuiet() {
        let listed = AgentSource(entry: entry("l", active: true, task: "searching"), facts: nil, reachable: true, unread: false)
        let read = wall([listed])
        #expect(read.tiles.isEmpty)
        #expect(read.listed.map(\.id) == ["p1/l"])
        #expect(read.listed.first?.words == "searching")
    }
}

@Suite struct AgentWallOrderTests {
    private func ids(_ wall: AgentWall) -> [String] { wall.tiles.map(\.id) }

    @Test func urgencyDecidesTheFirstOrder() {
        let read = wall(
            [
                background("bg"), working("w"), working("q", beating: false), asking("n", waited: 400),
            ], finished: [finish("f", .failed, ago: 5, reason: "x"), finish("d", .done, ago: 5)])
        #expect(ids(read) == ["p1/n", "p1/f", "p1/q", "p1/w", "p1/bg", "p1/d"])
    }

    @Test func theLongestWaitLeadsAmongTheAsks() {
        let read = wall([asking("young", waited: 10), asking("old", waited: 200)])
        #expect(ids(read) == ["p1/old", "p1/young"])
    }

    @Test func aSlotIsKeptWhateverTheStateDoes() {
        let first = wall([working("a"), working("b"), working("c")])
        let before = ids(first)
        let shuffled = wall([working("c"), working("a"), working("b")], previous: first)
        #expect(ids(shuffled) == before)
        let again = wall([working("c"), working("b"), working("a"), working("d")], previous: first)
        #expect(ids(again) == before + ["p1/d"])
    }

    @Test func aTilesStateNeverMovesIt() {
        let first = wall([working("a"), working("b"), working("c")])
        let order = ids(first)
        let stalled = wall(
            [
                working("a"), working("b"), working("c", beating: false),
            ], previous: first)
        #expect(ids(stalled) == order)
        #expect(stalled.tiles.first { $0.id == "p1/c" }?.state.rank == 3)
        let asked = wall([asking("n", waited: 5), working("a"), working("b"), working("c")], previous: first)
        #expect(ids(asked) == order + ["p1/n"])
    }

    @Test func anAskThatTakesTheSlotOfAWorkingSessionStaysWhereItWas() {
        let first = wall([working("a"), working("b")])
        let asked = wall([asking("a", waited: 5), working("b")], previous: first)
        #expect(ids(asked) == ids(first))
        #expect(asked.tiles.first?.state.isNeedsYou == true)
    }

    @Test func pastTheCapAnAskIsNeverTheOneLeftOut() {
        let sixWorking = (0..<6).map { working("w\($0)") }
        let first = wall(sixWorking)
        let crowded = wall(sixWorking + [asking("n", waited: 5)], previous: first)
        #expect(crowded.tiles.count == 6 && ids(crowded).contains("p1/n"))
        #expect(!ids(crowded).contains("p1/w5"))
        #expect(crowded.listed.map(\.id).contains("p1/w5"))
        #expect(Array(ids(crowded).prefix(5)) == Array(ids(first).prefix(5)))
    }

    @Test func aCooledEndingGivesWayBeforeARunningSession() {
        let sixWorking = (0..<5).map { working("w\($0)") }
        let first = wall(sixWorking, finished: [finish("d", .done, ago: 5)])
        let more = wall(sixWorking + [working("late")], finished: [finish("d", .done, ago: 6)], previous: first)
        #expect(more.tiles.count == 6 && ids(more).contains("p1/late") && !ids(more).contains("p1/d"))
    }

    @Test func aDeepeningWaitDoesNotMoveATile() {
        let first = wall([asking("x", waited: 20), asking("y", waited: 10)])
        let later = wall(
            [asking("y", waited: 400), asking("x", waited: 20)], previous: first)
        #expect(ids(later) == ids(first))
    }

    @Test func anEndedTileCoolsWhereItStood() {
        let first = wall([working("a"), working("b")], finished: [])
        let ended = wall([working("b")], finished: [finish("a", .done, ago: 5)], previous: first)
        #expect(ids(ended) == ["p1/a", "p1/b"])
    }
}

@Suite struct AgentWallGridTests {
    private func sources(_ count: Int, asks: Bool = false) -> [AgentSource] {
        var all: [AgentSource] = []
        if asks { all.append(asking("n", waited: 30)) }
        let rest = asks ? count - 1 : count
        for index in 0..<max(0, rest) { all.append(working("w\(index)")) }
        return all
    }

    private func shape(_ count: Int, _ aspect: Double, asks: Bool = false) -> (Int, Int) {
        let read = wall(sources(count, asks: asks), aspect: aspect)
        return (read.columns, read.rows)
    }

    @Test func theShapeFollowsTheCountAndTheScreen() {
        #expect(shape(0, landscape) == (0, 0))
        #expect(shape(1, landscape) == (1, 1))
        #expect(shape(1, portrait) == (1, 1))
        #expect(shape(2, landscape) == (2, 1))
        #expect(shape(2, portrait) == (1, 2))
        #expect(shape(3, landscape) == (3, 1))
        #expect(shape(3, portrait) == (1, 3))
        #expect(shape(3, squarish) == (2, 2))
        #expect(shape(4, landscape) == (2, 2))
        #expect(shape(4, portrait) == (2, 2))
        #expect(shape(5, landscape) == (3, 2))
        #expect(shape(6, landscape) == (3, 2))
        #expect(shape(5, portrait) == (2, 3))
        #expect(shape(6, portrait) == (2, 3))
    }

    @Test func theAspectBoundsAreInclusive() {
        #expect(shape(3, 1.2) == (3, 1))
        #expect(shape(3, 1.19) == (2, 2))
        #expect(shape(3, 0.9) == (1, 3))
        #expect(shape(3, 0.91) == (2, 2))
    }

    @Test func everyShapePacksWithNoHolesAndNoOverlap() {
        for aspect in [landscape, portrait, squarish] {
            for count in 0...6 {
                for asks in [false, true] where !(asks && count == 0) {
                    let read = wall(sources(count, asks: asks), aspect: aspect)
                    #expect(read.tiles.count == count)
                    var taken = Set<[Int]>()
                    for tile in read.tiles {
                        #expect(tile.span == 1 || tile.span == 2)
                        #expect(tile.column >= 0 && tile.column + tile.span <= read.columns)
                        for offset in 0..<tile.span {
                            #expect(taken.insert([tile.row, tile.column + offset]).inserted)
                        }
                    }
                    #expect(taken.count == read.columns * read.rows)
                }
            }
        }
    }

    @Test func anAskTakesNoMoreRoomThanAnyOtherTile() {
        for aspect in [landscape, portrait, squarish] {
            for count in 2...6 {
                let read = wall(sources(count, asks: true), aspect: aspect)
                #expect(read.tiles.first?.state.isNeedsYou == true)
                #expect(read.tiles.first?.span == 1)
            }
        }
        #expect(shape(6, portrait, asks: true) == (2, 3))
        #expect(shape(4, landscape, asks: true) == shape(4, landscape))
    }

    @Test func aTilesCellsAreWhereTheGridFlowsThem() {
        let read = wall(sources(5, asks: true))
        #expect(read.columns == 3 && read.rows == 2)
        #expect(read.tiles.map(\.column) == [0, 1, 2, 0, 2])
        #expect(read.tiles.map(\.row) == [0, 0, 0, 1, 1])
        #expect(read.tiles.map(\.span) == [1, 1, 1, 2, 1])
        let four = wall(sources(4, asks: true))
        #expect(four.columns == 2 && four.rows == 2)
        #expect(four.tiles.map(\.span) == [1, 1, 1, 1])
    }

    @Test func pagesPutTwoColumnsFillRowMajorAndNeverSpan() {
        let expected: [Int: (columns: Int, rows: Int)] = [
            1: (1, 1), 2: (2, 1), 3: (2, 2), 4: (2, 2), 5: (2, 3), 6: (2, 3),
        ]
        for aspect in [landscape, portrait, squarish] {
            for count in 1...6 {
                let board = AgentBoard.read(sources: sources(count), finished: [], now: epoch)
                let read = AgentWall.read(
                    board: board, hour: nil, now: epoch, aspect: aspect, pages: true, previous: nil)
                #expect(read.columns == expected[count]?.columns)
                #expect(read.rows == expected[count]?.rows)
                #expect(read.tiles.allSatisfy { $0.span == 1 })
                let columns = read.columns
                #expect(read.tiles.map(\.column) == (0..<count).map { $0 % columns })
                #expect(read.tiles.map(\.row) == (0..<count).map { $0 / columns })
            }
        }
    }

    @Test func pagesLeaveAnOddLastCellEmptyAndSurviveAReflow() {
        let five = wall(sources(5), aspect: landscape)
        let paged = five.reflowed(aspect: portrait, pages: true)
        #expect(paged.columns == 2 && paged.rows == 3)
        #expect(paged.tiles.last?.column == 0 && paged.tiles.last?.row == 2 && paged.tiles.last?.span == 1)
        let flat = paged.reflowed(aspect: landscape)
        #expect(flat.columns == 3 && flat.rows == 2)
    }

    @Test func noMoreThanSixTilesAndTheRestAreListed() {
        let read = wall(sources(9))
        #expect(read.tiles.count == 6)
        #expect(read.listed.count == 3)
        #expect(read.listedOverflow == 0)
        #expect(read.running == 9)
    }
}

@Suite struct AgentWallLifetimeTests {
    @Test func aDoneTileCoolsForAMinuteThenLeavesForRecent() {
        let at30 = wall([], finished: [finish("d", .done, ago: 30)])
        #expect(tile(at30, "d")?.fade == 0.5)
        #expect(at30.recent.isEmpty)
        let at59 = wall([], finished: [finish("d", .done, ago: 59)])
        #expect(tile(at59, "d") != nil)
        let at60 = wall([], finished: [finish("d", .done, ago: 60)])
        #expect(at60.tiles.isEmpty)
        #expect(at60.recent.map(\.id) == ["p1/d"])
        #expect(at60.recent.first?.outcome == .done)
        #expect(at60.recent.first?.at == epoch.addingTimeInterval(-60))
    }

    @Test func aStoppedTileFollowsTheSameMinute() {
        #expect(tile(wall([], finished: [finish("s", .stopped, ago: 59)]), "s") != nil)
        #expect(wall([], finished: [finish("s", .stopped, ago: 60)]).tiles.isEmpty)
    }

    @Test func aFailedTileStaysFifteenMinutesAtFullStrength() {
        let early = wall([], finished: [finish("f", .failed, ago: 600, reason: "x")])
        #expect(tile(early, "f")?.fade == 0)
        #expect(tile(wall([], finished: [finish("f", .failed, ago: 899, reason: "x")]), "f") != nil)
        let gone = wall([], finished: [finish("f", .failed, ago: 900, reason: "x")])
        #expect(gone.tiles.isEmpty)
        #expect(gone.recent.first?.outcome == .failed)
    }

    @Test func anEndingWhoseHowIsUnknownIsOnlyEverAChip() {
        let unknown = AgentFinish(
            id: "p1/u", profileID: "p1", sessionID: "u", title: "Chat u", machine: "studio",
            outcome: .unknown, line: "Finished", endedAt: epoch.addingTimeInterval(-5), unread: true)
        let read = wall([], finished: [unknown])
        #expect(read.tiles.isEmpty)
        #expect(read.recent.first?.outcome == .unknown)
    }

    @Test func recentHoldsTheLastFiveNewestFirstAndNotWhatATileShows() {
        let all = (0..<8).map { finish("e\($0)", .done, ago: 120 + Double($0) * 60) }
        let read = wall([], finished: all + [finish("now", .done, ago: 5)])
        #expect(read.recent.map(\.id) == (0..<5).map { "p1/e\($0)" })
        #expect(read.tiles.map(\.id) == ["p1/now"])
    }

    @Test func aSessionThatWorksAgainIsNotAlsoAFinishedTile() {
        let read = wall([working("w")], finished: [finish("w", .done, ago: 10)])
        #expect(read.tiles.map(\.id) == ["p1/w"])
    }
}

@Suite struct AgentWallRailTests {
    @Test func moreThanSixListedSessionsBecomeSixChipsAndACount() {
        var sources = (0..<6).map { working("w\($0)") }
        for index in 0..<9 {
            sources.append(
                AgentSource(
                    entry: entry("l\(index)", active: true, task: "task \(index)"), facts: nil,
                    reachable: true, unread: false))
        }
        let read = wall(sources)
        #expect(read.tiles.count == 6)
        #expect(read.listed.count == 6)
        #expect(read.listedOverflow == 3)
        #expect(read.watched == 6 && read.running == 15)
    }

    @Test func aWatchedSessionPastTheCapIsListedNotLost() {
        let read = wall((0..<7).map { working("w\($0)") })
        #expect(read.tiles.count == 6)
        #expect(read.listed.count == 1)
        #expect(Set(read.tiles.map(\.id) + read.listed.map(\.id)).count == 7)
    }

    @Test func theCalmLineCountsTheHourFromTheLedgerAndItsMarks() {
        var log = AgentHourLog()
        log.beginObserving(at: epoch.addingTimeInterval(-3000))
        func end(_ id: String, _ outcome: AgentFinish.Outcome, ago: TimeInterval) {
            log.note(id: "p1/" + id, profileID: "p1", sessionID: id, title: id, machine: "studio", phase: .working, at: epoch.addingTimeInterval(-ago - 100))
            log.end(id: "p1/" + id, outcome: outcome, at: epoch.addingTimeInterval(-ago))
        }
        end("a", .done, ago: 2000)
        end("b", .done, ago: 1500)
        end("c", .failed, ago: 1000)
        end("d", .stopped, ago: 500)
        end("old", .done, ago: 5000)
        let ledger = [finish("c", .failed, ago: 1000, reason: "x"), finish("d", .stopped, ago: 500), finish("e", .done, ago: 200)]
        let read = wall([], finished: ledger, hour: log.hour(now: epoch))
        #expect(read.calm == WallCalm(done: 3, failed: 1, stopped: 1, line: "3 done · 1 failed · 1 stopped in the last hour"))
        #expect(read.recent.map(\.id) == ["p1/e", "p1/d", "p1/c"])
    }

    @Test func aQuietHourSaysSoAndARunningBoardHasNoCalmLine() {
        #expect(wall([]).calm?.line == "Nothing ended in the last hour")
        #expect(wall([working("w")]).calm == nil)
        #expect(wall([], finished: [finish("d", .done, ago: 10)]).calm?.done == 1)
    }
}

@Suite struct AgentWallPurityTests {
    @Test func theSameInputGivesTheSameWall() {
        let sources = [asking("n", waited: 90), working("w"), working("q", beating: false), background("b")]
        let finished = [finish("f", .failed, ago: 40, reason: "boom"), finish("d", .done, ago: 20)]
        let one = wall(sources, finished: finished)
        let two = wall(sources, finished: finished)
        #expect(one == two)
        let again = wall(sources, finished: finished, previous: one)
        #expect(again == wall(sources, finished: finished, previous: one))
        #expect(again.tiles.map(\.id) == one.tiles.map(\.id))
    }

    @Test func theEmptyWallIsCalmAndHasNothingToDraw() {
        let empty = AgentWall.empty
        #expect(empty.isCalm && empty.tiles.isEmpty && empty.columns == 0 && empty.rows == 0)
    }
}

@Suite struct AgentWallDemoTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scene(_ name: String) -> AgentWall {
        AgentDemo.wallScenes(now: now).first { $0.name == name }!.wall
    }

    @Test func everySceneBuildsAndIsNamedOnce() {
        let scenes = AgentDemo.wallScenes(now: now)
        #expect(scenes.map(\.name) == ["calm", "busy", "attention", "alarm", "finishing", "crowded", "squad"])
        for (_, wall) in scenes {
            #expect(wall.tiles.count <= 6)
            #expect(wall.tiles.reduce(0) { $0 + $1.span } == wall.columns * wall.rows)
        }
        #expect(AgentDemo.wall(now: now) == scene("alarm"))
    }

    @Test func calmIsAnEmptyWallWithAnHoursSummary() {
        let calm = scene("calm")
        #expect(calm.mood == .calm && calm.tiles.isEmpty)
        #expect(calm.headline == "All quiet")
        #expect(calm.calm?.line == "6 done · 1 failed · 2 stopped in the last hour")
        #expect(calm.recent.count == 5)
    }

    @Test func busyHasThreeWorkingOneThinkingSubAgentsAndABackgroundRow() {
        let busy = scene("busy")
        #expect(busy.mood == .busy)
        let states = busy.tiles.map(\.state)
        #expect(states.filter { $0 == .working }.count == 2)
        #expect(states.contains(.thinking))
        #expect(states.contains(.background(stuck: false)))
        #expect(busy.tiles.contains { $0.children.contains { $0.kind == .agent } })
        #expect(busy.tiles.contains { !$0.steps.isEmpty && $0.contextShare != nil })
    }

    @Test func attentionLeadsWithAFreshAskOverWork() {
        let attention = scene("attention")
        #expect(attention.mood == .attention)
        #expect(attention.tiles.first?.state == .needsYou(.fresh))
        #expect(attention.tiles.first?.detail == "rm -rf build && swift build -c release")
        #expect(attention.tiles.count == 2)
    }

    @Test func alarmIsSixTilesEachInADifferentState() {
        let alarm = scene("alarm")
        #expect(alarm.mood == .alarm)
        #expect(alarm.tiles.count == 6)
        let tiles = alarm.tiles.sorted { $0.state.rank < $1.state.rank }
        let states = tiles.map(\.state)
        #expect(states[0] == .needsYou(.overdue))
        #expect(states[1] == .finished(.failed))
        #expect(states[2] == .retrying(attempt: 2))
        #expect(states[3] == .quiet(since: now.addingTimeInterval(-180)))
        #expect(states[4] == .away(lastSeen: now.addingTimeInterval(-240)))
        #expect(states[5] == .background(stuck: true))
        #expect(tiles[3].contextShare == 0.88)
        #expect(tiles[1].words == "swift build exited with status 1")
        #expect(tiles[0].statusWord(at: now) == "waiting 7m")
        #expect(alarm.headline == "3 working · 1 needs you")
    }

    @Test func finishingHasACoolingDoneTileAStoppedOneAndRecents() {
        let finishing = scene("finishing")
        #expect(finishing.mood == .calm)
        #expect(finishing.tiles.map(\.state) == [.finished(.done), .finished(.stopped)])
        #expect(finishing.tiles.allSatisfy { $0.fade > 0 && $0.fade < 1 })
        #expect(finishing.recent.count == 3)
        #expect(finishing.calm != nil)
    }

    @Test func crowdedWatchesSixAndListsFour() {
        let crowded = scene("crowded")
        #expect(crowded.tiles.count == 6 && crowded.listed.count == 4 && crowded.listedOverflow == 0)
        #expect(crowded.watched == 6 && crowded.running == 10)
        #expect(crowded.columns == 3 && crowded.rows == 2)
        #expect(crowded.mood == .busy)
    }

    @Test func theScenesAreTheSameAtAnyMoment() {
        #expect(AgentDemo.wallScenes(now: now).map(\.wall) == AgentDemo.wallScenes(now: now).map(\.wall))
    }
}
