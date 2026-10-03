import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A patch that waits to be read, a board grouped by what it asks of the reader, a run screen that
/// leads with the one thing that matters, and a chat that hands its task over: every word decided
/// in Core, so these are the claims the three clients draw.
@Suite("Delegate review")
struct DelegateReviewTests {
    private let tiers = [
        DelegateTier(tier: "t1", label: "local", chain: [DelegateChainEntry(runner: "omp", model: "llama-swap/qwen3.8-27b", healthy: true)]),
        DelegateTier(tier: "t2", label: "cheap cloud", chain: [DelegateChainEntry(runner: "omp", model: "ollama-cloud/glm-5.3-flash")]),
        DelegateTier(tier: "t3", label: "frontier", chain: [DelegateChainEntry(runner: "claude", model: "claude-fable-5-1", healthy: false, reason: "401")]),
    ]

    private func collect(_ server: DelegateDemoServer, _ runID: String, after: Int = 0) async throws -> [DelegateEnvelope] {
        var envelopes: [DelegateEnvelope] = []
        for try await envelope in server.events(runID: runID, after: after) { envelopes.append(envelope) }
        return envelopes
    }

    private func pass(_ story: inout DelegateRunStory, held: Bool, verified: Bool = true) {
        let outcome = DelegateAttemptOutcome(
            tier: "t1", attempt: 1, status: .pass, verifyExit: verified ? 0 : nil, durationMS: 4_000,
            tokensIn: 1_000, tokensOut: 200, changedFiles: ["a.rs", "b.rs"])
        story.fold(.runStarted(packetID: "P", taskClass: "docs", startTier: "t1", ceiling: "t2", mode: .normal, host: "h", repo: "/r/pulse"), seq: 1)
        story.fold(.attemptFinished(outcome), seq: 2)
        story.fold(held ? .awaitingReview(files: ["a.rs", "b.rs"], patchBytes: 90) : .applied(files: ["a.rs", "b.rs"], patchBytes: 90), seq: 3)
        story.fold(.runFinished(status: .passed, passedTier: "t1", escalations: 0, durationMS: 4_100, summary: "2 files: done"), seq: 4)
    }

    @Test("A held pass knocks, says Review, leads with the files and offers apply first")
    func heldPassNeedsYou() {
        var story = DelegateRunStory(runID: "R", tiers: tiers)
        pass(&story, held: true)
        #expect(story.needsReview)
        #expect(story.needsYou)
        #expect(story.badge == "Review")
        #expect(story.activity == .needsApproval)
        #expect(story.tone == .attention)
        #expect(story.subtitle == "Passed at t1 · 2 files · waiting for your review")
        let reading = DelegateRunReading(story: story, run: nil, tierOrder: ["t1", "t2", "t3"])
        #expect(reading.lead?.title == "Ready for your review")
        #expect(reading.primary?.kind == .apply)
        #expect(reading.secondary.map(\.kind) == [.discard, .duplicate])
        #expect(reading.filesTitle == "2 files to review")
        #expect(reading.files.map(\.name) == ["a.rs", "b.rs"])
        #expect(reading.files.allSatisfy { $0.counts == nil })
        #expect(story.notice(after: .runFinished(status: .passed, passedTier: "t1", escalations: 0, durationMS: 1, summary: ""))?.title == "Ready for your review")
    }

    @Test("A pass with no verifier says nothing judged it")
    func unverifiedPassSaysSo() {
        var story = DelegateRunStory(runID: "R", tiers: tiers)
        pass(&story, held: true, verified: false)
        let lead = DelegateRunReading(story: story, run: nil, tierOrder: []).lead
        #expect(lead?.body?.hasPrefix("Nothing judged this one") == true)
    }

    @Test("Applied and discarded passes settle, and the record moves the fold forward")
    func deliveryFromTheRecord() {
        var story = DelegateRunStory(runID: "R", tiers: tiers)
        pass(&story, held: false)
        #expect(story.badge == "Applied")
        #expect(!story.needsYou)
        #expect(DelegateRunReading(story: story, run: nil, tierOrder: []).lead?.title == "Applied to the tree")
        var board = DelegateBoard(host: "h", serverName: "h")
        var held = DelegateRunStory(runID: "R", tiers: tiers)
        pass(&held, held: true)
        board.remember(held)
        let packet = DelegatePacket(id: "P", taskClass: "docs", goal: "g")
        var record = DelegateRun(
            id: "R", packetID: "P", taskClass: "docs", repo: "/r", host: "h", mode: .normal, startTier: "t1", ceiling: "t2",
            status: .passed, createdAt: "2026-10-03T10:00:00+00:00", packet: packet, delivery: .discarded)
        board.filled(runs: [record])
        #expect(board.story(for: "R")?.badge == "Discarded")
        record.delivery = nil
        board.filled(runs: [record])
        #expect(board.story(for: "R")?.delivery == .discarded)
        board.delivered(runID: "R", .applied)
        #expect(board.runs.first?.delivery == .applied)
    }

    @Test("A stopped run leads with why, in the verifier's own last lines, and climbing is the first move")
    func failureLeads() {
        var story = DelegateRunStory(runID: "R", tiers: tiers)
        story.fold(.runStarted(packetID: "P", taskClass: "rust", startTier: "t1", ceiling: "t2", mode: .normal, host: "h", repo: "/r"), seq: 1)
        story.fold(.attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .scope, durationMS: 1, changedFiles: ["a", "x"], scopeViolations: ["x"])), seq: 2)
        story.fold(.escalated(from: "t1", to: "t2", reason: "t1 failed at 1"), seq: 3)
        story.fold(.attemptFinished(DelegateAttemptOutcome(tier: "t2", attempt: 1, status: .fail, verifyExit: 1, durationMS: 1, verifyTail: "\n\nline one\nsv.strings: Unexpected character\n\n")), seq: 4)
        story.fold(.runFinished(status: .failed, passedTier: nil, escalations: 1, durationMS: 55_000, summary: "exhausted ladder; last failure at t2 attempt 1"), seq: 5)
        #expect(story.subtitle == "Stopped at t2 · the verifier exited 1")
        #expect(story.lines.last?.text == "Failed · 1 escalation · 55.0s")
        #expect(story.lines.first { $0.seq == 2 }?.detail == "x")
        let reading = DelegateRunReading(story: story, run: nil, tierOrder: ["t1", "t2", "t3"])
        #expect(reading.lead?.title == "Why it stopped")
        #expect(reading.lead?.caption == "t2 · attempt 1 · the verifier exited 1")
        #expect(reading.lead?.body == "\n\nline one\nsv.strings: Unexpected character")
        #expect(reading.lead?.bodyIsOutput == true)
        #expect(reading.primary?.kind == .replay(tier: "t3"))
        #expect(reading.primary?.role == .primary)
        #expect(reading.replayTiers == ["t1", "t2", "t3"])
        #expect(reading.files.isEmpty)
    }

    @Test("A live run hides nothing; a settled one drops the worker's chatter from its timeline")
    func timelineChatter() {
        var story = DelegateRunStory(runID: "R", tiers: tiers)
        story.fold(.runStarted(packetID: "P", taskClass: "docs", startTier: "t1", ceiling: "t1", mode: .normal, host: "h", repo: "/r"), seq: 1)
        story.fold(.tierSelected(tier: "t1", label: "local", runner: "omp", model: "llama-swap/qwen3.8-27b", chainIndex: 0), seq: 2)
        story.fold(.attemptStarted(tier: "t1", attempt: 1, model: "q"), seq: 3)
        story.fold(.progress(tier: "t1", attempt: 1, text: "edit src/lib.rs"), seq: 4)
        var reading = DelegateRunReading(story: story, run: nil, tierOrder: [])
        #expect(reading.lead?.caption == "t1 · attempt 1 · qwen3.8-27b")
        #expect(reading.lead?.body == "edit src/lib.rs")
        #expect(reading.primary == nil)
        #expect(reading.secondary.map(\.kind) == [.cancel])
        #expect(reading.timeline.contains { $0.isProgress })
        story.fold(.runFinished(status: .cancelled, passedTier: nil, escalations: 0, durationMS: 1, summary: "cancelled"), seq: 5)
        reading = DelegateRunReading(story: story, run: nil, tierOrder: [])
        #expect(!reading.timeline.contains { $0.isProgress })
    }

    @Test("The board groups runs by what they ask of the reader and draws a ladder that says only what it knows")
    func boardSections() async throws {
        let server = DelegateDemoServer(pace: 0)
        var board = DelegateBoard(host: DelegateDemo.hosts.first!, serverName: "studio")
        board.landed(capabilities: try await server.capabilities(), tiers: tiers)
        board.filled(runs: try await server.runs(limit: 50))
        board.filled(stats: try await server.stats(taskClass: nil))
        for try await envelope in server.events(runID: "demo-run-held", after: 0) {
            board.fold(envelope)
            if case .approvalRequired = envelope.event { break }
        }
        let sections = board.sections()
        #expect(sections.map(\.kind) == [.needsYou, .running, .earlier])
        #expect(sections[0].rows.map(\.runID) == ["demo-run-held", "demo-run-docs"])
        #expect(sections[1].rows.map(\.runID) == ["demo-run-live"])
        #expect(board.waitingCount == 2)
        #expect(board.subtitle == "studio · delegate 0.4.0")
        #expect(board.supportsReview)
        let rungs = board.ladderRungs
        #expect(rungs.map(\.model) == ["qwen3.8-27b", "glm-5.3-flash", "claude-fable-5-1"])
        #expect(rungs[0].health == "answering")
        #expect(rungs[1].health == nil)
        #expect(rungs[2].tone == .danger)
        #expect(rungs[0].record?.hasPrefix("82% of 51") == true)
        #expect(rungs[2].record == nil)
    }

    @Test("The demo holds a written packet's patch, serves it, and lands it once")
    func demoReviewRoad() async throws {
        let server = DelegateDemoServer(pace: 0)
        let packet = DelegatePacket(id: "P1", taskClass: "docs", goal: "Write NOTES.md", paths: ["NOTES.md"], repo: "/r")
        let runID = try await server.start(packet: packet, overrides: DelegateOverrides(tier: "t1", ceiling: "t1", review: true))
        let envelopes = try await collect(server, runID)
        #expect(envelopes.contains { if case .awaitingReview = $0.event { true } else { false } })
        #expect(try await server.run(id: runID).run.delivery == .pending)
        let patch = try await server.patch(runID: runID)
        let files = DelegatePatch.files(patch)
        #expect(files.map(\.path) == ["NOTES.md"])
        #expect(files.first?.added == 3 && files.first?.removed == 1)
        #expect(try await server.apply(runID: runID) == ["NOTES.md"])
        await #expect(throws: AgentError.self) { _ = try await server.apply(runID: runID) }
        let after = try await collect(server, runID, after: envelopes.last?.seq ?? 0)
        guard case .applied = after.last?.event else { Issue.record("no applied event after the end"); return }
        #expect(try await server.run(id: runID).run.delivery == .applied)
    }

    @Test("The seeded review reads like a real diff, file by file")
    func seededPatchSplits() async throws {
        let server = DelegateDemoServer(pace: 0)
        let files = DelegatePatch.files(try await server.patch(runID: "demo-run-climbed"))
        #expect(files.map(\.path) == ["src/scan.rs", "tests/scan.rs"])
        #expect(files[0].added == 7 && files[0].removed == 2)
        #expect(files[1].patch.hasPrefix("diff --git a/tests/scan.rs"))
        #expect(GitPatchReader.lines(files[1].patch).contains { $0.kind == .addition })
        await #expect(throws: AgentError.self) { _ = try await server.patch(runID: "demo-run-failed") }
        _ = try await server.discard(runID: "demo-run-docs")
        #expect(try await server.run(id: "demo-run-docs").run.delivery == .discarded)
    }

    @Test("Repositories are offered from the chats first, then the runs, each once")
    func repoChoices() {
        let packet = DelegatePacket(id: "P", taskClass: "docs", goal: "g")
        func run(_ id: String, _ repo: String) -> DelegateRun {
            DelegateRun(id: id, packetID: "P", taskClass: "docs", repo: repo, host: "h", mode: .normal, startTier: "t1", ceiling: "t1", status: .passed, createdAt: "", packet: packet)
        }
        let choices = DelegateRepoChoices.make(
            runs: [run("1", "/home/m/Dev/hinta"), run("2", "/home/m/Dev/pulse/"), run("3", "/home/m/Dev/hinta")],
            chats: [DelegateChatFootprint(title: "Fix login", directory: "/home/m/Dev/pulse", isWorking: false)])
        #expect(choices.map(\.path) == ["/home/m/Dev/pulse", "/home/m/Dev/hinta"])
        #expect(choices.map(\.name) == ["pulse", "hinta"])
        #expect(choices[0].detail == "Chat · Fix login")
        #expect(choices[1].detail == "2 runs here")
    }

    @Test("Applying while a chat works in the same repository asks first and names the chat")
    func applyCaution() {
        let chats = [
            DelegateChatFootprint(title: "Busy", directory: "/r/pulse/sub", isWorking: true),
            DelegateChatFootprint(title: "Idle", directory: "/r/pulse", isWorking: false),
            DelegateChatFootprint(title: "Elsewhere", directory: "/r/pulse-ios", isWorking: true),
        ]
        let cautions = DelegateApplyCheck.cautions(repo: "/r/pulse/", chats: chats)
        #expect(cautions.count == 1)
        #expect(cautions.first?.contains("“Busy”") == true)
    }

    @Test("/delegate opens the composer with the words as the goal, and a chat's handoff fills the repository")
    func handoff() {
        #expect(SlashDispatch.decide(text: "/delegate add a --json flag", commands: [], supportsCompaction: true, resolvesFromPromptText: false, supportsDelegate: true) == .delegatePreflight(goal: "add a --json flag"))
        #expect(SlashDispatch.decide(text: "/delegate x", commands: [], supportsCompaction: true, resolvesFromPromptText: false) == .plainText)
        let catalog = CommandCatalogStore.forComposer([AgentCommand(name: "delegate", details: "theirs", source: .builtin)], supportsDesign: true, supportsDelegate: true)
        #expect(catalog.map(\.name) == ["design", "delegate"])
        #expect(catalog[1].details == DelegateHandoff.details)
        let draft = DelegateHandoff(host: "arch", serverName: "arch", goal: "  add a flag \n", repo: "/r/pulse").draft(capabilities: nil)
        #expect(draft.goal == "add a flag")
        #expect(draft.repo == "/r/pulse")
        #expect(draft.review)
        #expect(draft.canSend)
    }

    @Test("Words count honestly and a summary adds only what its lines do not")
    func words() {
        #expect(DelegateWords.escalations(1) == "1 escalation")
        #expect(DelegateWords.afterEscalations(2) == "after 2 escalations")
        #expect(DelegateWords.summaryClaim("2 file(s): cargo test passes", status: .passed) == "cargo test passes")
        #expect(DelegateWords.summaryClaim("1 file", status: .passed) == nil)
        #expect(DelegateWords.summaryClaim("exhausted ladder; last failure at t2 attempt 1", status: .failed) == nil)
        #expect(DelegateWords.summaryClaim("applying the passing patch: conflict", status: .error) == "applying the passing patch: conflict")
        #expect(DelegateWords.shortModel("llama-swap/qwen38-nvfp4") == "qwen38-nvfp4")
        #expect(DelegateWords.repoName("/home/m/Dev/hinta/") == "hinta")
        var draft = DelegateDraft(capabilities: nil)
        draft.taskClass = "docs"
        #expect(draft.planSummary(capabilities: nil, tierOrder: ["t1", "t2"]) == "docs · t1 → t2 · no verifier")
    }
}
