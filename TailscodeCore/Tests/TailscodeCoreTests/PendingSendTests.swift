import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The pending row is the only thing in a transcript that the server has never seen, so every
/// claim it makes is the client's own. These hold it to the two that matter: it goes away exactly
/// when the account it stood in for catches up, and a send that failed keeps its words.
@Suite("Pending sends")
struct PendingSendTests {
    private let epoch = Date(timeIntervalSince1970: 1_760_000_000)

    @Test("A message written is on its way and nothing more")
    func begins() {
        var ledger = PendingSendLedger()
        let send = ledger.begin(text: "run the tests", userMessages: 4, now: epoch)
        #expect(send.phase == .sending)
        #expect(send.isInFlight)
        #expect(send.acts.isEmpty)
        #expect(ledger.hasInFlight)
        #expect(ledger.count == 1)
    }

    @Test("The row retires when the server's account grows past it")
    func reconciles() {
        var ledger = PendingSendLedger()
        ledger.begin(text: "hello", userMessages: 2, now: epoch)
        let untouched = ledger.reconcile(userMessages: 2)
        #expect(untouched == false)
        #expect(ledger.count == 1)
        let caughtUp = ledger.reconcile(userMessages: 3)
        #expect(caughtUp)
        #expect(ledger.isEmpty)
    }

    @Test("A send the server took still stands until the transcript carries it")
    func acceptedStands() {
        var ledger = PendingSendLedger()
        let send = ledger.begin(text: "hello", userMessages: 2, now: epoch)
        let moved = ledger.mark(id: send.id, .accepted)
        #expect(moved)
        let again = ledger.mark(id: send.id, .accepted)
        #expect(again == false)
        let held = ledger.reconcile(userMessages: 2)
        #expect(held == false)
        #expect(ledger.send(id: send.id)?.phase == .accepted)
    }

    @Test("A failed send is never swept away by somebody else's message")
    func failureSurvivesReconcile() {
        var ledger = PendingSendLedger()
        let lost = ledger.begin(text: "the words nobody else has", userMessages: 1, now: epoch)
        ledger.mark(id: lost.id, .failed(reason: "the server didn't answer"))
        let swept = ledger.reconcile(userMessages: 9)
        #expect(swept == false)
        #expect(ledger.send(id: lost.id)?.text == "the words nobody else has")
        #expect(ledger.hasInFlight == false)
    }

    @Test("Sending again is the same row, with a fresh clock and a fresh baseline")
    func restarts() {
        var ledger = PendingSendLedger()
        let send = ledger.begin(text: "again", userMessages: 1, now: epoch)
        ledger.mark(id: send.id, .failed(reason: "offline"))
        let restarted = ledger.restart(id: send.id, userMessages: 3, now: epoch.addingTimeInterval(60))
        #expect(restarted?.id == send.id)
        #expect(ledger.count == 1)
        #expect(restarted?.phase == .sending)
        #expect(restarted?.baselineUserCount == 3)
        #expect(restarted?.startedAt == epoch.addingTimeInterval(60))
        let early = ledger.reconcile(userMessages: 3)
        #expect(early == false)
        let retired = ledger.reconcile(userMessages: 4)
        #expect(retired)
    }

    @Test("A failed row offers the words back three ways; an in-flight one offers nothing")
    func acts() {
        var ledger = PendingSendLedger()
        let send = ledger.begin(text: "x", userMessages: 0, now: epoch)
        #expect(ledger.send(id: send.id)?.acts == [])
        ledger.mark(id: send.id, .failed(reason: "no"))
        #expect(ledger.send(id: send.id)?.acts == [.retry, .edit, .discard])
    }

    @Test("Only a send still on the wire moves")
    func motionFollowsTheDoctrine() {
        let sending = PendingSend(text: "a", startedAt: epoch, baselineUserCount: 0)
        var accepted = sending
        accepted.phase = .accepted
        var failed = sending
        failed.phase = .failed(reason: "no")
        #expect(PendingSendReading.motion(sending) != .still)
        #expect(PendingSendReading.motion(accepted) == .still)
        #expect(PendingSendReading.motion(failed) == .still)
        #expect(PendingSendReading.tone(sending) == .live)
        #expect(PendingSendReading.tone(accepted) == .quiet)
        #expect(PendingSendReading.tone(failed) == .danger)
    }

    @Test("The wait is admitted rather than hidden")
    func slowWaitSpeaks() {
        let send = PendingSend(text: "a", startedAt: epoch, baselineUserCount: 0)
        let quick = PendingSendReading.caption(send, now: epoch.addingTimeInterval(1))
        let slow = PendingSendReading.caption(
            send, now: epoch.addingTimeInterval(PendingSendReading.slowAfter + 1))
        #expect(quick == nil)
        #expect(slow != nil)
        #expect(PendingSendReading.ink(send) == .faint)
        #expect(PendingSendReading.ink(send).opacity < 1)
        #expect(
            PendingSendReading.nextCaptionChange(send, now: epoch)
                == epoch.addingTimeInterval(PendingSendReading.slowAfter))
        var accepted = send
        accepted.phase = .accepted
        #expect(PendingSendReading.ink(accepted) == .full)
        #expect(PendingSendReading.badge(accepted) == nil)
        #expect(PendingSendReading.caption(accepted, now: epoch.addingTimeInterval(1)) == nil)
        #expect(
            PendingSendReading.caption(
                accepted, now: epoch.addingTimeInterval(PendingSendReading.quietAfter + 1)) != nil)
        #expect(PendingSendReading.state(accepted, now: epoch) == "Sent")
    }

    @Test("A failure says what the server said")
    func failureQuotesTheReason() {
        var send = PendingSend(text: "a", startedAt: epoch, baselineUserCount: 0)
        send.phase = .failed(reason: "The server didn't respond")
        #expect(PendingSendReading.caption(send, now: epoch)?.contains("The server didn't respond") == true)
        #expect(PendingSendReading.ink(send) == .failed)
        #expect(PendingSendReading.badge(send) != nil)
        send.phase = .failed(reason: "   ")
        #expect(PendingSendReading.caption(send, now: epoch) == "Not sent")
    }

    @Test("A screen reader hears the words and what became of them")
    func spoken() {
        var send = PendingSend(
            text: "look at this",
            attachments: [PromptAttachment(mime: "image/png", filename: "a.png")],
            startedAt: epoch, baselineUserCount: 0)
        send.phase = .failed(reason: "offline")
        let spoken = PendingSendReading.spoken(send, now: epoch)
        #expect(spoken.contains("look at this"))
        #expect(spoken.contains("offline"))
        #expect(spoken.contains("picture"))
    }

    @Test("A held queue does not read as a waiting one")
    func heldQueueSpeaks() {
        #expect(SendQueueReading.heldBadge != SendQueueReading.badge)
        #expect(SendQueueReading.heldHint(reason: "the tunnel dropped").contains("the tunnel dropped"))
        #expect(!SendQueueReading.heldHint(reason: nil).isEmpty)
        #expect(!SendQueueReading.heldHint(reason: "  ").contains("  ."))
    }
}

@Suite("Fresh canvas")
struct FreshCanvasTests {
    @Test("A prompt gets the room it needs and no more")
    func padding() {
        #expect(FreshCanvas.padding(viewport: 800, prompt: 60, below: 0) == 800 - 12 - 60)
        #expect(FreshCanvas.padding(viewport: 800, prompt: 60, below: 740) == 0)
        #expect(FreshCanvas.holds(viewport: 800, prompt: 60, below: 300))
        #expect(!FreshCanvas.holds(viewport: 800, prompt: 60, below: 900))
    }

    @Test("The offset lands the prompt at the top and never past the end")
    func offset() {
        #expect(FreshCanvas.offset(promptTop: 5000, contentHeight: 5800, viewport: 800) == 4988)
        #expect(FreshCanvas.offset(promptTop: 5000, contentHeight: 5200, viewport: 800) == 4400)
        #expect(FreshCanvas.offset(promptTop: 0, contentHeight: 100, viewport: 800) == 0)
    }
}
