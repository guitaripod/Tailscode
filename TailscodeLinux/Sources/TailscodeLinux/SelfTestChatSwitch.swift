import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

private final class PaintProbe: @unchecked Sendable {
    weak var pane: ChatPane?
    var armed = false
    var worst = 0.0
    var frames = 0

    func sample() {
        guard armed, let pane, let scroller = pane.transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)),
            gtk_widget_get_opacity(pane.transcriptBox) >= 1, pane.followsBottom
        else { return }
        let distance =
            gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
            - gtk_adjustment_get_value(adjustment)
        worst = max(worst, abs(distance))
        frames += 1
    }
}

extension SelfTest {
    /// What a switch to another chat promises: a message is drawn once for every pane and every
    /// chat the window shows lately, a chat opened ahead of its click has its messages drawn, the
    /// first screen of a long transcript is shown as soon as it covers the page while the rest of
    /// the history arrives above it without moving a row, and a conversation that has not read
    /// anything yet does not wipe the page it opens on.
    static func checkChatSwitch() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("chat switch: \(label)") }
            checks += 1
        }
        try checkRowMemo(expect)
        guard gtk_init_check() != 0 else { return checks }
        Gtk.installStyle()
        try checkSwitchedPage(expect)
        return checks
    }

    private static func switchMessage(_ id: String, at seconds: Double) -> ChatMessage {
        let selection = ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5")
        return ChatMessage(
            id: id, role: .assistant, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: id, kind: .note(TranscriptNote(.model(selection, effort: nil, previous: nil))))
            ],
            createdAt: Date(timeIntervalSince1970: seconds))
    }

    private static func checkRowMemo(_ expect: (Bool, String) throws -> Void) throws {
        var asked = 0
        let name: (ModelSelection) -> String? = { _ in
            asked += 1
            return nil
        }
        let id = "memo-\(UUID().uuidString)"
        let original = switchMessage(id, at: 1_780_000_000)
        _ = TranscriptRowBuilder().rows(for: [original], modelName: name)
        try expect(asked == 1, "a message is drawn once")
        _ = TranscriptRowBuilder().rows(for: [original], modelName: name)
        try expect(asked == 1, "and the next pane to show it draws nothing for it")

        let other = switchMessage("memo-\(UUID().uuidString)", at: 1_780_000_100)
        TranscriptRowBuilder.warm([other], turnOpen: false, modelName: name)
        try expect(asked == 2, "a chat warmed ahead of its opening has its messages drawn then")
        _ = TranscriptRowBuilder().rows(for: [original, other], modelName: name)
        try expect(asked == 2, "and the pane that opens it draws none of them")
        _ = TranscriptRowBuilder().rows(for: [switchMessage(id, at: 1_780_000_999)], modelName: name)
        try expect(asked == 3, "a message that is not the one that was drawn is drawn again")

        let memo = RowMemo()
        let capacity = RowMemo.capacity
        let total = capacity + capacity / 5 + 5
        let messages = (0..<total).map { switchMessage("cap-\($0)", at: Double($0)) }
        for message in messages {
            memo.store([], for: message, sealed: true, look: "a")
        }
        try expect(memo.count <= capacity + capacity / 5, "the memo keeps a bounded number of messages")
        try expect(
            memo.rows(for: messages[total - 1], sealed: true, look: "a") != nil,
            "and keeps the newest")
        try expect(
            memo.rows(for: messages[0], sealed: true, look: "a") == nil, "and lets the oldest go")
        try expect(
            memo.rows(for: messages[total - 1], sealed: true, look: "b") == nil,
            "a message drawn in another look is not reused")
        _ = MemoryRelief.shared.relieve(.half)
        try expect(memo.count <= capacity / 2, "relief at the strained level halves it")
        _ = MemoryRelief.shared.relieve(.all)
        try expect(memo.count == 0, "and at the critical level empties it")
    }

    private static func checkSwitchedPage(_ expect: (Bool, String) throws -> Void) throws {
        tailscode_set_animations_enabled(0)
        let host = MainWindow()
        let tile = TileHost(host: host)
        host.installTiling(tile)
        defer { Seatbelts.shared.onDecision = nil }
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 1000, 900)
        gtk_window_set_child(ptr(window), tile.container)
        gtk_window_present(ptr(window))
        let layout = SplitEven.layout(count: 2, as: .sideBySide)!
        _ = tile.restore(SplitSnapshot(layout: layout, contents: [:]))
        for pane in tile.orderedPanes { pane.kindOverride = .chat }
        _ = brainPump(4, until: { Int32(tile.canvas.size.width) == 1000 })
        _ = brainPump(0.3)
        guard let pane = tile.orderedPanes.first else { throw SelfTestFailure("chat switch: no pane") }
        pane.detachStreamForScript()

        let sentence =
            "A line of the answer that wraps more than once at this width, so that a row is not one line of its own. "
        let messages = (0..<300).map { index -> ChatMessage in
            ChatMessage(
                id: "sw-\(index)", role: index % 6 == 0 ? .user : .assistant,
                agentType: .claudeCode,
                parts: [
                    MessagePart(
                        id: "sw-\(index)-t",
                        kind: .text("Message \(index). " + String(repeating: sentence, count: 3)))
                ],
                createdAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index)))
        }
        let state = ConversationState(
            messages: messages, status: .idle, connection: .live, hasLoadedTranscript: true)
        let rows = pane.rowBuilder.rows(state: state)

        let probe = PaintProbe()
        probe.pane = pane
        if let clock = gtk_widget_get_frame_clock(pane.root) {
            Gtk.connect(UnsafeMutableRawPointer(clock), "paint") { probe.sample() }
        }
        probe.armed = true

        pane.apply(state: state, rows: rows)
        try expect(
            pane.renderedRows.count <= 32 && !pane.renderedRows.isEmpty,
            "the first apply draws a screen's worth of a long chat, not the window")
        try expect(
            gtk_widget_get_opacity(pane.transcriptBox) < 1,
            "and the page is kept back while that is not yet a page")

        var drawnAtReveal = 0
        let revealed = brainPump(
            6,
            until: {
                guard gtk_widget_get_opacity(pane.transcriptBox) >= 1 else { return false }
                drawnAtReveal = pane.renderedRows.count
                return true
            })
        try expect(revealed, "the page is shown")
        try expect(
            drawnAtReveal < rows.count,
            "before the whole history is drawn (\(drawnAtReveal) of \(rows.count))")

        let complete = brainPump(30, until: { pane.renderedRows.count >= rows.count })
        _ = brainPump(0.4)
        probe.armed = false
        try expect(complete, "and the history then arrives in full (\(pane.renderedRows.count))")
        try expect(
            probe.frames >= 3, "the arrival was painted over several frames (\(probe.frames))")
        try expect(
            probe.worst <= 3,
            "without the end of the chat leaving the bottom of the page (worst \(probe.worst) px)")

        let shown = pane.renderedRows.count
        pane.apply(state: ConversationState(), rows: [])
        try expect(
            pane.renderedRows.count == shown && gtk_widget_get_opacity(pane.transcriptBox) >= 1,
            "a conversation that has read nothing yet leaves the page as it is")
        pane.apply(
            state: ConversationState(status: .idle, connection: .live, hasLoadedTranscript: true),
            rows: [])
        try expect(
            pane.renderedRows.isEmpty, "while a chat that loaded and has nothing in it says so")
        gtk_window_destroy(ptr(window))
        withExtendedLifetime(host) {}
    }
}
