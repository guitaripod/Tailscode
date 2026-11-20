import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A send is one attempt read three ways, and these hold each reading to what the server could
/// have: a send that never left waits and goes again on its own, one that broke on the wire is
/// asked of the transcript before it is called a failure, and a refusal keeps the server's words.
@Suite("Send courier")
struct SendCourierTests {
    private let epoch = Date(timeIntervalSince1970: 1_760_000_000)

    private func user(_ text: String, files: Int = 0, id: String = UUID().uuidString) -> ChatMessage {
        var parts = text.isEmpty ? [] : [MessagePart(id: "t", kind: .text(text))]
        for index in 0..<files {
            parts.append(
                MessagePart(
                    id: "f\(index)",
                    kind: .file(FileReference(mime: "image/png", filename: "p\(index).png"))))
        }
        return ChatMessage(id: id, role: .user, agentType: .claudeCode, parts: parts, createdAt: epoch)
    }

    @Test("An offline device and an address nobody answers at never left")
    func neverLeft() {
        for code in [URLError.Code.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost] {
            let sentence = TransportWords.sentence(for: URLError(code))
            #expect(SendFailure.read(AgentError.connection(sentence)) == .neverLeft(reason: sentence))
            #expect(SendFailure.read(URLError(code)) == .neverLeft(reason: sentence))
        }
    }

    @Test("A dropped connection and a timeout might have landed")
    func uncertain() {
        for code in [URLError.Code.networkConnectionLost, .timedOut] {
            let sentence = TransportWords.sentence(for: URLError(code))
            #expect(SendFailure.read(AgentError.connection(sentence)) == .uncertain(reason: sentence))
        }
        if case .uncertain = SendFailure.read(SendBound.Expired()) {} else {
            Issue.record("an expired bound must be uncertain")
        }
    }

    @Test("A server that answered refused in its own words, and a cancellation is nobody's failure")
    func refusedAndCancelled() {
        if case .refused = SendFailure.read(AgentError.http(status: 409, body: "busy")) {} else {
            Issue.record("an HTTP refusal must read as refused")
        }
        #expect(SendFailure.read(CancellationError()) == nil)
        #expect(SendFailure.read(URLError(.cancelled)) == nil)
    }

    @Test("The bound never undercuts the transport, and pictures buy time")
    func bound() {
        #expect(SendBound.seconds(payloadBytes: 0) >= 30)
        #expect(SendBound.seconds(payloadBytes: 500_000) == SendBound.floor + 10)
    }

    @Test("A held send is tried again soon, then every half minute, and given up after the window")
    func waitClock() {
        #expect(SendWait.delay(afterAttempts: 1) == 2)
        #expect(SendWait.delay(afterAttempts: 2) == 4)
        #expect(SendWait.delay(afterAttempts: 40) == 30)
        #expect(!SendWait.givesUp(heldSince: epoch, now: epoch.addingTimeInterval(599)))
        #expect(SendWait.givesUp(heldSince: epoch, now: epoch.addingTimeInterval(600)))
        #expect(SendWait.gaveUp("This device is offline.").contains("This device is offline."))
    }

    @Test("A post the server answers is accepted")
    func accepted() async {
        let courier = SendCourier(bound: 5, post: {}, reread: { [] })
        #expect(await courier.run(text: "hi", attachments: 0, baselineUserCount: 0) == .accepted)
    }

    @Test("A post that never left waits instead of failing")
    func waits() async {
        let offline = TransportWords.sentence(for: URLError(.notConnectedToInternet))
        let courier = SendCourier(
            bound: 5, post: { throw AgentError.connection(offline) }, reread: { [] })
        #expect(
            await courier.run(text: "hi", attachments: 0, baselineUserCount: 0)
                == .waiting(reason: offline))
    }

    @Test("A post that broke on the wire but landed is not a failure")
    func uncertainButArrived() async {
        let dropped = TransportWords.sentence(for: URLError(.networkConnectionLost))
        let courier = SendCourier(
            bound: 5, post: { throw AgentError.connection(dropped) },
            reread: { [user("older"), user("ship it")] })
        #expect(await courier.run(text: "ship it", attachments: 0, baselineUserCount: 1) == .arrived)
    }

    @Test("A post that broke on the wire and did not land fails with the transport's sentence")
    func uncertainAndMissing() async {
        let dropped = TransportWords.sentence(for: URLError(.networkConnectionLost))
        let courier = SendCourier(
            bound: 5, post: { throw AgentError.connection(dropped) },
            reread: { [user("ship it")] })
        #expect(
            await courier.run(text: "ship it", attachments: 0, baselineUserCount: 1)
                == .failed(reason: dropped))
    }

    @Test("A post that outlives the bound is checked rather than cancelled into a failure")
    func expiredButArrived() async {
        let courier = SendCourier(
            bound: 0.05,
            post: { try await Task.sleep(nanoseconds: 2_000_000_000) },
            reread: { [user("slow link")] })
        #expect(await courier.run(text: "slow link", attachments: 0, baselineUserCount: 0) == .arrived)
    }

    @Test("Send again asks the transcript first and never posts words the server has")
    func checkFirst() async {
        let posted = Counter()
        let courier = SendCourier(
            bound: 5, post: { posted.bump() }, reread: { [user("again")] })
        #expect(
            await courier.run(text: "again", attachments: 0, baselineUserCount: 0, checkFirst: true)
                == .arrived)
        #expect(posted.value == 0)
        #expect(
            await courier.run(text: "again", attachments: 0, baselineUserCount: 1, checkFirst: true)
                == .accepted)
        #expect(posted.value == 1)
    }

    @Test("A device with no network holds the send without posting it")
    func offlineHoldsBeforePosting() async {
        let posted = Counter()
        let courier = SendCourier(
            bound: 5, online: { false }, post: { posted.bump() }, reread: { [] })
        #expect(
            await courier.run(text: "hi", attachments: 0, baselineUserCount: 0)
                == .waiting(reason: DevicePath.offlineReason))
        #expect(posted.value == 0)
    }

    @Test("A send that broke on the wire with the server out of reach is held, not failed")
    func uncertainAndUnreachable() async {
        let dropped = TransportWords.sentence(for: URLError(.networkConnectionLost))
        let refused = TransportWords.sentence(for: URLError(.cannotConnectToHost))
        let courier = SendCourier(
            bound: 5, post: { throw AgentError.connection(dropped) },
            reread: { () async throws -> [ChatMessage] in throw AgentError.connection(refused) })
        #expect(
            await courier.run(text: "x", attachments: 0, baselineUserCount: 0)
                == .waiting(reason: dropped))
    }

    @Test("Sending again with the server out of reach holds rather than posting blind")
    func checkFirstUnreachable() async {
        let posted = Counter()
        let courier = SendCourier(
            bound: 5, rereadBound: 0.05, post: { posted.bump() },
            reread: { () async throws -> [ChatMessage] in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return []
            })
        let outcome = await courier.run(
            text: "again", attachments: 0, baselineUserCount: 0, checkFirst: true)
        if case .waiting = outcome {} else { Issue.record("expected a held send, got \(outcome)") }
        #expect(posted.value == 0)
    }

    @Test("Words the server is holding in its queue have arrived")
    func queuedCounts() async {
        let posted = Counter()
        let courier = SendCourier(
            bound: 5, post: { posted.bump() },
            reread: { SendAccount(messages: [], queued: ["  behind the turn "]) })
        #expect(
            await courier.run(
                text: "behind the turn", attachments: 0, baselineUserCount: 0, checkFirst: true)
                == .arrived)
        #expect(posted.value == 0)
    }

    @Test("Pictures sent without words are found by their files")
    func picturesArrive() {
        let messages = [user("before"), user("", files: 2)]
        #expect(SendArrival.arrived("", attachments: 2, baselineUserCount: 1, in: messages))
        #expect(!SendArrival.arrived("", attachments: 1, baselineUserCount: 1, in: messages))
        #expect(!SendArrival.arrived("", attachments: 2, baselineUserCount: 2, in: messages))
        #expect(!SendArrival.arrived("", attachments: 0, baselineUserCount: 0, in: messages))
    }
}

/// Until the prompt a device sent is in the transcript, the turn the server calls running is not
/// the transcript's last one, and nothing about that last turn may be drawn as open.
@Suite("Pending sends and the open turn")
struct PendingSendTurnTests {
    private let epoch = Date(timeIntervalSince1970: 1_760_000_000)

    @Test("A prompt not yet echoed keeps the finished turn closed")
    func echoClosesTheGap() {
        var ledger = PendingSendLedger()
        #expect(ledger.turnIsOpen(running: true))
        let send = ledger.begin(text: "next", userMessages: 3, now: epoch)
        #expect(ledger.awaitsEcho)
        #expect(!ledger.turnIsOpen(running: true))
        ledger.mark(id: send.id, .accepted)
        #expect(!ledger.turnIsOpen(running: true))
        ledger.reconcile(userMessages: 4)
        #expect(ledger.turnIsOpen(running: true))
        #expect(!ledger.turnIsOpen(running: false))
    }

    @Test("A row build away from the ledger reads the same open turn from the echo baseline")
    func echoBaselineReading() {
        var ledger = PendingSendLedger()
        #expect(ledger.echoBaseline == nil)
        ledger.begin(text: "a", userMessages: 2, now: epoch)
        let held = ledger.begin(text: "b", userMessages: 3, now: epoch)
        ledger.mark(id: held.id, .waiting(reason: "offline"))
        #expect(ledger.echoBaseline == 2)
        let user = ChatMessage(id: "u", role: .user, agentType: .claudeCode, createdAt: epoch)
        let two = [user, user]
        let three = [user, user, user]
        #expect(!PendingSendLedger.turnIsOpen(running: true, messages: two, echoBaseline: 2))
        #expect(PendingSendLedger.turnIsOpen(running: true, messages: three, echoBaseline: 2))
        #expect(PendingSendLedger.turnIsOpen(running: true, messages: two, echoBaseline: nil))
        #expect(!PendingSendLedger.turnIsOpen(running: false, messages: three, echoBaseline: nil))
    }

    @Test("A send waiting for the connection is held, not in flight, and survives other messages")
    func waitingIsHeld() {
        var ledger = PendingSendLedger()
        let send = ledger.begin(text: "offline words", userMessages: 1, now: epoch)
        ledger.mark(id: send.id, .waiting(reason: "This device is offline."))
        let held = ledger.send(id: send.id)
        #expect(held?.isWaiting == true)
        #expect(held?.isInFlight == false)
        #expect(held?.isUnsent == true)
        #expect(held?.acts == [.retry, .edit, .discard])
        #expect(!ledger.awaitsEcho)
        #expect(ledger.hasUnsent)
        #expect(ledger.reconcile(userMessages: 5) == false)
        #expect(ledger.waiting.map(\.id) == [send.id])
    }

    @Test("A held send says it will go on its own, breathes, and keeps its ink")
    func waitingReads() {
        var send = PendingSend(text: "a", startedAt: epoch, baselineUserCount: 0)
        send.phase = .waiting(reason: "This device is offline.")
        #expect(PendingSendReading.ink(send) == .full)
        #expect(PendingSendReading.motion(send) != .still)
        #expect(PendingSendReading.caption(send, now: epoch)?.contains("This device is offline.") == true)
        #expect(PendingSendReading.badge(send) != nil)
        #expect(PendingSendReading.nextCaptionChange(send, now: epoch) == nil)
        #expect(PendingSendReading.title(.retry, for: send) == "Send now")
        var failed = send
        failed.phase = .failed(reason: "no")
        #expect(PendingSendReading.title(.retry, for: failed) == "Send again")
    }

    @Test("Stop takes what is on its way and leaves the words nobody else has")
    func stopKeepsUnsent() {
        var ledger = PendingSendLedger()
        let lost = ledger.begin(text: "failed earlier", userMessages: 0, now: epoch)
        ledger.mark(id: lost.id, .failed(reason: "no"))
        let held = ledger.begin(text: "held", userMessages: 0, now: epoch)
        ledger.mark(id: held.id, .waiting(reason: "offline"))
        let flying = ledger.begin(text: "on the wire", userMessages: 0, now: epoch)
        let gone = ledger.removeInFlight()
        #expect(gone.map(\.id) == [flying.id])
        #expect(ledger.sends.map(\.id) == [lost.id, held.id])
    }

    @Test("A send the server took that the transcript never shows is witnessed after a while")
    func witness() {
        var ledger = PendingSendLedger()
        let send = ledger.begin(text: "x", userMessages: 0, now: epoch)
        #expect(ledger.unwitnessed(now: epoch.addingTimeInterval(60)).isEmpty)
        ledger.mark(id: send.id, .accepted)
        #expect(ledger.unwitnessed(now: epoch.addingTimeInterval(SendWitness.after - 1)).isEmpty)
        #expect(ledger.unwitnessed(now: epoch.addingTimeInterval(SendWitness.after)).map(\.id) == [send.id])
    }

    @Test("Held and failed rows retire when the transcript shows them, pictures alone included")
    func retiresFromMessages() {
        var ledger = PendingSendLedger()
        let words = ledger.begin(text: "made it", userMessages: 1, now: epoch)
        ledger.mark(id: words.id, .waiting(reason: "offline"))
        let pictures = ledger.begin(
            text: "",
            attachments: [
                PromptAttachment(mime: "image/png", filename: "a.png", data: Data([1]))
            ], userMessages: 1, now: epoch)
        ledger.mark(id: pictures.id, .failed(reason: "dropped"))
        let flying = ledger.begin(text: "still going", userMessages: 1, now: epoch)
        let messages = [
            ChatMessage(
                id: "u0", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text("first"))], createdAt: epoch),
            ChatMessage(
                id: "u1", role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text("made it"))], createdAt: epoch),
            ChatMessage(
                id: "u2", role: .user, agentType: .claudeCode,
                parts: [
                    MessagePart(
                        id: "f", kind: .file(FileReference(mime: "image/png", filename: "a.png")))
                ], createdAt: epoch),
        ]
        let retired = ledger.retireArrived(in: messages)
        #expect(Set(retired.map(\.id)) == [words.id, pictures.id])
        #expect(ledger.sends.map(\.id) == [flying.id])
        #expect(ledger.retireArrived(in: messages).isEmpty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func bump() { lock.withLock { count += 1 } }
}

@Suite("Rise spring")
struct RiseSpringTests {
    @Test("The rise starts still, ends where it is going, and never overshoots past a hair")
    func shape() {
        #expect(FreshCanvas.rise(at: 0) == 0)
        #expect(FreshCanvas.rise(at: FreshCanvas.riseDuration) == 1)
        #expect(FreshCanvas.riseDuration > 0.4 && FreshCanvas.riseDuration < 0.8)
        var previous = 0.0
        var peak = 0.0
        for step in 1...60 {
            let value = FreshCanvas.rise(at: Double(step) / 60 * FreshCanvas.riseDuration)
            peak = max(peak, value)
            if value < 0.99 { #expect(value >= previous) }
            previous = value
        }
        #expect(peak <= 1.005)
        #expect(FreshCanvas.rise(at: 0.25) > 0.8)
    }
}

@Suite("Held sends", .serialized)
struct HeldSendStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_760_000_000)

    @Test("A held send survives a restart and comes back as the row it was")
    func survivesRestart() {
        HeldSendStore.removeAll()
        defer { HeldSendStore.removeAll() }
        var ledger = PendingSendLedger()
        let send = ledger.begin(text: "offline words", userMessages: 2, now: epoch)
        HeldSendStore.hold(
            HeldSend(
                send, profileID: "p", sessionID: "s", heldSince: epoch,
                reason: "This device is offline."))
        HeldSendStore.hold(
            HeldSend(
                send, profileID: "p", sessionID: "s", heldSince: epoch.addingTimeInterval(30),
                reason: "This device is offline."))
        HeldSendStore.forgetMemo()
        let held = HeldSendStore.records(profileID: "p", sessionID: "s")
        #expect(held.count == 1)
        #expect(held.first?.heldSince == epoch)
        #expect(HeldSendStore.records(profileID: "p", sessionID: "other").isEmpty)
        guard let record = held.first else { return }
        var restored = PendingSendLedger()
        let row = restored.restore(record, userMessages: 5)
        #expect(row?.id == send.id)
        #expect(row?.isWaiting == true)
        #expect(row?.baselineUserCount == 2)
        let again = restored.restore(record, userMessages: 5)
        #expect(again == nil)
        HeldSendStore.release(send.id)
        HeldSendStore.forgetMemo()
        #expect(HeldSendStore.records(profileID: "p", sessionID: "s").isEmpty)
    }

    @Test("A send retired while its attempt was out comes back when the answer says it never went")
    func reinstates() {
        var ledger = PendingSendLedger()
        let send = ledger.begin(text: "slow", userMessages: 4, now: epoch)
        ledger.reconcile(userMessages: 5)
        #expect(ledger.isEmpty)
        let first = ledger.reinstate(send, as: .failed(reason: "dropped"))
        #expect(first)
        #expect(ledger.send(id: send.id)?.isFailed == true)
        #expect(ledger.send(id: send.id)?.baselineUserCount == 4)
        let second = ledger.reinstate(send, as: .failed(reason: "dropped"))
        #expect(!second)
    }

    @Test("A send waiting behind a running turn says so whole")
    func behindTurnReads() {
        var send = PendingSend(text: "a", startedAt: epoch, baselineUserCount: 0)
        send.phase = .waiting(reason: SendWait.behindTurn)
        #expect(PendingSendReading.caption(send, now: epoch) == SendWait.behindTurn)
    }
}

