import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The dispatcher runs on another machine and a run is minutes of someone else's model, so what
/// this app says about one has to be right from the events alone: which rung is lit, what a row
/// reads, when a packet may go, and what the table is allowed to suggest.
@Suite("Delegate")
struct DelegateTests {
    private let tiers = [
        DelegateTier(tier: "t1", label: "local", chain: [DelegateChainEntry(runner: "omp", model: "llama-swap/qwen", thinking: "low", health: "http://x", healthy: true, reason: nil)]),
        DelegateTier(tier: "t2", label: "cheap cloud", chain: [DelegateChainEntry(runner: "omp", model: "ollama-cloud/glm", thinking: nil, health: nil, healthy: nil, reason: nil)]),
        DelegateTier(tier: "t3", label: "frontier", chain: [DelegateChainEntry(runner: "claude", model: "claude-fable-5-1", thinking: "high", health: nil, healthy: nil, reason: nil)]),
    ]

    private func envelope(_ seq: Int, _ event: DelegateEvent) -> DelegateEnvelope {
        DelegateEnvelope(runID: "R", seq: seq, timestamp: "2026-09-04T20:00:0\(seq % 10)+00:00", event: event)
    }

    private var capabilities: DelegateCapabilities {
        DelegateCapabilities(
            api: 1, version: "0.2.0", host: "arch", features: ["runs", "policies"], tiers: ["t1", "t2", "t3"],
            classes: ["default", "rust-mech", "docs"], modes: ["normal", "conserve", "rush"],
            classPolicies: [
                "default": DelegateClassPolicy(tier: "t2", ceiling: "t3"),
                "rust-mech": DelegateClassPolicy(tier: "t1", ceiling: "t2", verify: "cargo test", verified: true, attempts: 2),
                "docs": DelegateClassPolicy(tier: "t1", ceiling: "t2"),
            ],
            modePolicies: DelegateModePolicies(
                conserve: DelegateModePolicy(shift: -1, ceilingVerified: "t2", askBefore: "t3"),
                rush: DelegateModePolicy(shift: 1)))
    }

    @Test("Picking a class fills a verifier that was blank or the previous class's, never one that was typed")
    func classFillsTheVerifier() {
        var draft = DelegateDraft(capabilities: capabilities)
        draft.choose(taskClass: "rust-mech", capabilities: capabilities)
        #expect(draft.verify == "cargo test")
        draft.choose(taskClass: "docs", capabilities: capabilities)
        #expect(draft.verify == "")
        draft.verify = "make check"
        draft.choose(taskClass: "rust-mech", capabilities: capabilities)
        #expect(draft.verify == "make check")
    }

    @Test("The plan resolves the ladder the way the daemon does and says whose choice each rung was")
    func planReadsTheLadder() {
        var draft = DelegateDraft(capabilities: capabilities)
        draft.choose(taskClass: "rust-mech", capabilities: capabilities)
        var plan = draft.plan(capabilities: capabilities, tierOrder: ["t1", "t2", "t3"])
        #expect(plan.start == "t1")
        #expect(plan.ceiling == "t2")
        #expect(!plan.startIsYours)
        #expect(plan.legend == "Starts at t1 and may climb to t2 — the rust-mech class's own range.")
        draft.tier = "t2"
        plan = draft.plan(capabilities: capabilities, tierOrder: ["t1", "t2", "t3"])
        #expect(plan.startIsYours)
        #expect(plan.legend.hasPrefix("Starts at t2 because you set it"))
        draft.tier = nil
        draft.choose(taskClass: "default", capabilities: capabilities)
        #expect(draft.verify.isEmpty)
        draft.mode = .conserve
        plan = draft.plan(capabilities: capabilities, tierOrder: ["t1", "t2", "t3"])
        #expect(plan.start == "t1")
        #expect(plan.ceiling == "t3")
        #expect(plan.askBefore == "t3")
        #expect(plan.legend.contains("Conserve moves the start down to t1"))
        #expect(plan.legend.contains("asks before t3"))
        draft.mode = .rush
        plan = draft.plan(capabilities: capabilities, tierOrder: ["t1", "t2", "t3"])
        #expect(plan.start == "t3")
        #expect(plan.legend.contains("Rush moves the start up to t3"))
    }

    @Test("The composer's rungs wear the numbers for the class being written")
    func rungsWearTheNumbers() {
        var board = DelegateBoard(host: "arch", serverName: "arch")
        board.landed(capabilities: capabilities, tiers: tiers)
        board.filled(stats: [DelegateStat(taskClass: "docs", tier: "t1", attempts: 14, passes: 13, passRate: 0.93, averageMS: 6_400, tokensIn: 1, tokensOut: 1)])
        let rungs = board.composerRungs(taskClass: "docs")
        #expect(rungs.map(\.note) == ["93% · 6.4s", "untried", "untried"])
    }

    @Test("A settled run offers the rung below after a pass, the rungs above and here after a stop, and a copy always")
    func nextStepsFollowTheOutcome() {
        var passed = DelegateRunStory(runID: "P", tiers: tiers)
        passed.fold(envelope(1, .runStarted(packetID: "P", taskClass: "docs", startTier: "t1", ceiling: "t3", mode: .normal, host: "arch", repo: "/r")))
        passed.fold(envelope(2, .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .fail, verifyExit: 1, durationMS: 1))))
        passed.fold(envelope(3, .escalated(from: "t1", to: "t2", reason: "verify")))
        passed.fold(envelope(4, .runFinished(status: .passed, passedTier: "t2", escalations: 1, durationMS: 9, summary: "1 file")))
        #expect(passed.nextSteps(tierOrder: []).map(\.id) == ["duplicate"])
        var clean = DelegateRunStory(runID: "C", tiers: tiers)
        clean.fold(envelope(1, .runFinished(status: .passed, passedTier: "t2", escalations: 0, durationMS: 9, summary: "")))
        #expect(clean.nextSteps(tierOrder: []).map(\.id) == ["replay:t1", "duplicate"])
        #expect(clean.nextSteps(tierOrder: []).first?.title == "Try it at t1")
        var failed = DelegateRunStory(runID: "F", tiers: tiers)
        failed.fold(envelope(1, .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .fail, verifyExit: 1, durationMS: 1))))
        failed.fold(envelope(2, .runFinished(status: .failed, passedTier: nil, escalations: 0, durationMS: 9, summary: "ran out of ladder")))
        #expect(failed.nextSteps(tierOrder: []).map(\.id) == ["replay:t2", "replay:t1", "duplicate"])
        #expect(failed.nextSteps(tierOrder: []).first?.title == "Climb to t2")
        var live = DelegateRunStory(runID: "L", tiers: tiers)
        live.fold(envelope(1, .attemptStarted(tier: "t1", attempt: 1, model: "m")))
        #expect(live.nextSteps(tierOrder: []).isEmpty)
    }

    @Test("A wait and an end nobody chose earn a notice; a hold does not, and neither does the past")
    func noticesFollowTheEvents() {
        var story = DelegateRunStory(runID: "N", tiers: tiers)
        story.packet = DelegatePacket.draft(taskClass: "docs", goal: "Write the README", repo: "/r")
        let asks = story.notice(after: .approvalRequired(tier: "t3", reason: "conserve"))
        #expect(asks?.kind == .asks)
        #expect(asks?.body == "Write the README waits before t3")
        story.fold(envelope(1, .runFinished(status: .passed, passedTier: "t1", escalations: 0, durationMS: 1, summary: "")))
        #expect(story.notice(after: .runFinished(status: .passed, passedTier: "t1", escalations: 0, durationMS: 1, summary: ""))?.title == "Delegate passed at t1")
        #expect(story.notice(after: .runFinished(status: .held, passedTier: nil, escalations: 0, durationMS: 1, summary: "")) == nil)
        #expect(story.notice(after: .attemptStarted(tier: "t1", attempt: 1, model: "m")) == nil)
        let now = Date()
        #expect(DelegateDesk.isRecent(DelegateTimestamp.format(now.addingTimeInterval(-10)), now: now))
        #expect(!DelegateDesk.isRecent(DelegateTimestamp.format(now.addingTimeInterval(-600)), now: now))
        #expect(!DelegateDesk.isRecent("not a date", now: now))
    }

    @Test("A machine with no dispatcher is shown three copyable commands, and the demo never is")
    func setupIsTheRoad() {
        #expect(DelegateSetup.steps.count == 2)
        #expect(DelegateSetup.steps.map(\.command).allSatisfy { !$0.isEmpty })
        #expect(DelegateSetup.steps[0].command.hasPrefix("cargo install"))
        #expect(DelegateSetup.steps[1].command.contains("install-service"))
        #expect(DelegateReach.wantsPassword.asksForPassword)
        #expect(DelegateReach.refused.asksForPassword)
        #expect(!DelegateReach.answering(version: "0.3.0").asksForPassword)
        #expect(!DelegateReach.unreachable("x").asksForPassword)
        var board = DelegateBoard(host: "arch", serverName: "arch")
        #expect(DelegateSetup.isWanted(board: board, known: false))
        #expect(!DelegateSetup.isWanted(board: board, known: true))
        board.failed("no route")
        #expect(DelegateSetup.isWanted(board: board, known: false))
        board.landed(capabilities: capabilities, tiers: tiers)
        #expect(!DelegateSetup.isWanted(board: board, known: false))
        #expect(!DelegateSetup.isWanted(board: DelegateBoard(host: "studio.tailnet-demo.ts.net", serverName: "studio"), known: false))
    }

    @Test("The beta mark is one word on the badge and three paragraphs behind it")
    func betaExplainsItself() {
        #expect(DelegateBeta.badge == "BETA")
        #expect(DelegateBeta.paragraphs.count == 3)
        for paragraph in DelegateBeta.paragraphs {
            #expect(paragraph.hasSuffix("."))
            #expect(paragraph.count > 80)
        }
        #expect(DelegateBeta.body.components(separatedBy: "\n\n").count == 3)
        #expect(DelegateBeta.marked("Not checked yet") == "Beta · Not checked yet")
        #expect(DelegateBeta.spoken.hasPrefix(DelegateBeta.label))
    }

    @Test("A run climbs the ladder one rung at a time and the lit rung is where it passed")
    func ladderFollowsTheRun() {
        var story = DelegateRunStory(runID: "R", tiers: tiers)
        story.fold(envelope(1, .runStarted(packetID: "P", taskClass: "rust-mech", startTier: "t1", ceiling: "t3", mode: .normal, host: "arch", repo: "/r")))
        story.fold(envelope(2, .tierSelected(tier: "t1", label: "local", runner: "omp", model: "llama-swap/qwen", chainIndex: 0)))
        story.fold(envelope(3, .attemptStarted(tier: "t1", attempt: 1, model: "llama-swap/qwen")))
        #expect(story.ladder.rungs.map(\.state) == [.current, .pending, .pending])
        #expect(story.subtitle == "t1 attempt 1 running")
        story.fold(envelope(4, .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .fail, verifyExit: 101, durationMS: 12_300))))
        story.fold(envelope(5, .escalated(from: "t1", to: "t2", reason: "t1 failed at 1")))
        story.fold(envelope(6, .tierSelected(tier: "t2", label: "cheap cloud", runner: "omp", model: "ollama-cloud/glm", chainIndex: 0)))
        story.fold(envelope(7, .attemptStarted(tier: "t2", attempt: 1, model: "ollama-cloud/glm")))
        #expect(story.ladder.rungs.map(\.state) == [.failed, .current, .pending])
        #expect(story.lines[3].text == "t1 ✗ attempt 1 · verify exit 101 (12.3s)")
        story.fold(envelope(8, .attemptFinished(DelegateAttemptOutcome(tier: "t2", attempt: 1, status: .pass, durationMS: 41_000, changedFiles: ["src/lib.rs", "tests/x.rs"]))))
        story.fold(envelope(9, .applied(files: ["src/lib.rs", "tests/x.rs"], patchBytes: 400)))
        story.fold(envelope(10, .runFinished(status: .passed, passedTier: "t2", escalations: 1, durationMS: 60_000, summary: "2 file(s)")))
        #expect(story.status == .passed)
        #expect(story.ladder.rungs.map(\.state) == [.failed, .passed, .pending])
        #expect(story.ladder.lit?.tier == "t2")
        #expect(story.subtitle == "Passed at t2 after 1 escalation(s) · 2 files")
        #expect(story.activity == nil)
        #expect(story.badge == "t2")
        #expect(story.lines.last?.text.hasPrefix("passed at t2 · 1 escalation(s) · 60.0s") == true)
    }

    @Test("A replayed sequence is folded once")
    func replayIsIdempotent() {
        var story = DelegateRunStory(runID: "R", tiers: tiers)
        let started = envelope(1, .runStarted(packetID: "P", taskClass: "docs", startTier: "t1", ceiling: "t2", mode: .normal, host: "arch", repo: "/r"))
        story.fold(started)
        story.fold(started)
        #expect(story.lines.count == 1)
        #expect(story.ladder.rungs.map(\.state) == [.pending, .pending, .beyondCeiling])
    }

    @Test("A wait for approval knocks, and a refusal holds the run on that rung")
    func approvalIsAStateWithAFace() {
        var story = DelegateRunStory(runID: "R", tiers: tiers)
        story.fold(envelope(1, .runStarted(packetID: "P", taskClass: "docs", startTier: "t1", ceiling: "t3", mode: .conserve, host: "arch", repo: "/r")))
        story.fold(envelope(2, .attemptFinished(DelegateAttemptOutcome(tier: "t1", attempt: 1, status: .fail, durationMS: 10))))
        story.fold(envelope(3, .escalated(from: "t1", to: "t2", reason: "x")))
        story.fold(envelope(4, .attemptFinished(DelegateAttemptOutcome(tier: "t2", attempt: 1, status: .fail, durationMS: 10))))
        story.fold(envelope(5, .escalated(from: "t2", to: "t3", reason: "x")))
        story.fold(envelope(6, .approvalRequired(tier: "t3", reason: "mode conserve requires approval before t3")))
        #expect(story.needsApproval)
        #expect(story.activity == .needsApproval)
        #expect(story.ladder.rungs.map(\.state) == [.failed, .failed, .held])
        #expect(story.subtitle == "Waiting for approval before t3")
        story.fold(envelope(7, .approvalResolved(tier: "t3", approved: false)))
        story.fold(envelope(8, .runFinished(status: .held, passedTier: nil, escalations: 2, durationMS: 100, summary: "held before t3")))
        #expect(story.status == .held)
        #expect(story.tone == .attention)
        #expect(story.subtitle == "Held before t3")
        #expect(!story.needsApproval)
    }

    @Test("A stored run reads without a stream, and the rung it passed at is lit")
    func storedRunHasALadder() {
        let run = DelegateRun(
            id: "R", packetID: "P", taskClass: "docs", repo: "/r", host: "arch", mode: .normal, startTier: "t1",
            ceiling: "t2", status: .passed, createdAt: "2026-09-04T20:00:00+00:00", finishedAt: nil, passedTier: "t1",
            escalations: 0, summary: "1 file(s): done",
            packet: DelegatePacket(id: "P", taskClass: "docs", goal: "Create NOTES.md\nmore", paths: ["NOTES.md"]))
        let story = DelegateRunStory(runID: run.id, tiers: tiers, run: run)
        #expect(story.headline == "Create NOTES.md")
        #expect(story.ladder.rungs.map(\.state) == [.passed, .pending, .beyondCeiling])
        #expect(story.subtitle == "Passed at t1 · 1 file")
    }

    @Test("The board folds live events into the run it lists")
    func boardFoldsIntoItsRuns() {
        var board = DelegateBoard(host: "arch", serverName: "arch")
        board.landed(capabilities: DelegateCapabilities(api: 1, version: "0.1.0", host: "arch", features: [], tiers: ["t1", "t2", "t3"], classes: ["default", "docs"], modes: ["normal"]), tiers: tiers)
        #expect(board.statusLine == "delegate 0.1.0 on arch · 3 tiers")
        let packet = DelegatePacket(id: "P", taskClass: "docs", goal: "Create X", paths: ["X"], repo: "/r")
        board.expect(runID: "R", packet: packet, startTier: "t1", ceiling: "t2")
        #expect(board.runs.first?.id == "R")
        #expect(board.liveRunIDs == ["R"])
        board.fold(envelope(1, .runStarted(packetID: "P", taskClass: "docs", startTier: "t1", ceiling: "t2", mode: .normal, host: "arch", repo: "/r")))
        board.fold(envelope(2, .runFinished(status: .passed, passedTier: "t1", escalations: 0, durationMS: 5_000, summary: "1 file(s)")))
        #expect(board.runs.first?.status == .passed)
        #expect(board.liveRunIDs.isEmpty)
        #expect(board.story(for: "R")?.status == .passed)
        #expect(board.tierLines.map(\.detail) == ["answering", "not probed", "not probed"])
    }

    @Test("A packet needs a goal and a repository; scope and verifier are cautions, not walls")
    func draftValidation() {
        var draft = DelegateDraft(capabilities: DelegateCapabilities(api: 1, version: "0.1.0", host: "arch", features: [], tiers: ["t1"], classes: ["docs", "default"], modes: []), repo: "")
        #expect(draft.taskClass == "default")
        #expect(draft.problems.count == 2)
        draft.goal = "Create NOTES.md containing hello"
        draft.repo = "/home/me/repo"
        #expect(draft.canSend)
        #expect(draft.cautions.count == 2)
        draft.paths = "NOTES.md, docs/\n"
        draft.verify = "grep -q hello NOTES.md"
        draft.mode = .conserve
        #expect(draft.cautions.isEmpty)
        let packet = draft.packet()
        #expect(packet?.paths == ["NOTES.md", "docs/"])
        #expect(packet?.verify == "grep -q hello NOTES.md")
        #expect(packet?.mode == .conserve)
        #expect(packet?.id.count == 26)
        #expect(packet?.notes == nil)
        let again = DelegateDraft(packet: packet!)
        #expect(again.paths == "NOTES.md\ndocs/")
        #expect(DelegateDraft.verifySuggestions(paths: ["src/lib.rs"], repo: "/x").first == "cargo test")
        #expect(DelegateDraft.verifySuggestions(paths: [], repo: "/home/me/Dev/iOS/App").first == "swift test")
    }

    @Test("Promotion is a streak the table can show, never a feeling")
    func promotionHints() {
        let order = ["t1", "t2", "t3"]
        let stats = [
            DelegateStat(taskClass: "docs", tier: "t2", attempts: 12, passes: 12, passRate: 1, averageMS: 4000, tokensIn: 0, tokensOut: 0),
            DelegateStat(taskClass: "rust-impl", tier: "t1", attempts: 6, passes: 1, passRate: 0.16, averageMS: 30000, tokensIn: 0, tokensOut: 0),
            DelegateStat(taskClass: "strings", tier: "t1", attempts: 3, passes: 3, passRate: 1, averageMS: 900, tokensIn: 0, tokensOut: 0),
        ]
        let hints = DelegatePromotion.hints(stats, tiers: order)
        #expect(hints == [
            "docs passes 12 of 12 at t2 — try starting it at t1",
            "rust-impl fails 5 of 6 at t1 — start it at t2",
        ])
        let rows = stats.map(DelegateStatRow.init)
        #expect(rows[0].rateText == "100%")
        #expect(rows[1].line == "1 of 6 passed · 30.0s average")
    }

    @Test("Access is remembered per machine and the password key follows the host")
    func accessStore() throws {
        let suite = "tailscode.tests.delegate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DelegateAccessStore.all(defaults: defaults).isEmpty)
        DelegateAccessStore.remember(DelegateAccess(host: "100.91.211.44"), defaults: defaults)
        DelegateAccessStore.remember(DelegateAccess(host: "100.127.250.64", port: 4101), defaults: defaults)
        DelegateAccessStore.remember(DelegateAccess(host: "100.91.211.44", enabled: false), defaults: defaults)
        let all = DelegateAccessStore.all(defaults: defaults)
        #expect(all.count == 2)
        #expect(DelegateAccessStore.access(host: "100.91.211.44", defaults: defaults)?.enabled == false)
        #expect(DelegateAccessStore.access(host: "100.127.250.64", defaults: defaults)?.address == "100.127.250.64:4101")
        #expect(DelegateAccess(host: "h").secretKey == "delegate.h")
        #expect(DelegateAccess(host: "h").config(password: "p")?.credentials?.username == "delegate")
        DelegateAccessStore.forget(host: "100.91.211.44", defaults: defaults)
        #expect(DelegateAccessStore.all(defaults: defaults).count == 1)
    }

    @Test("The gate opens for Pro and for a client that sells nothing")
    func proGate() {
        #expect(DelegateProGate.allows(isPro: false, sells: true) == false)
        #expect(DelegateProGate.allows(isPro: true, sells: true))
        #expect(DelegateProGate.allows(isPro: false, sells: false))
        #expect(ProOffer.perks.contains { $0.symbol == DelegateEntryPoint.symbol })
    }

    @Test("Every event kind prints a line except the ones this app cannot read")
    func everyEventHasALine() {
        let events: [DelegateEvent] = [
            .tierSkipped(tier: "t2", reason: "unreachable"),
            .chainFailover(tier: "t3", from: "a", to: "b", reason: "402"),
            .progress(tier: "t1", attempt: 1, text: "write NOTES.md"),
            .unknown(kind: "later"),
        ]
        let lines = events.enumerated().compactMap { DelegateRunStory.line(for: $1, seq: $0) }
        #expect(lines.count == 3)
        #expect(lines[0].text == "t2 skipped: unreachable")
        #expect(lines[1].text == "t3 ↷ b (a failed: 402)")
        #expect(lines[2].isProgress)
    }
}
