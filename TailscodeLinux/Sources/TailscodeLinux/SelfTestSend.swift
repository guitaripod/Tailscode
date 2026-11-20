import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension SelfTest {
    /// The moment a message is sent: the echo is the server's row before the server has it — same
    /// rows, same air, same height, full strength from the press — a prompt not yet echoed leaves
    /// the finished turn above it closed, a send that never left waits and offers to go now, one
    /// that broke on the wire is retired when its words turn up, and a row that did not go changes
    /// its state in place rather than being rebuilt.
    static func checkSendMoment() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        MatrixTheme.install()
        var claims = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure(label) }
            claims += 1
        }
        let now = Date()
        func user(_ id: String, _ text: String) -> ChatMessage {
            ChatMessage(
                id: id, role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: "t", kind: .text(text))], createdAt: now)
        }
        func assistant(_ id: String, _ text: String) -> ChatMessage {
            ChatMessage(
                id: id, role: .assistant, agentType: .claudeCode,
                parts: [MessagePart(id: "a", kind: .text(text))], createdAt: now)
        }

        let log = (1...30).map { "12:00:\($0) worker \($0) failed to bind" }.joined(separator: "\n")
        let wrapped = PasteFold.wrap("why does this fail?", pastes: [FoldedPaste(text: log)])
        let send = PendingSend(text: wrapped, startedAt: now, baselineUserCount: 1)
        let echo = TranscriptRow.echoRows(send, plan: nil)
        let server = TranscriptRowBuilder().rows(for: [user("u1", wrapped)])
        try expect(
            echo.map(\.chatClass) == server.map(\.chatClass),
            "the echo is set as the server's rows: \(echo.map(\.chatClass)) vs \(server.map(\.chatClass))")
        let metrics = TranscriptGaps.metrics
        try expect(
            TranscriptGaps.margins(for: echo, metrics: metrics)
                == TranscriptGaps.margins(for: server, metrics: metrics),
            "the echo sits in the same air as the server's rows")
        let serverWords = server.compactMap { row -> String? in
            if case .userText(let text, _) = row.kind { return text }
            return nil
        }
        try expect(
            serverWords == [TranscriptRow.echoWords(wrapped)],
            "the echo's words are the server row's words: \(serverWords)")
        try expect(
            echo.allSatisfy { !$0.announcesArrival } && echo.allSatisfy(\.isPromptBlock),
            "nothing of the echo fades in, and all of it rises")
        let picture = TranscriptRow(
            key: "p", kind: .file(FileReference(mime: "image/png", filename: "a.png"), mine: true))
        try expect(!picture.announcesArrival, "a picture the person sent is not faded in either")

        let pictures = PendingSend(
            text: "",
            attachments: [PromptAttachment(mime: "image/png", filename: "a.png", data: Data([1]))],
            startedAt: now, baselineUserCount: 0)
        let pictureEcho = TranscriptRow.echoRows(pictures, plan: nil)
        try expect(
            pictureEcho.count == 1 && pictureEcho.allSatisfy(\.isPromptBlock),
            "a send of a picture alone is the picture and nothing under it until there is news")

        let context = TranscriptContext()
        let words = "ship the fix and tell me what broke"
        let plain = PendingSend(text: words, startedAt: now, baselineUserCount: 0)
        let echoWidget = TranscriptRow(key: "pending:x", kind: .pendingSend(plain, nil))
            .makeWidget(context: context)
        let serverWidget = TranscriptRow(key: "u:t", kind: .userText(words, messageID: "u"))
            .makeWidget(context: context)
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 640, 400)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(column, 600, -1)
        gtk_widget_set_halign(column, GTK_ALIGN_START)
        gtk_widget_set_valign(column, GTK_ALIGN_START)
        gtk_box_append(ptr(column), echoWidget)
        gtk_box_append(ptr(column), serverWidget)
        gtk_window_set_child(ptr(window), column)
        gtk_window_present(ptr(window))
        defer { gtk_window_destroy(ptr(window)) }
        _ = brainPump(5) {
            gtk_widget_get_mapped(echoWidget) != 0 && gtk_widget_get_height(echoWidget) > 4
                && gtk_widget_get_height(serverWidget) > 4
        }
        try expect(
            gtk_widget_get_height(echoWidget) == gtk_widget_get_height(serverWidget),
            "the echo is as tall as the server's row: \(gtk_widget_get_height(echoWidget)) vs \(gtk_widget_get_height(serverWidget))")
        try expect(gtk_widget_get_opacity(echoWidget) == 1, "the echo is at full strength from the press")

        var failed = plain
        failed.phase = .failed(reason: "The connection to the server dropped.")
        try expect(
            TranscriptRow.restatePending(on: echoWidget, send: failed, plan: nil, context: context),
            "a failure is stated on the row the words were written in, not on a rebuilt one")
        _ = brainPump(0.6)
        let rule = gtk_widget_get_first_child(echoWidget)
        try expect(
            rule.map { gtk_widget_has_css_class($0, "pending-rule-failed") != 0 } == true,
            "the failure takes the danger tone")
        try expect(
            gtk_widget_get_height(echoWidget) > gtk_widget_get_height(serverWidget),
            "the failure grows its line and its acts into the row")
        try expect(
            TranscriptRow.restatePending(on: echoWidget, send: plain, plan: nil, context: context),
            "a retry is the same row going back on the wire")
        _ = brainPump(0.6)
        try expect(
            gtk_widget_get_height(echoWidget) == gtk_widget_get_height(serverWidget)
                && rule.map { gtk_widget_has_css_class($0, "pending-rule-failed") == 0 } == true,
            "a retry folds the line and the acts away and takes the tone off")

        var held = plain
        held.phase = .waiting(
            reason: TransportWords.sentence(for: URLError(.notConnectedToInternet)))
        try expect(
            PendingSendReading.caption(held, now: now)?.contains("on its own") == true
                && held.acts.map { PendingSendReading.title($0, for: held) }.first == "Send now",
            "a send that never left says it goes on its own and offers to go now")

        let messages = [user("u1", "first"), assistant("a1", "Scanning.\n\n| a | b |\n|---|---|\n| 1 | 2 |")]
        try expect(
            !PendingSendLedger.turnIsOpen(running: true, messages: messages, echoBaseline: 1),
            "a prompt not in the transcript yet leaves the turn before it closed")
        try expect(
            PendingSendLedger.turnIsOpen(
                running: true, messages: messages + [user("u2", "next")], echoBaseline: 1),
            "the echo opens the turn")
        try expect(
            PendingSendLedger.turnIsOpen(running: true, messages: messages, echoBaseline: nil),
            "with nothing on its way the server's word stands")
        let closed = TranscriptRowBuilder().rows(
            state: ConversationState(messages: messages, status: .running, hasLoadedTranscript: true),
            turnOpen: false)
        try expect(
            closed.contains { if case .table = $0.kind { return true } else { return false } }
                && !closed.contains { if case .tableDraft = $0.kind { return true } else { return false } },
            "the finished answer above a prompt on its way is not rebuilt as one being written")

        var ledger = PendingSendLedger()
        let lost = ledger.begin(text: "made it after all", userMessages: 1, now: now)
        ledger.mark(id: lost.id, .failed(reason: "dropped"))
        let retired = ledger.retireArrived(
            in: [user("u1", "first"), user("u2", "made it after all")])
        try expect(
            retired.map(\.id) == [lost.id] && ledger.isEmpty,
            "a failed row whose words turn up is retired, never offered again")

        let key = LiveKey(profileID: "selftest", sessionID: "send-shelf")
        var shelved = SendShelf.Shelved()
        let kept = shelved.ledger.begin(text: "kept across a switch", userMessages: 0, now: now)
        shelved.ledger.mark(id: kept.id, .waiting(reason: "offline"))
        SendShelf.put(shelved, for: key)
        try expect(SendShelf.hasUnsent(key), "words left in a chat that was switched away from are kept")
        try expect(
            SendShelf.take(key).ledger.send(id: kept.id)?.text == "kept across a switch"
                && !SendShelf.hasUnsent(key),
            "opening the chat again takes them back")
        try checkSendAttempts(now: now, expect: expect)
        return claims
    }

    /// The attempts on the wire and the rows they belong to: nothing is posted before there is a
    /// transcript to count against, a second attempt never starts beside one on the wire and an
    /// attempt called back changes nothing, a new prompt waits behind a held one, words whose row
    /// went while their attempt was out come back when it did not go, and a held send survives the
    /// app going away.
    private static func checkSendAttempts(
        now: Date, expect: (Bool, String) throws -> Void
    ) throws {
        try expect(
            SendGate.attempt(loaded: false, busy: false) == .awaitLoad
                && SendGate.attempt(loaded: true, busy: true) == .behindTurn
                && SendGate.attempt(loaded: true, busy: false) == .post,
            "a held send waits for a transcript to load and for a turn to end before it goes")
        var unloaded = PendingSendLedger()
        let early = unloaded.begin(
            text: "written while the chat was loading", userMessages: ChatPane.unloadedBaseline,
            now: now)
        unloaded.reconcile(userMessages: 400)
        try expect(
            unloaded.send(id: early.id) != nil,
            "a send counted against no transcript is never retired by the one that loads")

        var attempts: [UUID: SendAttempt] = [:]
        let id = UUID()
        let sent = PendingSend(id: id, text: "go", startedAt: now, baselineUserCount: 2)
        let first = SendShelf.nextToken()
        attempts[id] = SendAttempt(token: first, task: Task {}, sent: sent)
        try expect(
            !SendAttempts.mayStart(attempts, id),
            "Send now while an attempt is on the wire starts nothing")
        try expect(SendShelf.nextToken() != first, "every attempt has a token of its own")
        SendAttempts.callBackAll(&attempts)
        try expect(
            attempts.isEmpty && !SendAttempts.finish(&attempts, id: id, token: first),
            "an attempt called back by Stop answers into nothing")
        let second = SendShelf.nextToken()
        attempts[id] = SendAttempt(token: second, task: Task {}, sent: sent)
        try expect(
            !SendAttempts.finish(&attempts, id: id, token: first)
                && SendAttempts.finish(&attempts, id: id, token: second) && attempts.isEmpty,
            "only the attempt registered now is answered by its outcome")
        let key = LiveKey(profileID: "selftest", sessionID: "send-attempts")
        let third = SendShelf.nextToken()
        var shelved = SendShelf.Shelved()
        shelved.ledger.begin(text: "go", userMessages: 2, now: now, id: id)
        shelved.attempts[id] = SendAttempt(token: third, task: Task {}, sent: sent)
        SendShelf.put(shelved, for: key)
        let back = SendShelf.take(key)
        try expect(
            back.attempts[id]?.token == third && !SendAttempts.mayStart(back.attempts, id),
            "an attempt still on the wire comes back with its chat, so returning sends nothing twice")

        try expect(
            SendGate.holdsNewSend(busy: false, queueEmpty: true, waitingAhead: true)
                && SendGate.holdsNewSend(busy: false, queueEmpty: false, waitingAhead: false)
                && SendGate.holdsNewSend(busy: true, queueEmpty: true, waitingAhead: false)
                && !SendGate.holdsNewSend(busy: false, queueEmpty: true, waitingAhead: false),
            "a prompt written after a held send waits behind it, and goes at once only when nothing is ahead")

        var ledger = PendingSendLedger()
        let lost = PendingSend(text: "words nobody else has", startedAt: now, baselineUserCount: 3)
        let offline = TransportWords.sentence(for: URLError(.notConnectedToInternet))
        try expect(
            SendLanding.settle(.waiting(reason: offline), of: lost, in: &ledger)
                && ledger.send(id: lost.id)?.phase == .waiting(reason: offline)
                && ledger.send(id: lost.id)?.text == "words nobody else has",
            "words whose row was retired while their attempt was out come back held")
        var again = PendingSendLedger()
        try expect(
            SendLanding.settle(.failed(reason: "refused"), of: lost, in: &again)
                && again.send(id: lost.id)?.isFailed == true,
            "and come back failed when the attempt says they did not go")
        var gone = PendingSendLedger()
        try expect(
            !SendLanding.settle(.accepted, of: lost, in: &gone) && gone.isEmpty,
            "an attempt the server took puts back nothing: its echo is coming")

        let heldKey = LiveKey(profileID: "selftest", sessionID: "held-\(UUID().uuidString)")
        let since = now.addingTimeInterval(-60)
        let held = PendingSend(text: "survives a quit", startedAt: since, baselineUserCount: 1)
        HeldSends.hold(held, key: heldKey, heldSince: since, reason: offline)
        defer { HeldSends.release(held.id) }
        try expect(
            HeldSendStore.records(profileID: heldKey.profileID, sessionID: heldKey.sessionID)
                .map(\.id) == [held.id],
            "a held send is written down the moment it starts waiting")
        let earlier = ChatMessage(
            id: "u0", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("before it"))],
            createdAt: since.addingTimeInterval(-30))
        var reopened = PendingSendLedger()
        let clocks = HeldSends.restore(heldKey, into: &reopened, messages: [earlier])
        try expect(
            clocks[held.id]?.heldSince == since
                && reopened.send(id: held.id)?.phase == .waiting(reason: offline)
                && reopened.send(id: held.id)?.baselineUserCount == 1,
            "opening the chat again puts it back, waiting, counted from when it started waiting")
        try expect(
            HeldSends.restore(heldKey, into: &reopened, messages: [earlier]).isEmpty
                && reopened.count == 1,
            "a row the chat already holds is not put back twice")
        HeldSends.release(held.id)
        try expect(
            HeldSendStore.records(profileID: heldKey.profileID, sessionID: heldKey.sessionID)
                .isEmpty,
            "and the record goes the moment it stops waiting")

        var clock = SendWaitClock(heldSince: now)
        clock.outOfReach(at: now)
        clock.reachable(at: now.addingTimeInterval(300))
        clock.outOfReach(at: now.addingTimeInterval(1000))
        try expect(
            !clock.givesUp(at: now.addingTimeInterval(1250))
                && clock.givesUp(at: now.addingTimeInterval(1301)),
            "only the time the machine was out of reach counts toward giving up")
    }
}
