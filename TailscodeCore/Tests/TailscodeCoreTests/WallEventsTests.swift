import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func step(_ id: String, _ words: String = "Changed Backoff.swift") -> AgentStep {
    AgentStep(id: id, words: words, outcome: .done)
}

private func worker(_ id: String, _ state: WorkerState = .working) -> WallWorker {
    WallWorker(
        id: id, kind: .agent, title: "Plan", words: "Searching the code", state: state,
        startedAt: epoch, stateSince: epoch, todosDone: 0, todosTotal: 0, toolCount: nil, fade: 0)
}

private func tile(
    _ id: String, _ state: WallState = .working, words: String = "Changing Backoff.swift",
    steps: [AgentStep] = [], beat: [Int]? = nil, context: Double? = nil, workers: [WallWorker] = []
) -> WallTile {
    var made = WallTile(
        id: id, profileID: "p1", sessionID: id, title: "Chat " + id, machine: "studio", chip: nil,
        state: state, words: words, detail: nil, startedAt: epoch, stateSince: epoch, ask: nil,
        beat: beat, contextShare: context, children: [], steps: steps, fade: 0, unread: false)
    made.workers = workers
    return made
}

private func wall(_ tiles: WallTile...) -> AgentWall {
    AgentWall(
        mood: .busy, headline: "", watchLine: "", tiles: tiles, columns: 1, rows: 1, listed: [],
        listedOverflow: 0, recent: [], calm: nil, watched: tiles.count, running: tiles.count,
        subagents: 0, at: epoch)
}

private func kinds(_ before: AgentWall?, _ after: AgentWall) -> [WallEvent.Kind] {
    WallEvents.between(before, after).map(\.kind)
}

private func change(_ from: WallState, to: WallState) -> [WallEvent.Kind] {
    kinds(wall(tile("a", from)), wall(tile("a", to)))
}

@Suite struct WallEventsTests {
    @Test func aFirstReadSaysNothing() {
        #expect(WallEvents.between(nil, wall(tile("a"), tile("b"))).isEmpty)
        #expect(WallEvents.between(wall(tile("a")), wall(tile("a"))).isEmpty)
    }

    @Test func aNewIdJoinsAndAGoneIdLeavesInOrder() {
        let before = wall(tile("a"), tile("b"))
        let after = wall(tile("a"), tile("c"))
        let events = WallEvents.between(before, after)
        #expect(events == [WallEvent(kind: .joined, tile: "c"), WallEvent(kind: .left, tile: "b")])
    }

    @Test func askedWhenAnythingBecomesNeedsYou() {
        #expect(change(.working, to: .needsYou(.fresh)) == [.asked])
        #expect(change(.thinking, to: .needsYou(.fresh)) == [.asked])
        #expect(change(.quiet(since: epoch), to: .needsYou(.fresh)) == [.asked])
    }

    @Test func aDeepeningWaitIsNotAnEvent() {
        #expect(change(.needsYou(.fresh), to: .needsYou(.waiting)).isEmpty)
        #expect(change(.needsYou(.waiting), to: .needsYou(.overdue)).isEmpty)
    }

    @Test func answeredWhenAnAskGoesBackToWork() {
        #expect(change(.needsYou(.waiting), to: .working) == [.answered])
        #expect(change(.needsYou(.fresh), to: .thinking) == [.answered])
        #expect(change(.needsYou(.fresh), to: .retrying(attempt: 1)) == [.answered, .retried])
        #expect(change(.needsYou(.fresh), to: .background(stuck: false)) == [.answered])
        #expect(change(.needsYou(.fresh), to: .finished(.stopped)) == [.stopped])
    }

    @Test func finishedWhenATurnEndsDoneOrUnknown() {
        #expect(change(.working, to: .finished(.done)) == [.finished])
        #expect(change(.thinking, to: .finished(.unknown)) == [.finished])
        #expect(change(.finished(.done), to: .finished(.done)).isEmpty)
    }

    @Test func failedAndStoppedAreTheirOwnEvents() {
        #expect(change(.working, to: .finished(.failed)) == [.failed])
        #expect(change(.working, to: .finished(.stopped)) == [.stopped])
        #expect(change(.finished(.failed), to: .finished(.failed)).isEmpty)
    }

    @Test func retriedWhenItStartsOrTheAttemptGrows() {
        #expect(change(.working, to: .retrying(attempt: 1)) == [.retried])
        #expect(change(.retrying(attempt: 1), to: .retrying(attempt: 2)) == [.retried])
        #expect(change(.retrying(attempt: 2), to: .retrying(attempt: 2)).isEmpty)
    }

    @Test func quietWhenItGoesQuietAndATickingCounterIsNothing() {
        #expect(change(.working, to: .quiet(since: epoch)) == [.quiet])
        #expect(change(.quiet(since: epoch), to: .quiet(since: epoch.addingTimeInterval(30))).isEmpty)
    }

    @Test func resumedWhenQuietOrRetryingComesBackToWork() {
        #expect(change(.quiet(since: epoch), to: .working) == [.resumed])
        #expect(change(.retrying(attempt: 3), to: .thinking) == [.resumed])
        #expect(change(.working, to: .thinking).isEmpty)
    }

    @Test func compactedWhenTheContextFallsByAFifthOrMore() {
        func drop(_ was: Double?, _ now: Double?) -> [WallEvent.Kind] {
            kinds(wall(tile("a", context: was)), wall(tile("a", context: now)))
        }
        #expect(drop(0.9, 0.2) == [.compacted])
        #expect(drop(0.9, 0.7) == [.compacted])
        #expect(drop(0.9, 0.71).isEmpty)
        #expect(drop(0.2, 0.9).isEmpty)
        #expect(drop(nil, 0.1).isEmpty)
        #expect(drop(0.9, nil).isEmpty)
    }

    @Test func awayAndBack() {
        #expect(change(.working, to: .away(lastSeen: epoch)) == [.away])
        #expect(change(.away(lastSeen: epoch), to: .away(lastSeen: epoch.addingTimeInterval(60))).isEmpty)
        #expect(change(.away(lastSeen: epoch), to: .working) == [.back])
        #expect(change(.away(lastSeen: epoch), to: .needsYou(.fresh)) == [.asked, .back])
    }

    @Test func aStepWhenTheNewestStepOrTheWordsChange() {
        let base = tile("a", steps: [step("s1")], beat: [0, 1, 2])
        func after(_ next: WallTile) -> [WallEvent.Kind] { kinds(wall(base), wall(next)) }
        #expect(after(tile("a", steps: [step("s2")], beat: [0, 1, 2])) == [.step])
        #expect(after(tile("a", words: "Running the tests", steps: [step("s1")], beat: [0, 1, 2])) == [.step])
        #expect(after(tile("a", steps: [step("s1")], beat: [0, 1, 3])) == [.step])
        #expect(after(tile("a", steps: [step("s1")], beat: [0, 1, 2])).isEmpty)
        #expect(after(tile("a", steps: [step("s1")], beat: [1, 2, 1])).isEmpty)
    }

    @Test func aStepNeedsWorkInBothReads() {
        let before = wall(tile("a", .thinking, steps: [step("s1")]))
        let after = wall(tile("a", .working, steps: [step("s2")]))
        #expect(kinds(before, after).isEmpty)
        #expect(kinds(after, wall(tile("a", .thinking, steps: [step("s3")]))).isEmpty)
    }

    @Test func aWorkerStartsUnderATileThatWasThere() {
        let before = wall(tile("a", workers: [worker("w1")]))
        let after = wall(tile("a", workers: [worker("w1"), worker("w2")]))
        #expect(WallEvents.between(before, after) == [WallEvent(kind: .workerStarted, tile: "a", worker: "w2")])
    }

    @Test func workersOfANewTileAreNotStartsOfTheirOwn() {
        let after = wall(tile("a"), tile("b", workers: [worker("w1")]))
        #expect(kinds(wall(tile("a")), after) == [.joined])
    }

    @Test func aWorkerEndsGoesQuietOrGetsStuck() {
        func event(_ from: WorkerState, _ to: WorkerState) -> [WallEvent.Kind] {
            kinds(wall(tile("a", workers: [worker("w", from)])), wall(tile("a", workers: [worker("w", to)])))
        }
        #expect(event(.working, .finished) == [.workerEnded])
        #expect(event(.finished, .finished).isEmpty)
        #expect(event(.working, .quiet(since: epoch)) == [.workerQuiet])
        #expect(event(.quiet(since: epoch), .quiet(since: epoch.addingTimeInterval(9))).isEmpty)
        #expect(event(.working, .background(stuck: true)) == [.workerStuck])
        #expect(event(.background(stuck: false), .background(stuck: true)) == [.workerStuck])
        #expect(event(.background(stuck: true), .background(stuck: true)).isEmpty)
        #expect(event(.background(stuck: true), .working).isEmpty)
    }

    @Test func eventsComeInTileOrderWithWorkersAfterTheirTileAndLeftTilesLast() {
        let before = wall(
            tile("a", workers: [worker("w1")]), tile("b"), tile("gone"))
        let after = wall(
            tile("a", .needsYou(.fresh), workers: [worker("w1"), worker("w2")]),
            tile("b", .finished(.done)))
        let events = WallEvents.between(before, after)
        #expect(
            events == [
                WallEvent(kind: .asked, tile: "a"),
                WallEvent(kind: .workerStarted, tile: "a", worker: "w2"),
                WallEvent(kind: .finished, tile: "b"),
                WallEvent(kind: .left, tile: "gone"),
            ])
    }
}
