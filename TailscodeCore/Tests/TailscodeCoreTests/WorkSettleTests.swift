import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("When work is over")
struct WorkSettleTests {
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static let running = WorkSettle.Reading(running: true)
    private static let idle = WorkSettle.Reading(running: false)
    private static let carrying = WorkSettle.Reading(running: false, carried: 1)

    @Test("A key first seen at rest says nothing, and one first seen working starts a span")
    func priming() {
        var settle = WorkSettle()
        #expect(settle.observe("a", Self.idle, at: Self.at(0)) == .none)
        #expect(settle.observe("b", Self.running, at: Self.at(0)) == .none)
        _ = settle.observe("a", Self.idle, at: Self.at(5))
        let ended = settle.observe("b", Self.idle, at: Self.at(30))
        #expect(ended.settling?.began == Self.at(0))
        #expect(settle.due(at: Self.at(30 + WorkSettle.grace)).map(\.key) == ["b"])
    }

    @Test("A turn that ends while background work runs is not the end of the work")
    func backgroundKeepsTheSpanOpen() {
        var settle = WorkSettle()
        _ = settle.observe("s", Self.idle, at: Self.at(0))
        _ = settle.observe("s", Self.running, at: Self.at(1))
        let turn = settle.observe("s", Self.carrying, at: Self.at(60))
        #expect(turn.turnEnded?.length == 59)
        #expect(turn.settling == nil)
        #expect(settle.due(at: Self.at(600)).isEmpty)
        _ = settle.observe("s", Self.running, at: Self.at(900))
        let done = settle.observe("s", Self.idle, at: Self.at(960))
        #expect(done.settling?.began == Self.at(1))
        #expect(done.settling?.length == 959)
        #expect(settle.due(at: Self.at(960 + WorkSettle.grace - 1)).isEmpty)
        #expect(settle.due(at: Self.at(960 + WorkSettle.grace)).count == 1)
        #expect(settle.due(at: Self.at(2000)).isEmpty)
    }

    @Test("Work that starts again inside the grace takes the ending back")
    func resumingInsideTheGrace() {
        var settle = WorkSettle()
        _ = settle.observe("s", Self.idle, at: Self.at(0))
        _ = settle.observe("s", Self.running, at: Self.at(1))
        #expect(settle.observe("s", Self.idle, at: Self.at(20)).settling != nil)
        let back = settle.observe("s", Self.running, at: Self.at(22))
        #expect(back.resumed)
        #expect(settle.due(at: Self.at(60)).isEmpty)
        let done = settle.observe("s", Self.idle, at: Self.at(80))
        #expect(done.settling?.began == Self.at(1))
    }

    @Test("A queued message and an open ask both keep the work going")
    func queuedAndWaitingAreBusy() {
        #expect(WorkSettle.Reading(running: false, queued: 1).isBusy)
        #expect(WorkSettle.Reading(running: false, waiting: true).isBusy)
        #expect(!WorkSettle.Reading(running: false, failed: true).isBusy)
    }

    @Test("A paused queue starts nothing and does not hold the work open")
    func pausedQueue() {
        var state = ConversationState(status: .idle)
        state.queue = [QueuedPrompt(id: "q", text: "next")]
        #expect(WorkSettle.Reading(state).queued == 1)
        state.queuePaused = true
        #expect(WorkSettle.Reading(state).queued == 0)
        #expect(WorkSettle.Reading(state, heldQueue: 2).queued == 2)
    }

    @Test("Messages this device holds behind a failure wait for the person, not for the work")
    func heldQueueBehindAFailure() {
        var state = ConversationState(status: .idle)
        #expect(WorkSettle.Reading(state, heldQueue: 1).queued == 1)
        state.lastFailure = BackendFailure(message: "boom")
        #expect(WorkSettle.Reading(state, heldQueue: 1).queued == 0)
    }

    @Test("Two endings owed between timer fires are both handed over")
    func twoMaturedEndings() {
        var settle = WorkSettle()
        _ = settle.observe("s", Self.idle, at: Self.at(0))
        _ = settle.observe("s", Self.running, at: Self.at(1))
        _ = settle.observe("s", Self.idle, at: Self.at(10))
        _ = settle.observe("s", Self.running, at: Self.at(30))
        _ = settle.observe("s", Self.idle, at: Self.at(40))
        _ = settle.observe("s", Self.running, at: Self.at(60))
        #expect(settle.due(at: Self.at(61)).map(\.ended) == [Self.at(10), Self.at(40)])
    }

    @Test("An ending owed while a new span began is still handed over")
    func maturedEndingsSurviveANewSpan() {
        var settle = WorkSettle()
        _ = settle.observe("s", Self.idle, at: Self.at(0))
        _ = settle.observe("s", Self.running, at: Self.at(1))
        _ = settle.observe("s", Self.idle, at: Self.at(10))
        let next = settle.observe("s", Self.running, at: Self.at(10 + WorkSettle.grace + 5))
        #expect(!next.resumed)
        let owed = settle.due(at: Self.at(30))
        #expect(owed.count == 1)
        #expect(owed.first?.ended == Self.at(10))
    }

    @Test("A failure that lands after the turn closed marks the ending failed")
    func lateFailure() {
        var settle = WorkSettle()
        _ = settle.observe("s", Self.idle, at: Self.at(0))
        _ = settle.observe("s", Self.running, at: Self.at(1))
        _ = settle.observe("s", Self.idle, at: Self.at(5))
        let failed = settle.observe(
            "s", WorkSettle.Reading(running: false, failed: true), at: Self.at(6))
        #expect(failed.settling?.failed == true)
        #expect(settle.due(at: Self.at(30)).first?.failed == true)
    }

    @Test("The next deadline is the soonest settling ending")
    func nextDue() {
        var settle = WorkSettle()
        #expect(settle.nextDue == nil)
        _ = settle.observe("a", Self.running, at: Self.at(0))
        _ = settle.observe("b", Self.running, at: Self.at(0))
        _ = settle.observe("b", Self.idle, at: Self.at(5))
        _ = settle.observe("a", Self.idle, at: Self.at(8))
        #expect(settle.nextDue == Self.at(5 + WorkSettle.grace))
    }
}

@Suite("What a person asked to hear about")
struct NoticeRulesTests {
    @Test("Finished work obeys the choice, the minimum and the mute; a failure ignores the minimum")
    func admits() {
        let rules = NoticeRules(finish: .settled, minimumWork: 120, muted: ["quiet"])
        #expect(!rules.admits(failed: false, length: 30, sessionID: "s"))
        #expect(rules.admits(failed: false, length: 300, sessionID: "s"))
        #expect(rules.admits(failed: true, length: 5, sessionID: "s"))
        #expect(!rules.admits(failed: true, length: 500, sessionID: "quiet"))
        #expect(!NoticeRules(finish: .never).admits(failed: true, length: 500, sessionID: "s"))
        let failures = NoticeRules(finish: .failures)
        #expect(!failures.admits(failed: false, length: 500, sessionID: "s"))
        #expect(failures.admits(failed: true, length: 1, sessionID: "s"))
    }

    @Test("The old switch carries over and the new keys round-trip")
    func storage() {
        #expect(NoticeRulesKeys.read { _ in nil } == .standard)
        let legacy = NoticeRulesKeys.read { $0 == NoticeRulesKeys.legacyTurnComplete ? false : nil }
        #expect(legacy.finish == .never)
        var store: [String: Any] = [:]
        let rules = NoticeRules(finish: .failures, minimumWork: 600, needsYou: false, muted: ["b", "a"])
        NoticeRulesKeys.write(rules) { store[$0] = $1 }
        #expect(store[NoticeRulesKeys.legacyTurnComplete] as? Bool == true)
        #expect(NoticeRulesKeys.read { store[$0] } == rules)
        NoticeRulesKeys.write(NoticeRules(finish: .never)) { store[$0] = $1 }
        #expect(store[NoticeRulesKeys.legacyTurnComplete] as? Bool == false)
        #expect(store[NoticeRulesKeys.muted] == nil)
    }

    @Test("A bridge is told only about the chats it holds")
    func wire() {
        let rules = NoticeRules(finish: .settled, minimumWork: 30, muted: ["x", "y"])
        let wire = rules.wire(sessionIDs: ["y", "z"])
        #expect(wire.finish == "settled")
        #expect(wire.minimumWork == 30)
        #expect(wire.muted == ["y"])
        #expect(rules.wire().muted == ["x", "y"])
    }

    @Test("Muting flips one chat")
    func toggle() {
        let rules = NoticeRules().togglingMute("s")
        #expect(rules.isMuted("s"))
        #expect(!rules.togglingMute("s").isMuted("s"))
    }
}

@Suite("The watch raises finished work once it is over")
struct ActivityWatchSettleTests {
    private static let t0 = Date(timeIntervalSince1970: 2_000_000)

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private static func state(
        _ status: BackendStatus, background: Int = 0, failure: Bool = false
    ) -> ConversationState {
        var state = ConversationState(status: status, connection: .live, hasLoadedTranscript: true)
        if background > 0 { state.backgroundWork = BackgroundWork(tasks: background) }
        if failure { state.lastFailure = BackendFailure(message: "boom") }
        return state
    }

    private static func row(_ active: Bool, carried: Int = 0, id: String = "s") -> ActivityObservation {
        ActivityObservation(
            profileID: "p", sessionID: id, title: "Chat", isActive: active, carried: carried)
    }

    private static func observe(
        _ watch: inout ActivityWatch, _ state: ConversationState, _ seconds: TimeInterval
    ) -> [ActivityAlert] {
        watch.observeConversation(
            profileID: "p", sessionID: "s", title: "Chat", state: state, at: at(seconds)
        ).alerts
    }

    @Test("A turn handing over to background work, then speaking again, notifies once at the end")
    func oneNoticeForOnePieceOfWork() {
        var watch = ActivityWatch()
        _ = Self.observe(&watch, Self.state(.idle), 0)
        _ = Self.observe(&watch, Self.state(.running), 1)
        #expect(Self.observe(&watch, Self.state(.idle, background: 2), 60).isEmpty)
        #expect(watch.due(at: Self.at(600)).isEmpty)
        #expect(watch.nextDue == nil)
        _ = Self.observe(&watch, Self.state(.running), 1200)
        #expect(Self.observe(&watch, Self.state(.idle), 1260).isEmpty)
        #expect(watch.nextDue == Self.at(1260 + WorkSettle.grace))
        let alerts = watch.due(at: Self.at(1260 + WorkSettle.grace))
        #expect(alerts.map(\.reason) == [.turnEnded])
        #expect(alerts.first?.identifier == "done:s")
    }

    @Test("Every turn means every turn, the old way")
    func everyTurn() {
        var watch = ActivityWatch(rules: NoticeRules(finish: .everyTurn))
        _ = Self.observe(&watch, Self.state(.idle), 0)
        _ = Self.observe(&watch, Self.state(.running), 1)
        #expect(Self.observe(&watch, Self.state(.idle, background: 1), 60).count == 1)
        _ = Self.observe(&watch, Self.state(.running), 70)
        #expect(Self.observe(&watch, Self.state(.idle), 80).count == 1)
        #expect(watch.due(at: Self.at(200)).isEmpty)
    }

    @Test("Short work and a muted chat end quietly; a failure still speaks")
    func minimumAndMute() {
        var watch = ActivityWatch(rules: NoticeRules(minimumWork: 120))
        _ = Self.observe(&watch, Self.state(.idle), 0)
        _ = Self.observe(&watch, Self.state(.running), 1)
        _ = Self.observe(&watch, Self.state(.idle), 31)
        #expect(watch.due(at: Self.at(60)).isEmpty)
        _ = Self.observe(&watch, Self.state(.running), 100)
        _ = Self.observe(&watch, Self.state(.idle, failure: true), 110)
        #expect(watch.due(at: Self.at(130)).map(\.reason) == [.turnFailed])

        watch.rules = NoticeRules(muted: ["s"])
        _ = Self.observe(&watch, Self.state(.running), 200)
        _ = Self.observe(&watch, Self.state(.idle), 500)
        #expect(watch.due(at: Self.at(520)).isEmpty)
    }

    @Test("A listing row holding agents is still working; the stream's quiet does not end it")
    func listingAgentsKeepItOpen() {
        var watch = ActivityWatch()
        _ = watch.observeListing([Self.row(true)], at: Self.at(0))
        _ = Self.observe(&watch, Self.state(.running), 1)
        _ = watch.observeListing([Self.row(false, carried: 2)], at: Self.at(5))
        _ = Self.observe(&watch, Self.state(.idle), 6)
        #expect(watch.due(at: Self.at(60)).isEmpty)
        _ = watch.observeListing([Self.row(false)], at: Self.at(70))
        #expect(watch.due(at: Self.at(70 + WorkSettle.grace)).count == 1)
    }

    @Test("A session only the listing sees ends from the listing, once")
    func listingOnly() {
        var watch = ActivityWatch()
        #expect(watch.observeListing([Self.row(true, id: "x")], at: Self.at(0)).isEmpty)
        _ = watch.observeListing([Self.row(false, carried: 1, id: "x")], at: Self.at(10))
        #expect(watch.due(at: Self.at(30)).isEmpty)
        _ = watch.observeListing([Self.row(false, id: "x")], at: Self.at(40))
        let alerts = watch.due(at: Self.at(40 + WorkSettle.grace))
        #expect(alerts.map(\.sessionID) == ["x"])
        #expect(alerts.first?.notice == nil)
        _ = watch.observeListing([Self.row(false, id: "x")], at: Self.at(80))
        #expect(watch.due(at: Self.at(200)).isEmpty)
    }

    @Test("Asks are raised at once unless the person turned them off")
    func asks() {
        var asking = Self.state(.running)
        asking.pendingPermissions = [
            PermissionRequest(id: "perm", sessionID: "s", title: "Run", toolName: "Bash")
        ]
        var watch = ActivityWatch(rules: NoticeRules(muted: ["s"]))
        #expect(Self.observe(&watch, asking, 0).map(\.reason) == [.needsApproval])
        var silent = ActivityWatch(rules: NoticeRules(needsYou: false))
        #expect(Self.observe(&silent, asking, 0).isEmpty)
    }

    @Test("A conversation that has not been told anything yet says nothing about the work")
    func unknownStatusIsNoReading() {
        var watch = ActivityWatch(rules: NoticeRules(finish: .everyTurn))
        _ = watch.observeListing([Self.row(true)], at: Self.at(0))
        _ = watch.observeListing([Self.row(true)], at: Self.at(1))
        #expect(Self.observe(&watch, Self.state(.unknown), 2).isEmpty)
        #expect(Self.observe(&watch, Self.state(.running), 3).isEmpty)
        #expect(Self.observe(&watch, Self.state(.idle), 60).count == 1)
    }

    @Test("A turn's words are spent by its notice and never quoted for work only the listing saw end")
    func noticeIsSpent() {
        var watch = ActivityWatch()
        _ = Self.observe(&watch, Self.state(.idle), 0)
        _ = Self.observe(&watch, Self.state(.running), 1)
        _ = Self.observe(&watch, Self.state(.idle), 30)
        #expect(watch.due(at: Self.at(40)).first?.notice != nil)
        watch.releaseConversation(profileID: "p", sessionID: "s")
        _ = watch.observeListing([Self.row(true)], at: Self.at(1000))
        _ = watch.observeListing([Self.row(false)], at: Self.at(1060))
        let later = watch.due(at: Self.at(1060 + WorkSettle.grace))
        #expect(later.count == 1)
        #expect(later.first?.notice == nil)
    }

    @Test("An ending owed long ago is history, not news")
    func lateEndingsAreDropped() {
        var watch = ActivityWatch(rules: NoticeRules(finish: .never))
        _ = Self.observe(&watch, Self.state(.idle), 0)
        _ = Self.observe(&watch, Self.state(.running), 1)
        _ = Self.observe(&watch, Self.state(.idle), 50)
        watch.rules = .standard
        #expect(watch.due(at: Self.at(3600)).isEmpty)
    }
}
