import AgentTestSupport
import AppKit
import CodingAgentKit
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The send moment through a real pane with no server: the courier is a stand-in that answers as
/// the network would, so every claim is about what the pane does with an answer — drawn at full
/// strength from the press, the finished turn kept closed until the prompt lands, a send that
/// could not leave held and sent when the stream comes back, a failure retired by its own words,
/// and the queue never overtaking a row still holding words.
extension ChatChecks {
    static func runSending() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("send: \(label)") }
            checks += 1
        }
        try await pressAndEcho(expect)
        try await heldForTheConnection(expect)
        try await failureRetiredByItsWords(expect)
        try queueWaitsBehindUnsent(expect)
        try await answerAfterTheRowWasRetired(expect)
        try await heldAcrossARestart(expect)
        try await heldBehindATurn(expect)
        try await sentAgainDuringATurn(expect)
        return checks
    }

    /// A pane in a window of its own, holding a conversation it never streams from.
    @MainActor
    private final class Bench {
        let pane = TranscriptViewController()
        let window: NSWindow
        let conversation: AgentConversation
        var attempts = 0
        var answers: [@Sendable (Int) async throws -> Void] = []
        /// Whether the device has a network, as the courier asks before every attempt.
        var online = true
        /// How many times an attempt asked the server what it holds before posting.
        let rereads = Tally()

        init(entry: SessionEntry? = nil) {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled],
                backing: .buffered, defer: true)
            window.contentView = pane.view
            conversation = AgentConversation(backend: MockBackend(), sessionID: "send-check")
            pane.entry = entry
            pane.conversation = conversation
            pane.setFocusedPane(true)
            ChatChecks.windows.append(window)
        }

        /// Every attempt asks `answers` in turn: throwing is the network's failure, returning is
        /// the server taking the prompt, and an attempt with no answer left stays on the wire.
        func courier(transcript: @escaping @Sendable () -> [ChatMessage]) {
            pane.courierFactory = { [weak self] _, _ in
                let index = self?.attempts ?? 0
                self?.attempts += 1
                let answer = self.flatMap { index < $0.answers.count ? $0.answers[index] : nil }
                let online = self?.online ?? true
                let rereads = self?.rereads
                return SendCourier(
                    bound: 30, online: { online },
                    post: {
                        guard let answer else {
                            try await Task.sleep(for: .seconds(60))
                            return
                        }
                        try await answer(index)
                    },
                    reread: {
                        rereads?.bump()
                        return transcript()
                    })
            }
        }

        /// The app going away with a send held: every clock and attempt stops, and nothing the
        /// send left on disk is touched.
        func quit() {
            pane.dropAllWaits()
            for flight in pane.sendFlights.values { flight.task.cancel() }
            pane.sendFlights = [:]
            window.contentView = nil
            ChatChecks.windows.removeAll { $0 === window }
        }

        func show(_ messages: [ChatMessage], running: Bool = false, connection: ConnectionPhase = .live) {
            pane.show(
                state: ConversationState(
                    messages: messages, status: running ? .running : .idle,
                    connection: connection, hasLoadedTranscript: true))
            pane.view.layoutSubtreeIfNeeded()
        }

        var echo: PendingSendRowView? {
            guard let id = pane.pending.sends.first?.id,
                let index = pane.renderedRows.firstIndex(where: {
                    $0.key == TranscriptViewController.echoKey(id)
                }), index < pane.rowViews.count
            else { return nil }
            return pane.rowViews[index] as? PendingSendRowView
                ?? pane.rowViews[index].firstDescendant(PendingSendRowView.self)
        }

        func close() {
            pane.stopSendsInFlight()
            window.contentView = nil
            ChatChecks.windows.removeAll { $0 === window }
        }
    }

    private static func until(_ condition: @MainActor () -> Bool, seconds: Double = 4) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func prompt(_ id: String, _ text: String) -> ChatMessage {
        message(id, .user, [MessagePart(id: "p", kind: .text(text))])
    }

    private static func answer(_ id: String, _ text: String) -> ChatMessage {
        message(id, .assistant, [MessagePart(id: "t", kind: .text(text))])
    }

    private static func pressAndEcho(_ expect: (Bool, String) throws -> Void) async throws {
        let bench = Bench()
        defer { bench.close() }
        let history = [prompt("u1", "Run the suite"), answer("a1", "All green. The flaky one passed ten times in a row.")]
        bench.courier { [] }
        bench.show(history)
        bench.pane.sendPrompt("Now ship it", model: nil, effort: nil, attachments: [])
        let echo = bench.echo
        try expect(echo != nil, "the echo is a row the moment Send is pressed")
        try expect(
            echo.map { $0.inkAlpha == 1 && $0.alphaValue == 1 } ?? false,
            "and it is drawn at full strength in that same pass, never faded in")
        if let index = bench.pane.renderedRows.firstIndex(where: { $0.key.hasPrefix("echo:") }) {
            try expect(
                bench.pane.rowViews[index].alphaValue == 1,
                "its row is not handed to the entrance fade")
        }
        try expect(
            bench.pane.pending.sends.first?.phase == .sending, "the send is on its way")

        bench.show(history, running: true)
        try expect(
            !bench.pane.context.turnOpen,
            "a server that already says running leaves the finished turn closed while the prompt has not landed")
        try expect(
            bench.pane.cascade.key == nil,
            "and the finished answer above the question is not taken up to be written again")

        bench.show(history + [prompt("u2", "Now ship it")], running: true)
        try expect(bench.pane.pending.isEmpty, "the prompt landing retires the echo")
        try expect(bench.pane.context.turnOpen, "and only then is the turn open")
        try expect(
            !bench.pane.renderedRows.contains { $0.key.hasPrefix("echo:") },
            "the echo's rows give way to the server's")
    }

    private static func heldForTheConnection(_ expect: (Bool, String) throws -> Void) async throws {
        let bench = Bench()
        defer { bench.close() }
        let offline = TransportWords.sentence(for: URLError(.notConnectedToInternet))
        let history = [prompt("u1", "Start"), answer("a1", "Done.")]
        bench.answers = [
            { _ in throw AgentError.connection(offline) },
            { _ in },
        ]
        bench.courier { [] }
        bench.show(history)
        bench.pane.sendPrompt("Words written on a train", model: nil, effort: nil, attachments: [])
        await until { bench.pane.pending.sends.first?.isWaiting == true }
        try expect(
            bench.pane.pending.sends.first?.isWaiting == true,
            "a send that never left is held, not failed")
        bench.pane.redrawPending()
        let echo = bench.echo
        try expect(
            echo?.captionLine?.contains(offline) == true,
            "the held row says what stood in the way (\(echo?.captionLine ?? "nothing"))")
        try expect(
            echo?.actTitles == [
                Localized.text("Send now"), Localized.text("Edit"), Localized.text("Discard"),
            ], "and offers Send now, Edit and Discard (\(echo?.actTitles ?? []))")
        try expect(echo?.inkAlpha == 1, "a held send keeps its ink")
        if case .breath = echo?.markMotion ?? .still {
            try expect(true, "and its mark breathes")
        } else {
            try expect(false, "and its mark breathes")
        }

        bench.pane.sendPrompt("A second thought", model: nil, effort: nil, attachments: [])
        try expect(
            bench.pane.pending.count == 1,
            "a prompt written behind a held send waits behind it rather than overtaking it")

        bench.show(history, connection: .reconnecting)
        bench.show(history, connection: .live)
        await until { bench.pane.pending.sends.first?.phase == .accepted }
        try expect(bench.attempts == 2, "the stream coming back live tries the held send at once")
        try expect(
            bench.pane.pending.sends.first?.phase == .accepted,
            "and the server taking it moves the row on")
        bench.show(history + [prompt("u2", "Words written on a train")], running: true)
        try expect(bench.pane.pending.isEmpty, "the prompt landing retires the held row")
    }

    private static func failureRetiredByItsWords(_ expect: (Bool, String) throws -> Void) async throws {
        let bench = Bench()
        defer { bench.close() }
        let history = [prompt("u1", "Start"), answer("a1", "Done.")]
        bench.answers = [{ _ in throw AgentError.http(status: 500, body: "the machine hiccuped") }]
        bench.courier { [] }
        bench.show(history)
        bench.pane.sendPrompt("Did this make it?", model: nil, effort: nil, attachments: [])
        await until { bench.pane.pending.sends.first?.isFailed == true }
        try expect(bench.pane.pending.sends.first?.isFailed == true, "a refusal fails the row")
        bench.pane.redrawPending()
        try expect(
            bench.echo?.actTitles.first == Localized.text("Send again"),
            "a failed row offers Send again")
        bench.show(history + [prompt("u2", "Did this make it?")])
        try expect(
            bench.pane.pending.isEmpty,
            "a failed row whose words turn up in the transcript is retired rather than offered again")
    }

    private static func answerAfterTheRowWasRetired(
        _ expect: (Bool, String) throws -> Void
    ) async throws {
        let bench = Bench()
        defer { bench.close() }
        let offline = TransportWords.sentence(for: URLError(.notConnectedToInternet))
        let history = [prompt("u1", "Start"), answer("a1", "Done.")]
        let gate = Gate()
        bench.answers = [
            { _ in
                await gate.wait()
                throw AgentError.connection(offline)
            }
        ]
        bench.courier { [] }
        bench.show(history)
        bench.pane.sendPrompt("Words another desk overtook", model: nil, effort: nil, attachments: [])
        bench.show(history + [prompt("x1", "Written on the phone meanwhile")])
        try expect(
            bench.pane.pending.isEmpty,
            "another device's message retires an in-flight row by the count while its attempt is out")
        gate.open()
        await until { bench.pane.pending.sends.first?.isWaiting == true }
        try expect(
            bench.pane.pending.sends.first?.isWaiting == true
                && bench.pane.pending.sends.first?.text == "Words another desk overtook",
            "an answer that the words never left puts the row back, held, instead of dropping them")
    }

    private static func heldAcrossARestart(_ expect: (Bool, String) throws -> Void) async throws {
        let profileID = "selftest-send"
        let sessionID = "held-\(UUID().uuidString)"
        defer {
            for record in HeldSendStore.records(profileID: profileID, sessionID: sessionID) {
                HeldSendStore.release(record.id)
            }
        }
        let chat = SessionEntry(
            profileID: profileID, profileName: "send", host: "send", backendType: .claudeCode,
            session: AgentSession(
                id: sessionID, agentType: .claudeCode, title: "send", createdAt: Date(),
                updatedAt: Date()))
        let history = [prompt("u1", "Start"), answer("a1", "Done.")]
        let before = Bench(entry: chat)
        before.online = false
        before.courier { [] }
        before.show(history)
        before.pane.sendPrompt("Written in a lift", model: nil, effort: nil, attachments: [])
        await until { before.pane.pending.sends.first?.isWaiting == true }
        try expect(
            before.pane.pending.sends.first?.isWaiting == true,
            "a send with no network is held without being posted (\(before.attempts) courier)")
        try expect(
            HeldSendStore.records(profileID: profileID, sessionID: sessionID).map(\.text)
                == ["Written in a lift"], "and kept on disk while it waits")
        before.quit()

        let after = Bench(entry: chat)
        defer { after.close() }
        after.answers = [{ _ in }]
        after.courier { [] }
        after.show(history)
        let restored = after.pane.pending.sends.first
        try expect(
            restored?.isWaiting == true && restored?.text == "Written in a lift",
            "a fresh pane puts the held send back once the transcript has loaded")
        try expect(
            restored?.baselineUserCount == 1, "against the transcript's own count of messages")
        after.show(history, connection: .reconnecting)
        after.show(history, connection: .live)
        await until { after.pane.pending.sends.first?.phase == .accepted }
        try expect(
            after.pane.pending.sends.first?.phase == .accepted,
            "the restored send goes when the stream comes back")
        try expect(after.rereads.value >= 1, "having asked the server first")
        try expect(
            HeldSendStore.records(profileID: profileID, sessionID: sessionID).isEmpty,
            "and its copy on disk is let go once the server takes it")
    }

    private static func heldBehindATurn(_ expect: (Bool, String) throws -> Void) async throws {
        let bench = Bench()
        defer { bench.close() }
        let offline = TransportWords.sentence(for: URLError(.notConnectedToInternet))
        let history = [prompt("u1", "Start"), answer("a1", "Done.")]
        bench.answers = [{ _ in throw AgentError.connection(offline) }, { _ in }]
        bench.courier { [] }
        bench.show(history)
        bench.pane.sendPrompt("After the other desk's turn", model: nil, effort: nil, attachments: [])
        await until { bench.pane.pending.sends.first?.isWaiting == true }
        guard let id = bench.pane.pending.sends.first?.id, let held = bench.pane.sendWaits[id] else {
            try expect(false, "a send that never left is held with a clock")
            return
        }
        bench.show(history, running: true)
        bench.pane.attemptWaiting(id)
        try expect(
            TranscriptViewController.reason(of: bench.pane.pending.sends.first ?? PendingSend(
                text: "", startedAt: Date(), baselineUserCount: 0)) == SendWait.behindTurn,
            "a held send whose clock comes round during a running turn waits for the turn to end")
        try expect(bench.attempts == 1, "and nothing is posted into the running turn")
        try expect(
            bench.pane.sendWaits[id]?.attempts == held.attempts,
            "time behind a turn is not an attempt")
        try await Task.sleep(for: .milliseconds(80))
        bench.show(history + [prompt("u2", "the other desk"), answer("a2", "ok")])
        try expect(
            (bench.pane.sendWaits[id]?.heldSince ?? .distantPast) > held.heldSince,
            "nor time out of the window, which counts only time nobody could be reached")
        await until { bench.pane.pending.sends.first?.phase == .accepted }
        try expect(
            bench.pane.pending.sends.first?.phase == .accepted, "it goes when the turn ends")
    }

    private static func sentAgainDuringATurn(_ expect: (Bool, String) throws -> Void) async throws {
        let bench = Bench()
        defer { bench.close() }
        let history = [prompt("u1", "Start"), answer("a1", "Done.")]
        bench.answers = [{ _ in throw AgentError.http(status: 500, body: "busy") }, { _ in }]
        bench.courier { [] }
        bench.show(history)
        bench.pane.sendPrompt("Try this again", model: nil, effort: nil, attachments: [])
        await until { bench.pane.pending.sends.first?.isFailed == true }
        guard let id = bench.pane.pending.sends.first?.id else {
            try expect(false, "a refused send leaves a failed row")
            return
        }
        bench.pane.sendPrompt("Written after the failure", model: nil, effort: nil, attachments: [])
        try expect(
            bench.pane.pending.count == 1,
            "a message written behind a failed row queues behind it instead of going out")
        bench.show(history, running: true)
        bench.pane.actOnPending(id, .retry)
        let row = bench.pane.pending.send(id: id)
        try expect(
            row.map { TranscriptViewController.reason(of: $0) == SendWait.behindTurn } == true,
            "Send again during a running turn keeps the row where it was written, held behind the turn")
        try expect(bench.attempts == 1, "and posts nothing into the turn")
        let asked = bench.rereads.value
        bench.show(history + [prompt("u2", "the other desk"), answer("a2", "ok")])
        await until { bench.pane.pending.send(id: id)?.phase == .accepted }
        try expect(
            bench.pane.pending.send(id: id)?.phase == .accepted,
            "it goes first when the turn ends")
        try expect(bench.rereads.value > asked, "having asked the server whether it already has it")
    }

    private static func queueWaitsBehindUnsent(_ expect: (Bool, String) throws -> Void) throws {
        let idle = ConversationState(
            messages: [prompt("u1", "Start"), answer("a1", "Done.")], status: .idle,
            connection: .live, hasLoadedTranscript: true)
        var ledger = PendingSendLedger()
        try expect(
            TranscriptViewController.mayHandOutHead(
                idle, pending: ledger, editing: false, handoff: TurnHandoff()),
            "an idle conversation hands out the queue's head")
        let failed = ledger.begin(text: "did not go", userMessages: 1)
        ledger.mark(id: failed.id, .failed(reason: "no"))
        try expect(
            !TranscriptViewController.mayHandOutHead(
                idle, pending: ledger, editing: false, handoff: TurnHandoff()),
            "but not past a failed row")
        ledger.mark(id: failed.id, .waiting(reason: "offline"))
        try expect(
            !TranscriptViewController.mayHandOutHead(
                idle, pending: ledger, editing: false, handoff: TurnHandoff()),
            "nor past a send held for the connection")
        ledger.remove(id: failed.id)
        try expect(
            TranscriptViewController.mayHandOutHead(
                idle, pending: ledger, editing: false, handoff: TurnHandoff()),
            "and goes again once the row is resolved")
    }
}

/// A count several tasks may add to.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func bump() { lock.withLock { count += 1 } }
}

/// A door an attempt waits at until the check opens it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func open() { lock.withLock { opened = true } }

    func wait() async {
        while !lock.withLock({ opened }) { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

extension NSView {
    /// The first view of a type under this one, depth first.
    fileprivate func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        for child in subviews {
            if let match = child as? T { return match }
            if let match = child.firstDescendant(type) { return match }
        }
        return nil
    }
}
