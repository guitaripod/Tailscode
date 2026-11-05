import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The quick ask's own actions on the real panel, over two fixture machines and a scratch
    /// actions file, with every key it touches put back: a written action is offered beside the
    /// app's, its aim moves machine and model for the one question and emptying the box hands the
    /// aim back, `{session}` turns the empty panel into a list of chats and a pick names the chat in
    /// the box, a copied link is told from copied words, an unreadable entry is counted, and a
    /// question put off for later is kept with its aim.
    /// `TAILSCODE_QUICKASK_OUT=<dir>` writes the panel and the chat list as PNGs.
    static func checkQuickAskActions() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
            checks += 1
        }
        await settleQuickAsk()
        let defaults = UserDefaults.standard
        let serverKey = "tailscode.quickask.server"
        let startersKey = "tailscode.quickask.starters"
        let keptServer = defaults.string(forKey: serverKey)
        let keptStarters = defaults.stringArray(forKey: startersKey)
        let keptURL = QuickAskActions.fileURL
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("selftest-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        QuickAskActions.fileURL = folder.appendingPathComponent("quick-actions.json")
        QuickAskActions.forget()
        let keptLater = QuickAskLaterStore.fileURL
        QuickAskLaterStore.fileURL = folder.appendingPathComponent("quick-later.json")
        let arch = ConnectionProfile(
            id: "selftest-qx-arch", name: "qx-arch", backend: .openCode,
            baseURL: URL(string: "http://127.0.0.1:9")!)
        let macbook = ConnectionProfile(
            id: "selftest-qx-macbook", name: "qx-macbook", backend: .openCode,
            baseURL: URL(string: "http://127.0.0.1:9")!)
        defer {
            for profile in [arch, macbook] { QuickAskDefaults.clearOwnAim(forProfileID: profile.id) }
            if let keptServer { defaults.set(keptServer, forKey: serverKey) } else { defaults.removeObject(forKey: serverKey) }
            if let keptStarters { defaults.set(keptStarters, forKey: startersKey) } else { defaults.removeObject(forKey: startersKey) }
            try? FileManager.default.removeItem(at: folder)
            QuickAskLaterStore.fileURL = keptLater
            QuickAskActions.fileURL = keptURL
            QuickAskActions.forget()
        }
        try Data(
            """
            {"actions": [
              {"id": "custom.selftest", "title": "Ask the other one", "prompt": "Weigh {cursor} carefully.",
               "aim": {"server": "selftest-qx-macbook", "model": "ollama/qwen3-coder:30b", "effort": "high"}},
              {"id": "continue"},
              {"broken": true}
            ]}
            """.utf8
        ).write(to: QuickAskActions.fileURL)
        QuickAskActions.forget()
        try expect(QuickAskActions.unreadable == 1, "an entry with no id is counted, not dropped silently")

        let chat = SessionEntry(
            profileID: macbook.id, profileName: macbook.name, host: "127.0.0.1",
            backendType: .omp,
            session: AgentSession(
                id: "selftest-chat", agentType: .omp, title: "Port the game", parentID: nil,
                directory: "/tmp/game", createdAt: Date(), updatedAt: Date()))
        QuickAskDefaults.record(profileID: arch.id)
        defaults.removeObject(forKey: startersKey)
        let panel = QuickAskPanel(
            servers: [arch, macbook], preferredServer: arch.id, recents: [chat],
            onAsk: { _, _, _, done in done(nil) }, onResume: { _ in },
            onAskParty: { _, done in done(nil) })
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
        defer { panel.close() }
        panel.aim(at: arch.id)
        panel.refreshAim()
        try dumpActions(panel, "quickask-actions.png")

        try expect(
            panel.offered.first?.id == "custom.selftest",
            "the written action leads, in the file's order")
        try expect(
            panel.offered.contains { $0.id == "continue" } && panel.offered.contains { $0.id == "web" },
            "the app's own actions follow, named or not")

        guard let written = QuickAskActions.action(id: "custom.selftest") else {
            throw SelfTestFailure("the written action is read back")
        }
        panel.run(written, copied: false)
        try expect(panel.targetServer.id == macbook.id, "the action's machine is the aim while it is in the box")
        try expect(
            QuickAskDefaults.model(forProfileID: macbook.id)?.rawValue == "ollama/qwen3-coder:30b",
            "and its model")
        try expect(panel.editor.text == "Weigh  carefully.", "the words land with the token gone")
        try expect(panel.editor.cursor == "Weigh ".count, "the caret stands where {cursor} was")
        panel.editor.setText("", caretAtEnd: true)
        try expect(panel.hold == nil, "emptying the box sets the action aside")
        try expect(panel.targetServer.id == arch.id, "and hands the machine back")

        guard let handOn = QuickAskActions.action(id: "continue") else {
            throw SelfTestFailure("the app's own hand-on action is there")
        }
        panel.run(handOn, copied: false)
        try expect(panel.gathering?.awaiting == .session, "{session} waits for a chat")
        try expect(!panel.listScroll.isHidden, "and the empty panel lists them")
        try dumpActions(panel, "quickask-actions-chats.png")
        panel.pick(at: 0)
        try expect(panel.gathering == nil, "a pick finishes the gathering")
        try expect(
            panel.editor.text.contains("selftest-chat") && panel.editor.text.contains("Port the game"),
            "the chat is named so an agent can find it")
        panel.editor.setText("", caretAtEnd: true)

        panel.run(handOn, copied: false)
        panel.cancelOperation(nil)
        try expect(panel.gathering == nil && panel.isVisible, "Esc sets the gathering aside and keeps the panel")

        try expect(
            QuickAskClipboard.holding(of: ClipboardOffer(text: "https://github.com/a/b"))?.holding
                == .link("https://github.com/a/b"),
            "a copied address is a link")

        panel.editor.setText("ipad mini rumours", caretAtEnd: true)
        try expect(
            panel.isTyping && !panel.menuItems.isEmpty
                && panel.menuItems.allSatisfy { $0.id.hasPrefix("verb:") },
            "typed words turn the list into verbs for them")
        try expect(!panel.listScroll.isHidden, "and the list keeps its place")
        guard panel.menuItems.contains(where: { $0.id == "verb:web" }) else {
            throw SelfTestFailure("the web search is offered as a verb")
        }
        try expect(panel.walksList(down: true), "↓ from a one-line question steps into the verbs")
        try expect(!panel.walksList(down: false), "and ↑ stays the box's")
        panel.activate(id: "verb:web")
        try expect(
            panel.editor.text.hasSuffix("ipad mini rumours")
                && panel.editor.text.count > "ipad mini rumours".count,
            "a verb takes the typed words as what it is about: \(panel.editor.text)")
        panel.editor.setText("", caretAtEnd: true)
        panel.moveSelection(by: 1)
        try expect(panel.menuCursor.index == 0, "an arrow walks into the list")
        panel.cancelOperation(nil)
        try expect(panel.menuCursor.index == nil && panel.isVisible, "Esc lets go of the line first")

        try checkPlacement(panel, expect)

        panel.editor.setText("Any iPad mini rumours?", caretAtEnd: true)
        panel.schedule(.everyMorning)
        let waiting = QuickAskLaterStore.all()
        try expect(waiting.count == 1 && waiting[0].repeats == .daily, "a question put off is kept with its repeat")
        try expect(waiting[0].profileID == arch.id, "and with the machine showing")
        try expect(panel.editor.text.isEmpty, "and leaves the box empty")
        return checks
    }

    /// The panel is the person's size: the list takes the height a taller panel gives it, the
    /// panel can be made no smaller than the card needs, and it opens with the head of the question
    /// box under the pointer at the size it was left at, slid in from a corner, while a panel that
    /// never stood on a screen keeps its hands off what the person kept.
    private static func checkPlacement(
        _ panel: QuickAskPanel, _ expect: (Bool, String) throws -> Void
    ) throws {
        let kept = QuickAskPlacementStore.load()
        defer {
            if kept == QuickAskPlacement() { QuickAskPlacementStore.clear() } else {
                QuickAskPlacementStore.save(kept)
            }
        }
        try expect(panel.styleMask.contains(.resizable), "the panel can be resized")
        panel.setContentSize(NSSize(width: 640, height: 480))
        panel.contentView?.layoutSubtreeIfNeeded()
        let short = panel.listScroll.frame.height
        panel.setContentSize(NSSize(width: 720, height: 820))
        panel.contentView?.layoutSubtreeIfNeeded()
        let tall = panel.listScroll.frame.height
        try expect(tall >= short + 300, "a taller panel is a taller list: \(short) → \(tall)")
        try expect(
            abs(panel.frame.height - 820) < 1 && abs(panel.frame.width - 720) < 1,
            "and the panel keeps the size it was given: \(panel.frame.size)")
        try expect(
            panel.contentMinSize.width == QuickAskGeometry.minimumWidth
                && panel.contentMinSize.height == QuickAskGeometry.minimumHeight,
            "a hand can make it no smaller than the card's minimum")
        panel.setContentSize(NSSize(width: 520, height: 330))
        panel.sizeChosen()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setStatus(
            String(
                repeating: "The machine refused the question because the model it was aimed at is not loaded there. ",
                count: 24))
        panel.contentView?.layoutSubtreeIfNeeded()
        let grown = panel.frame.height
        try expect(
            grown > 420 && panel.listScroll.frame.height >= 63,
            "a failure longer than the list can give way to grows the panel and keeps the list's floor: \(grown), list \(panel.listScroll.frame.height)")
        panel.setStatus("")
        panel.contentView?.layoutSubtreeIfNeeded()
        try expect(
            abs(panel.frame.height - 330) < 1, "and it goes back to the chosen size after: \(panel.frame.height)")

        QuickAskPlacementStore.clear()
        panel.remember()
        try expect(QuickAskPlacementStore.load() == QuickAskPlacement(), "an unplaced panel remembers nothing")
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let pointer = NSPoint(x: area.minX + 300, y: area.maxY - 240)
        panel.place(at: pointer, near: nil)
        let mark = panel.spark.convert(
            NSPoint(x: panel.spark.bounds.midX, y: panel.spark.bounds.midY), to: nil)
        let landed = panel.convertPoint(toScreen: mark)
        try expect(
            abs(landed.x - pointer.x) < 1 && abs(landed.y - pointer.y) < 1,
            "it opens with the head of the question box under the pointer: \(landed) for \(pointer)")
        panel.setFrame(
            NSRect(x: area.minX + 120, y: area.maxY - 90 - 700, width: 760, height: 700), display: false)
        panel.sizeChosen()
        panel.remember()
        let left = QuickAskPlacementStore.load()
        try expect(
            left.width == 760 && left.height == 700 && left.spots.isEmpty,
            "the size is kept as it was left, and the place is not: \(left)")
        panel.place(at: NSPoint(x: area.maxX - 2, y: area.minY + 2), near: nil)
        try expect(
            abs(panel.frame.maxX - (area.maxX - QuickAskGeometry.inset)) < 1
                && abs(panel.frame.minY - (area.minY + QuickAskGeometry.inset)) < 1
                && abs(panel.frame.width - 760) < 1,
            "and a pointer in a corner slides it in from the edges at that size: \(panel.frame)")
        panel.isPlaced = false
    }

    private static func dumpActions(_ panel: QuickAskPanel, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TAILSCODE_QUICKASK_OUT"],
            let view = panel.card ?? panel.contentView
        else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
