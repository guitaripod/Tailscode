import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the side buttons of a mouse promise, on the real window with no server: the chats a pane
    /// opens are its trail, a step is drawn once the queued events are done and not before, a burst of
    /// steps lands on the chat it ended on, Forward walks back what Back walked, a chat that is
    /// shown in another pane is stepped over, and a deleted chat leaves the trail.
    static func checkChatTrail() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("chat trail: \(label)") }
            checks += 1
        }
        guard gtk_init_check() != 0 else { return checks }
        Gtk.installStyle()
        tailscode_set_animations_enabled(0)

        let host = MainWindow()
        let tile = TileHost(host: host)
        host.installTiling(tile)
        defer { Seatbelts.shared.onDecision = nil }
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 1000, 700)
        gtk_window_set_child(ptr(window), tile.container)
        gtk_window_present(ptr(window))
        let layout = SplitEven.layout(count: 2, as: .sideBySide)!
        _ = tile.restore(SplitSnapshot(layout: layout, contents: [:]))
        for pane in tile.orderedPanes { pane.kindOverride = .chat }
        _ = brainPump(4, until: { Int32(tile.canvas.size.width) == 1000 })
        guard tile.orderedPanes.count == 2 else { throw SelfTestFailure("chat trail: no panes") }
        let pane = tile.orderedPanes[0]
        let other = tile.orderedPanes[1]
        tile.focus(pane, grabKeyboard: false)

        let now = Date()
        func entry(_ id: String) -> SessionEntry {
            SessionEntry(
                profileID: "trail-test", profileName: "trail", host: "trail",
                backendType: .claudeCode,
                session: AgentSession(
                    id: id, agentType: .claudeCode, title: "Trail \(id)", directory: "/tmp/trail",
                    createdAt: now, updatedAt: now))
        }
        let chats = ["a", "b", "c", "d", "e"].map(entry)
        host.entries = chats

        func settled(on id: String) -> Bool {
            brainPump(2, until: { pane.sessionID == id })
        }
        func trail() -> [String] { pane.trail.visited.map(\.sessionID) }

        for chat in chats.prefix(4) { pane.open(chat) }
        try expect(trail() == ["a", "b", "c", "d"], "the chats a pane opens are its trail, in order")

        try expect(host.stepTrail(.back), "Back has somewhere to go")
        try expect(pane.sessionID == "d", "a step is not drawn until the queued events are done")
        try expect(settled(on: "c"), "and then the pane shows the chat before")

        try expect(host.stepTrail(.back) && host.stepTrail(.back), "a burst of presses is taken")
        try expect(settled(on: "a"), "and lands on the chat it ended on")
        try expect(trail() == ["a", "b", "c", "d"], "a step opens nothing the trail did not hold")
        try expect(!host.stepTrail(.back), "a press with nowhere to go does nothing")

        for id in ["b", "c", "d"] {
            try expect(host.stepTrail(.forward), "Forward walks back what Back walked")
            try expect(settled(on: id), "to the chat after (\(id))")
        }
        try expect(!host.stepTrail(.forward), "and stops at the end")

        other.open(chats[2])
        try expect(host.stepTrail(.back), "Back steps over a chat another pane is showing")
        try expect(settled(on: "b"), "to the one before it")
        try expect(host.stepTrail(.forward), "and Forward steps over it too")
        try expect(settled(on: "d"), "to the one after it")
        other.open(chats[4])
        try expect(host.stepTrail(.back), "with the other pane gone from it, Back goes there")
        try expect(settled(on: "c"), "to the chat that was in the way")

        host.forgetInTrails(sessionIDs: ["a"])
        try expect(trail() == ["b", "c", "d"], "a deleted chat leaves the trail")
        try expect(host.stepTrail(.back), "and the place stays where it was")
        try expect(settled(on: "b"), "so Back goes to the oldest that is left")
        try expect(!host.stepTrail(.back), "and stops there")

        host.entries = chats.filter { $0.session.id != "c" }
        try expect(host.stepTrail(.forward), "a chat missing from the listing is stepped over")
        try expect(settled(on: "d"), "to the next that is there")
        try expect(trail() == ["b", "c", "d"], "and stays in the trail for when it is listed again")
        return checks
    }
}
