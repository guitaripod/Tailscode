import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Resume when the window opens")
struct AutoResumeTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let row = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    private func gauge(
        label: String, fraction: Double, resetsIn: TimeInterval? = 3600, trusted: Bool = true
    ) -> UsageQuota.Gauge {
        UsageQuota.Gauge(
            key: label.lowercased(), label: label, fraction: fraction,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, trustedReset: trusted)
    }

    private func quota(_ provider: String, _ gauges: [UsageQuota.Gauge]) -> UsageQuota {
        UsageQuota(
            providerName: provider, subtitle: "", source: "test", live: true, gauges: gauges,
            details: [])
    }

    private func decide(
        failure: String? = nil, quotas: [UsageQuota], model: String? = nil, enabled: Bool = true
    ) -> ResumeVerdict {
        AutoResume.decide(
            row: row, profileID: "p", sessionID: "s", trigger: .refused, failure: failure,
            quotas: quotas, model: model, enabled: enabled, now: now)
    }

    @Test("A wall with a stated reset plans a send at that reset plus the grace")
    func plansOnTheProvidersClock() {
        let verdict = decide(quotas: [quota("Claude", [gauge(label: "Session", fraction: 1.0)])])
        guard case .resume(let plan) = verdict else {
            Issue.record("expected a plan, got \(verdict)")
            return
        }
        #expect(plan.provider == "Claude")
        #expect(plan.window == "Session")
        #expect(plan.resumesAt == now.addingTimeInterval(3600 + AutoResume.grace))
        #expect(plan.trustedReset)
        #expect(plan.attempt == 0)
        #expect(!plan.isDue(at: now))
        #expect(plan.isDue(at: plan.resumesAt))
    }

    @Test("A failure that is not a wall is not this policy's business at all")
    func ordinaryFailuresAreLeftAlone() {
        #expect(decide(failure: "connection refused", quotas: []) == .notAWall)
        #expect(decide(failure: "tool bash failed with exit 1", quotas: []) == .notAWall)
        #expect(
            decide(failure: "prompt is too long for the context window", quotas: []) == .notAWall)
    }

    @Test("A wall that never says when it opens is refused rather than guessed at")
    func aBalanceIsNotAClock() {
        let spent = quota(
            "OpenCode Go", [gauge(label: "Balance", fraction: 1.0, resetsIn: nil)])
        #expect(decide(quotas: [spent]) == .cannot(.noReset))
    }

    @Test("A reset past the horizon is not waited on silently")
    func farOutWallsAreDeclined() {
        let weekly = quota(
            "Claude", [gauge(label: "Weekly", fraction: 1.0, resetsIn: 4 * 24 * 3600)])
        guard case .cannot(.tooFarOut) = decide(quotas: [weekly]) else {
            Issue.record("expected tooFarOut")
            return
        }
    }

    @Test("The setting says so in words rather than by producing nothing")
    func turnedOffIsAnAnswer() {
        let wall = quota("Claude", [gauge(label: "Session", fraction: 1.0)])
        #expect(decide(quotas: [wall], enabled: false) == .cannot(.turnedOff))
    }

    @Test("A wall standing in front of another model is not this chat's wall")
    func scopedWallsStayScoped() {
        let opus = quota("Claude", [gauge(label: "Weekly · Opus 4.1", fraction: 1.0)])
        #expect(decide(quotas: [opus], model: "claude-sonnet-4-6") == .notAWall)
        guard case .resume = decide(quotas: [opus], model: "claude-opus-4-6") else {
            Issue.record("an Opus chat is behind an Opus wall")
            return
        }
    }

    @Test("A wall read out of the failure's own prose is a clock, spoken about as an estimate")
    func prosedResetsStillPlan() {
        let verdict = AutoResume.decide(
            row: row, profileID: "p", sessionID: "s", trigger: .refused,
            failure: "Claude usage limit reached. It will reset in 2 hours 30 minutes.",
            quotas: [], now: now)
        guard case .resume(let plan) = verdict else {
            Issue.record("expected a plan from the message's own reset")
            return
        }
        #expect(plan.resumesAt == now.addingTimeInterval(2.5 * 3600 + AutoResume.grace))
        #expect(!plan.trustedReset)
        #expect(ResumeReading.caption(plan, now: now).contains("about"))
    }

    @Test("Only a turn that produced nothing may be asked again by a clock")
    func halfAnAnswerIsNotResumed() {
        #expect(!AutoResume.mayAskAgain(nil))
        let silent = ChatMessage(
            id: "m1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .unknown(type: "step-start"))], createdAt: now,
            completedAt: now, finishReason: "unknown")
        #expect(AutoResume.mayAskAgain(silent))
        let spoke = ChatMessage(
            id: "m2", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text("half an answer"))],
            createdAt: now, completedAt: now, finishReason: "unknown")
        #expect(!AutoResume.mayAskAgain(spoke))
    }

    private func plan(attempt: Int = 0, at fires: TimeInterval = 3600) -> ResumePlan {
        ResumePlan(
            id: row, profileID: "p", sessionID: "s", provider: "Claude", window: "Session",
            resumesAt: now.addingTimeInterval(fires), trustedReset: true, trigger: .refused,
            attempt: attempt, plannedAt: now)
    }

    @Test("The window is looked at before the message goes, never assumed open")
    func recheckSendsOnlyWhenTheWallIsGone() {
        let open = quota("Claude", [gauge(label: "Session", fraction: 0.4)])
        #expect(AutoResume.recheck(plan(), quotas: [open], now: now) == .send)
        #expect(AutoResume.recheck(plan(), quotas: [], now: now) == .send)
    }

    @Test("A wall still standing with a newer reset re-plans onto it")
    func recheckFollowsTheProvider() {
        let later = quota(
            "Claude", [gauge(label: "Session", fraction: 1.0, resetsIn: 7200)])
        let fired = now.addingTimeInterval(3600)
        guard
            case .wait(let next) = AutoResume.recheck(
                plan(), quotas: [later], now: fired)
        else {
            Issue.record("expected a re-plan")
            return
        }
        #expect(next.resumesAt == now.addingTimeInterval(7200 + AutoResume.grace))
        #expect(next.attempt == 1)
        #expect(next.id == row)
    }

    @Test("A wall that refused at its own stated time falls onto the backoff")
    func recheckBacksOffWhenNothingIsLearned() {
        let stubborn = quota(
            "Claude", [gauge(label: "Session", fraction: 1.0, resetsIn: nil)])
        let fired = now.addingTimeInterval(3600)
        guard case .wait(let next) = AutoResume.recheck(plan(), quotas: [stubborn], now: fired)
        else {
            Issue.record("expected a backoff")
            return
        }
        #expect(next.resumesAt == fired.addingTimeInterval(AutoResume.backoff(attempt: 1)))
        #expect(next.attempt == 1)
    }

    @Test("The tries are bounded, and running out is a sentence")
    func attemptsAreSpent() {
        let stubborn = quota(
            "Claude", [gauge(label: "Session", fraction: 1.0, resetsIn: nil)])
        let last = plan(attempt: AutoResume.maxAttempts - 1)
        #expect(
            AutoResume.recheck(last, quotas: [stubborn], now: now.addingTimeInterval(3600))
                == .cancel(.attemptsSpent(AutoResume.maxAttempts)))
        #expect(
            ResumeReading.obstacle(.attemptsSpent(AutoResume.maxAttempts))
                .contains("still here"))
    }

    @Test("A plan nobody was awake for goes stale rather than firing late")
    func staleness() {
        let missed = plan()
        let woken = now.addingTimeInterval(3600 + AutoResume.staleAfter + 60)
        #expect(missed.isStale(at: woken))
        #expect(!missed.isStale(at: now.addingTimeInterval(3600 + 60)))
        #expect(
            AutoResume.recheck(missed, quotas: [], now: woken)
                == .cancel(.tooFarOut(missed.resumesAt)))
    }

    @Test("A ledger hands back what is due, what is stale, and one moment to wake at")
    func ledger() {
        var ledger = ResumeLedger()
        let soon = plan(at: 600)
        let later = ResumePlan(
            id: UUID(), profileID: "p", sessionID: "s", provider: "Claude", window: "Weekly",
            resumesAt: now.addingTimeInterval(3000), trustedReset: true, trigger: .refused,
            plannedAt: now.addingTimeInterval(1))
        ledger.hold(soon)
        ledger.hold(later)
        #expect(ledger.count == 2)
        #expect(ledger.nextWake(after: now) == soon.resumesAt)
        #expect(ledger.due(at: now).isEmpty)
        #expect(ledger.due(at: now.addingTimeInterval(700)).map(\.id) == [soon.id])
        let woken = now.addingTimeInterval(600 + AutoResume.staleAfter + 120)
        #expect(ledger.stale(at: woken).map(\.id) == [soon.id])
        #expect(ledger.due(at: woken).map(\.id) == [later.id])
        #expect(ledger.drop(soon.id) != nil)
        #expect(ledger.count == 1)
    }

    @Test("A conversation that keeps bouncing off the same wall runs out of tries")
    func attemptsCarryAcrossFreshFailures() {
        let wall = quota("Claude", [gauge(label: "Session", fraction: 1.0)])
        guard
            case .resume = AutoResume.decide(
                row: row, profileID: "p", sessionID: "s", trigger: .answerless, failure: nil,
                quotas: [wall], attempt: AutoResume.maxAttempts - 1, now: now)
        else {
            Issue.record("the last try is still a try")
            return
        }
        #expect(
            AutoResume.decide(
                row: row, profileID: "p", sessionID: "s", trigger: .answerless, failure: nil,
                quotas: [wall], attempt: AutoResume.maxAttempts, now: now)
                == .cannot(.attemptsSpent(AutoResume.maxAttempts)))
    }

    @Test("Every refusal has words, and none of them is a silence")
    func everyObstacleSpeaks() {
        let cases: [ResumeObstacle] = [
            .turnedOff, .noReset, .turnHadStarted, .attemptsSpent(4),
            .tooFarOut(now.addingTimeInterval(4 * 24 * 3600)),
        ]
        for obstacle in cases {
            let words = ResumeReading.obstacle(obstacle, now: now)
            #expect(words.count > 30, "\(obstacle) needs a sentence, not a label")
        }
    }

    @Test("A waiting row says what is used up, when it goes, and which try this is")
    func captions() {
        let first = ResumeReading.caption(plan(), now: now)
        #expect(first.contains("Claude"))
        #expect(first.contains("Session"))
        #expect(first.contains("1h 0m"))
        #expect(!first.contains("try"))
        let again = ResumeReading.caption(plan(attempt: 2), now: now)
        #expect(again.contains("still used up"))
        #expect(again.contains("3 of \(AutoResume.maxAttempts)"))
    }

    @Test("A wait holds perfectly still, like every other settled state")
    func stillness() {
        #expect(ResumeReading.icon.motion == .still)
        #expect(ResumeReading.icon.tone == .attention)
    }
}


/// Nested under `DeviceStores` on purpose: every device-local store shares one process, and a
/// suite that writes a file another suite reads has to be serialized against them all.
extension DeviceStores {
    @Suite("Resume store")
    struct ResumeStoreTests {
        private let now = Date(timeIntervalSince1970: 1_760_000_000)
        private let row = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

        private func fresh() {
            ResumeStore.forgetMemo()
            try? FileManager.default.removeItem(at: ResumeStore.url)
            try? FileManager.default.removeItem(at: ResumeStore.unreadableURL)
            ResumeStore.forgetMemo()
        }

        private func plan(attempt: Int = 0, at fires: TimeInterval = 3600) -> ResumePlan {
            ResumePlan(
                id: row, profileID: "p", sessionID: "s", provider: "Claude", window: "Session",
                resumesAt: now.addingTimeInterval(fires), trustedReset: true, trigger: .refused,
                attempt: attempt, plannedAt: now)
        }

        @Test("The store holds a message whole and hands it back for its own conversation")
        func store() {
            fresh()
            defer { fresh() }
            let record = ResumeRecord(
                plan: plan(), text: "run the tests",
                attachments: [PromptAttachment(mime: "image/png", filename: "shot.png")],
                model: ModelSelection(providerID: "anthropic", modelID: "claude-opus-4-6"))
            ResumeStore.hold(record)
            let held = ResumeStore.records(profileID: "p", sessionID: "s")
            #expect(held.count == 1)
            #expect(held.first?.text == "run the tests")
            #expect(held.first?.attachments.first?.filename == "shot.png")
            #expect(held.first?.queued.id == row)
            #expect(ResumeStore.records(profileID: "other", sessionID: "s").isEmpty)

            let moved = plan(attempt: 1, at: 9000)
            ResumeStore.replan(moved)
            #expect(ResumeStore.records(profileID: "p", sessionID: "s").first?.plan.attempt == 1)
            #expect(ResumeStore.records(profileID: "p", sessionID: "s").first?.text == "run the tests")

            ResumeStore.forgetMemo()
            #expect(ResumeStore.records(profileID: "p", sessionID: "s").first?.text == "run the tests")

            #expect(ResumeStore.release(row)?.text == "run the tests")
            #expect(ResumeStore.records(profileID: "p", sessionID: "s").isEmpty)
        }

        @Test("A launch sweeps what nobody was awake for and reports it rather than losing it")
        func sweep() {
            fresh()
            defer { fresh() }
            ResumeStore.hold(ResumeRecord(plan: plan(), text: "held"))
            let woken = now.addingTimeInterval(3600 + AutoResume.staleAfter + 60)
            let swept = ResumeStore.sweepStale(now: woken)
            #expect(swept.map(\.text) == ["held"])
            #expect(ResumeStore.all().isEmpty)
            #expect(ResumeReading.missed(plan(), now: woken).contains("still here"))
        }
    }
}
