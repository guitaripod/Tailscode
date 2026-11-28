import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The rehearsal is the first thing a person learns about the dispatcher, so what it sends has to
/// play the lesson it promises and every sentence has to be said at the moment it is true.
@Suite("Delegate rehearsal")
struct DelegateRehearsalTests {
    @Test("A copy that has not bought Pro is shown the dispatcher working; everyone else goes to the board")
    func road() {
        #expect(DelegateRehearsal.road(isPro: false, sells: true) == .rehearsal)
        #expect(DelegateRehearsal.road(isPro: true, sells: true) == .board)
        #expect(DelegateRehearsal.road(isPro: false, sells: false) == .board)
        #expect(DelegateRehearsal.road(isPro: false, sells: true, demo: true) == .board)
    }

    @Test("The rehearsal's machine is one of the scripted ones")
    func host() {
        #expect(DelegateDemo.isDemoHost(DelegateRehearsal.host))
        #expect(DelegateRehearsal.isRehearsal(host: DelegateRehearsal.host))
        #expect(!DelegateRehearsal.isRehearsal(host: "arch.tailnet.ts.net"))
    }

    @Test("The practice packet is complete, fails once on the local rung and passes one rung up for review")
    func practicePlaysTheLesson() async throws {
        let server = DelegateDemoServer(pace: 0)
        let draft = DelegateRehearsal.practice
        let packet = try #require(draft.packet())
        #expect(draft.problems.isEmpty)
        let runID = try await server.start(packet: packet, overrides: DelegateOverrides(review: true))
        var story = DelegateRunStory(runID: runID, tiers: try await server.tiers())
        var lessons: [String] = []
        var seq = 0
        for try await envelope in server.events(runID: runID, after: 0) {
            seq += 1
            story.fold(envelope.event, seq: seq)
            if let lesson = DelegateRehearsal.lesson(story, host: DelegateRehearsal.host), lessons.last != lesson {
                lessons.append(lesson)
            }
        }
        #expect(story.status == .passed)
        #expect(story.passedTier == "t2")
        #expect(story.attempts.map(\.status) == [.fail, .pass])
        #expect(story.delivery == .pending)
        #expect(lessons.count == 3)
        #expect(lessons.first?.contains("cheapest rung") == true)
        #expect(lessons.dropFirst().first?.contains("proof failed") == true)
        #expect(lessons.last?.contains("until you apply it") == true)
        _ = try await server.apply(runID: runID)
        story.delivery = .applied
        #expect(DelegateRehearsal.lesson(story, host: DelegateRehearsal.host)?.contains("whole loop") == true)
    }

    @Test("A real machine's run is never lectured")
    func realMachinesAreQuiet() {
        var story = DelegateRunStory(runID: "R", tiers: [])
        story.status = .running
        #expect(DelegateRehearsal.lesson(story, host: "arch.tailnet.ts.net") == nil)
        var board = DelegateBoard(host: "arch.tailnet.ts.net", serverName: "arch")
        board.stories["R"] = story
        #expect(board.reading(for: "R")?.teaching == nil)
        var scripted = DelegateBoard(host: DelegateRehearsal.host, serverName: DelegateRehearsal.serverName)
        scripted.stories["R"] = story
        #expect(scripted.reading(for: "R")?.teaching != nil)
    }

    @Test("The request written for the machine's agent names every command the hand-typed road does")
    func briefCoversTheSteps() {
        for command in ["cargo install --git https://github.com/guitaripod/delegate", "delegate config init", "delegate install-service"] {
            #expect(DelegateSetup.brief.contains(command))
            #expect(DelegateSetup.steps.contains { $0.command.contains(command) })
        }
        #expect(DelegateSetup.askTitle(agent: "Claude Code") == "Ask Claude Code to set it up")
    }
}
