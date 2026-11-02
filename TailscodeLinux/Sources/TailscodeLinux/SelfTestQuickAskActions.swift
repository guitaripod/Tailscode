import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// The quick ask's own actions over the scripted fleet (hosts that cannot resolve) and a scratch
    /// actions file: a written action leads, its aim moves machine and model for the one question
    /// and emptying the box hands the aim back, `{session}` turns the empty window into the chat
    /// list and a pick names the chat in the box, Esc sets a gathering aside without closing the
    /// window, and a question put off for later is kept with its aim and leaves the box empty.
    static func checkQuickAskActions() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var claims = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("quick ask actions: \(label)") }
            claims += 1
        }
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(4000)
            }
        }
        MatrixTheme.install()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("selftest-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keptActions = QuickAskActions.fileURL
        let keptLater = QuickAskLaterStore.fileURL
        QuickAskActions.fileURL = folder.appendingPathComponent("quick-actions.json")
        QuickAskLaterStore.fileURL = folder.appendingPathComponent("quick-later.json")
        QuickAskActions.forget()
        let keptStarters = QuickAskStarterRecents.recent()
        QuickAskStarterRecents.clear()
        defer {
            QuickAskStarterRecents.clear()
            for id in keptStarters.reversed() { QuickAskStarterRecents.record(id) }
            QuickAskWindow.open?.close()
            QuickAskPartyDemo.restore()
            QuickAskActions.fileURL = keptActions
            QuickAskLaterStore.fileURL = keptLater
            QuickAskActions.forget()
            try? FileManager.default.removeItem(at: folder)
            SettingsFile.capture()
        }
        try Data(
            """
            {"actions": [
              {"id": "custom.selftest", "title": "Ask the other one", "prompt": "Weigh {cursor} carefully.",
               "aim": {"server": "macbook"}},
              {"id": "continue"}
            ]}
            """.utf8
        ).write(to: QuickAskActions.fileURL)
        QuickAskActions.forget()

        QuickAskPartyDemo.seed()
        let chat = SessionEntry(
            profileID: "studio", profileName: "studio", host: "studio", backendType: .omp,
            session: AgentSession(
                id: "selftest-chat", agentType: .omp, title: "Port the game", parentID: nil,
                directory: "/tmp/game", createdAt: Date(), updatedAt: Date()))
        QuickAskWindow.present(
            servers: QuickAskPartyDemo.profiles, preferredServer: "arch", recents: [chat],
            parent: nil, onAsk: { _, _, _, done in done(nil) }, onResume: { _ in },
            onAskParty: { _, done in done(nil) })
        guard let ask = QuickAskWindow.open else {
            throw SelfTestFailure("quick ask actions: the window did not open")
        }
        pump(0.4)
        ask.write("")
        pump(0.2)
        try expect(ask.offered.first?.id == "custom.selftest", "the written action leads")
        try expect(ask.offered.contains { $0.id == "web" }, "the app's own follow it")

        guard let written = QuickAskActions.action(id: "custom.selftest"),
            let handOn = QuickAskActions.action(id: "continue")
        else { throw SelfTestFailure("quick ask actions: the file is read back") }
        ask.run(written, copied: false)
        pump(0.2)
        try expect(ask.targetServer.id == "macbook", "the action's machine is the aim while it is in the box")
        try expect(ask.editor.text == "Weigh  carefully.", "the words land with the token gone")
        try expect(ask.editor.cursor == "Weigh ".count, "the caret stands where {cursor} was")
        ask.write("")
        pump(0.2)
        try expect(ask.hold == nil && ask.targetServer.id == "arch", "emptying the box hands the aim back")

        ask.run(handOn, copied: false)
        pump(0.2)
        try expect(ask.gathering?.awaiting == .session, "{session} waits for a chat")
        try expect(gtk_widget_get_visible(ask.body) != 0, "and the empty window lists them")
        try expect(ask.menuItems.first.map { if case .session = $0.kind { true } else { false } } == true, "as chats to pick")
        ask.pick(at: 0)
        pump(0.2)
        try expect(ask.gathering == nil, "a pick finishes the gathering")
        try expect(
            ask.editor.text.contains("selftest-chat") && ask.editor.text.contains("Port the game"),
            "the chat is named so an agent can find it")
        ask.write("")
        ask.run(handOn, copied: false)
        ask.cancelGathering()
        pump(0.2)
        try expect(ask.gathering == nil && QuickAskWindow.open === ask, "Esc's path sets the gathering aside and keeps the window")

        ask.write("ipad mini rumours")
        pump(0.2)
        try expect(
            ask.isTyping && !ask.menuItems.isEmpty
                && ask.menuItems.allSatisfy { $0.id.hasPrefix("verb:") },
            "typed words turn the list into verbs for them")
        try expect(gtk_widget_get_visible(ask.body) != 0, "and the list keeps its place")
        guard ask.menuItems.contains(where: { $0.id == "verb:web" }) else {
            throw SelfTestFailure("quick ask actions: the web search is offered as a verb")
        }
        try expect(ask.walksList(down: true), "↓ from a one-line question steps into the verbs")
        ask.activate(id: "verb:web")
        pump(0.2)
        try expect(
            ask.editor.text.hasSuffix("ipad mini rumours") && ask.editor.text.count > "ipad mini rumours".count,
            "a verb takes the typed words as what it is about: \(ask.editor.text)")
        ask.write("")
        pump(0.2)
        ask.moveSelection(by: 1)
        try expect(ask.menuCursor.index == 0, "an arrow walks into the list")
        ask.moveSelection(by: -1)
        try expect(ask.menuCursor.index == nil, "and back out of it")

        ask.write("Any iPad mini rumours?")
        ask.schedule(.everyMorning)
        pump(0.2)
        let waiting = QuickAskLaterStore.all()
        try expect(waiting.count == 1 && waiting[0].repeats == .daily, "a question put off is kept with its repeat")
        try expect(waiting[0].profileID == "arch" && waiting[0].model != nil, "and with the aim showing")
        try expect(ask.editor.text.isEmpty, "and leaves the box empty")
        return claims
    }
}
