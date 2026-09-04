import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The demo dispatcher has to be the real thing minus the machine: the same events, the same
/// shapes, the same answers to approve, hold, cancel and a new packet — so a first-run user and
/// App Review work the whole feature and nothing they see is a picture.
@Suite("Delegate demo")
struct DelegateDemoTests {
    private func collect(_ server: DelegateDemoServer, _ runID: String, after: Int = 0) async throws -> [DelegateEvent] {
        var events: [DelegateEvent] = []
        for try await envelope in server.events(runID: runID, after: after) { events.append(envelope.event) }
        return events
    }

    @Test("The world opens with one run of every kind")
    func seededWorld() async throws {
        let server = DelegateDemoServer(pace: 0)
        let runs = try await server.runs(limit: 50)
        #expect(runs.map(\.id) == ["demo-run-live", "demo-run-held", "demo-run-failed", "demo-run-docs", "demo-run-climbed"])
        #expect(runs.map(\.status) == [.running, .running, .failed, .passed, .passed])
        let capabilities = try await server.capabilities()
        #expect(capabilities.tiers == ["t1", "t2", "t3"])
        let tiers = try await server.tiers()
        #expect(tiers.count == 3)
        let stats = try await server.stats(taskClass: nil)
        #expect(!DelegatePromotion.hints(stats, tiers: capabilities.tiers).isEmpty)
        let detail = try await server.run(id: "demo-run-climbed")
        #expect(detail.attempts.count == 3)
        #expect(detail.attempts.last?.status == .pass)
    }

    @Test("A live run plays to a pass and its listing follows")
    func liveRunFinishes() async throws {
        let server = DelegateDemoServer(pace: 0)
        let events = try await collect(server, "demo-run-live")
        #expect(events.first.map { if case .runStarted = $0 { true } else { false } } == true)
        #expect(events.last?.isTerminal == true)
        let run = try await server.run(id: "demo-run-live")
        #expect(run.run.status == .passed)
        #expect(run.run.passedTier == "t1")
        #expect(run.attempts.count == 2)
        var story = DelegateRunStory(runID: "demo-run-live", tiers: try await server.tiers())
        for (index, event) in events.enumerated() { story.fold(event, seq: index + 1) }
        #expect(story.ladder.rungs.map(\.state) == [.passed, .pending, .pending])
    }

    @Test("A held run waits, climbs when approved, and reads as passed at the top")
    func approvalClimbs() async throws {
        let server = DelegateDemoServer(pace: 0)
        let detail = try await server.run(id: "demo-run-held")
        #expect(detail.run.status == .running)
        var story = DelegateRunStory(detail: detail, tiers: try await server.tiers())
        try await server.approve(runID: "demo-run-held", approved: true)
        let events = try await collect(server, "demo-run-held")
        for (index, event) in events.enumerated() { story.fold(event, seq: index + 1) }
        #expect(story.status == .passed)
        #expect(story.passedTier == "t3")
        #expect(story.escalations == 2)
        #expect(story.ladder.rungs.map(\.state) == [.failed, .failed, .passed])
    }

    @Test("A held run that is refused ends held on its rung")
    func refusalHolds() async throws {
        let server = DelegateDemoServer(pace: 0)
        try await server.approve(runID: "demo-run-held", approved: false)
        let events = try await collect(server, "demo-run-held")
        guard case .runFinished(let status, _, _, _, _) = events.last else { Issue.record("no ending"); return }
        #expect(status == .held)
    }

    @Test("A packet written in the demo is tried, fails once, and passes one rung up")
    func newPacketClimbs() async throws {
        let server = DelegateDemoServer(pace: 0)
        let packet = DelegatePacket(id: "P1", taskClass: "rust-impl", goal: "Fix add()", paths: ["src/lib.rs"], verify: "cargo test", repo: "/r")
        let runID = try await server.start(packet: packet, overrides: DelegateOverrides(tier: "t1", ceiling: "t3"))
        let events = try await collect(server, runID)
        let escalations = events.filter { if case .escalated = $0 { true } else { false } }.count
        #expect(escalations == 1)
        var story = DelegateRunStory(runID: runID, tiers: try await server.tiers())
        for (index, event) in events.enumerated() { story.fold(event, seq: index + 1) }
        #expect(story.status == .passed)
        #expect(story.passedTier == "t2")
        #expect(story.attempts.map(\.status) == [.fail, .pass])
        let runs = try await server.runs(limit: 1)
        #expect(runs.first?.id == runID)
        #expect(runs.first?.status == .passed)
    }

    @Test("Rush skips the stumble, and a cancel ends a run where it stands")
    func rushAndCancel() async throws {
        let server = DelegateDemoServer(pace: 0)
        let packet = DelegatePacket(id: "P2", taskClass: "docs", goal: "Write NOTES.md", paths: ["NOTES.md"], repo: "/r")
        let rushed = try await server.start(packet: packet, overrides: DelegateOverrides(tier: "t1", ceiling: "t2", mode: .rush))
        let events = try await collect(server, rushed)
        #expect(!events.contains { if case .escalated = $0 { true } else { false } })
        try await server.cancel(runID: "demo-run-held")
        let held = try await server.run(id: "demo-run-held")
        #expect(held.run.status == .cancelled)
    }

    @Test("Demo hosts are the demo world's own machines and the gate stays open for them")
    func demoHostsAndGate() {
        #expect(DelegateDemo.isDemoHost("studio.tailnet-demo.ts.net"))
        #expect(!DelegateDemo.isDemoHost("100.91.211.44"))
        #expect(DelegateProGate.allows(isPro: false, sells: true, demo: true))
        #expect(!DelegateProGate.allows(isPro: false, sells: true, demo: false))
        var board = DelegateBoard(host: "studio.tailnet-demo.ts.net", serverName: "studio")
        #expect(board.note != nil)
        board = DelegateBoard(host: "arch", serverName: "arch")
        #expect(board.note == nil)
    }
}
