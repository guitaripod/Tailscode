import AppKit
import CodingAgentKit
import TailscodeCore

extension AgentsChecks {
    /// The tower through the window: opened when the window is looked at, a watch on the running
    /// session while it is, none the moment it is closed, and again when it comes back.
    static func theTowerOpensAndClosesWithTheWindow(_ expect: (Bool, String) throws -> Void) async throws {
        let (tower, entry) = AgentsFixtures.tower(script: AgentsFixtures.script())
        let feed = TowerFeed(tower: tower, serial: AgentsSerial())
        await tower.update(entries: [entry], reachability: ["p1": true], unread: [])
        let controller = AgentsFixtures.controller(feed)
        try await Task.sleep(for: .milliseconds(1500))
        let idle = await tower.current
        try expect(idle.working.first?.isWatched == false && idle.working.first?.line == nil, "a closed window has watched nothing")
        controller.startWatching()
        let watched = await AgentsFixtures.wait {
            await tower.current.working.first?.line == "Editing Backoff.swift"
        }
        try expect(watched, "an open window watches the running session and reads what it is doing")
        await AgentsFixtures.settle(controller)
        let drawn = AgentsFixtures.allCells(AgentsRowView.self, in: controller).first
        try expect(drawn?.row?.line == "Editing Backoff.swift", "and the row shows it")
        controller.stopWatching()
        let released = await AgentsFixtures.wait(timeout: 5) {
            await tower.current.working.first?.isWatched == false
        }
        try expect(released, "closing the window leaves no watch behind")
        var heard: AgentFacts? = AgentDemo.facts(now: Date())
        for await facts in await tower.facts(for: "p1/s1") {
            heard = facts
            break
        }
        try expect(heard == nil, "and the session's facts are gone with it")
        controller.startWatching()
        let again = await AgentsFixtures.wait {
            await tower.current.working.first?.isWatched == true
        }
        try expect(again, "a window that comes back watches again")
        controller.stopWatching()
        await tower.close()
    }

    /// An approval through the real code path: a tower over a scripted session that asks, a card
    /// that appears from what the conversation says, and a press that reaches the backend.
    static func theRealPathApproves(_ expect: (Bool, String) throws -> Void) async throws {
        let (tower, entry) = AgentsFixtures.tower(script: AgentsFixtures.askingScript())
        let feed = TowerFeed(tower: tower, serial: AgentsSerial())
        await tower.update(entries: [entry], reachability: ["p1": true], unread: [])
        let controller = AgentsFixtures.controller(feed)
        controller.startWatching()
        let asked = await AgentsFixtures.wait {
            await tower.current.needsYou.first?.ask.object == "rm -rf build"
        }
        try expect(asked, "a session that asks becomes a card with the command word for word")
        await AgentsFixtures.settle(controller)
        let card = AgentsFixtures.cell(AgentsAskCardView.self, in: controller)
        try expect(card?.block.commandText == "rm -rf build", "and the window draws it")
        guard let key = await tower.current.needsYou.first?.id, let ask = await tower.current.needsYou.first?.ask
        else { throw SelfTestFailure("agents: the real card has a key") }
        controller.actions.decide(key, ask: ask, allow: true)
        let answered = await AgentsFixtures.wait(timeout: 5) {
            controller.actions.phase(for: key, askID: ask.id) == .sent(.approve)
        }
        try expect(answered, "Approve reaches the conversation and comes back sent")
        controller.stopWatching()
        await tower.close()
    }

    /// The registry binds the chord, the action opens the window, and closing it releases the feed.
    static func theShortcutOpensTheWindow(_ expect: (Bool, String) throws -> Void) async throws {
        let set = ShortcutSet.build(overrides: [:])
        let chord = KeyChord.canonical(
            keyval: UInt32(UnicodeScalar("a").value), state: KeyChord.controlMask | KeyChord.shiftMask)
        var resolved: KeyAction?
        if let chord, case .run(let found) = set.resolve(chord, context: .normal, pending: [], awaitingApproval: false) {
            resolved = found
        }
        try expect(resolved == .toggleAgents, "Control-Shift-A is the registry's chord for the board")
        let bound = MainWindowController.boundChord(for: .toggleAgents, in: set)
        try expect(bound?.control == true && bound?.shift == true, "and the menu wears the same chord")
        let feed = DemoFeed()
        let controller = AgentsFixtures.keep(AgentsWindowController(feed: feed))
        controller.visibilityOverride = true
        controller.toggle()
        try expect(controller.window?.isVisible == true, "the action opens the window")
        try expect(controller.isWatching && feed.isOpen, "and the feed is open with it")
        controller.window?.close()
        try await Task.sleep(for: .milliseconds(100))
        try expect(!controller.isWatching && !feed.isOpen, "closing the window closes the feed")
    }
}
