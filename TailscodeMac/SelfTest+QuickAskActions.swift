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
        try expect(!panel.suggestions.isEmpty && !panel.suggest.isHidden, "typed words are offered verbs")
        try expect(panel.listScroll.isHidden, "and the list steps aside for them")
        guard let verb = panel.suggestions.firstIndex(where: { $0.id == "web" }) else {
            throw SelfTestFailure("the web search is offered as a verb")
        }
        panel.applySuggestion(at: verb)
        try expect(
            panel.editor.text.hasSuffix("ipad mini rumours")
                && panel.editor.text.count > "ipad mini rumours".count,
            "a verb takes the typed words as what it is about: \(panel.editor.text)")
        panel.editor.setText("", caretAtEnd: true)
        panel.moveSelection(by: 1)
        try expect(panel.menuCursor.index == 0, "an arrow walks into the list")
        panel.cancelOperation(nil)
        try expect(panel.menuCursor.index == nil && panel.isVisible, "Esc lets go of the line first")

        panel.editor.setText("Any iPad mini rumours?", caretAtEnd: true)
        panel.schedule(.everyMorning)
        let waiting = QuickAskLaterStore.all()
        try expect(waiting.count == 1 && waiting[0].repeats == .daily, "a question put off is kept with its repeat")
        try expect(waiting[0].profileID == arch.id, "and with the machine showing")
        try expect(panel.editor.text.isEmpty, "and leaves the box empty")
        return checks
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
