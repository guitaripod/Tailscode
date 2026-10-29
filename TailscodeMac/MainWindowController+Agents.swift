import AppKit
import CodingAgentKit
import TailscodeCore

extension MainWindowController {
    /// The Agents window, one per app. Raised from the menu, the sidebar's entry, the orb and the
    /// shortcut, and built the first time somebody asks.
    @discardableResult
    func presentAgents(fixture: Bool = false) -> AgentsWindowController {
        let controller = agentsController(fixture: fixture)
        controller.present()
        return controller
    }

    func toggleAgents() {
        agentsController(fixture: false).toggle()
    }

    private func agentsController(fixture: Bool) -> AgentsWindowController {
        if let agentsWindow { return agentsWindow }
        let feed: any AgentsFeed = fixture ? DemoFeed() : AgentsCenter.shared.makeFeed()
        let controller = AgentsWindowController(feed: feed)
        controller.onOpenChat = { [weak self] key in self?.openAgentChat(key) }
        if fixture { controller.visibilityOverride = true }
        agentsWindow = controller
        return controller
    }

    /// A chat the board names, opened where chats open: the pane already showing it, or the
    /// focused one. A key whose chat is no longer in the listing opens nothing.
    func openAgentChat(_ key: String) {
        let profileID = AgentsActions.profile(of: key)
        let sessionID = AgentsActions.session(of: key)
        guard
            let entry = sidebar.allEntries.first(where: {
                $0.profileID == profileID && $0.session.id == sessionID
            })
        else {
            NSSound.beep()
            return
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        MacNotifier.clearNotices(sessionID: sessionID)
        if let pane = splitPanes.pane(showing: sessionID) {
            splitPanes.focus(pane, grabKeyboard: false)
        } else {
            sidebar.open(entry)
        }
    }

    /// `--open agents`, `agents-watch`, `agents-hour` and `agent-peek`: the wall and the board on the
    /// fictional world, so a window nobody is sitting at can be drawn and measured with no server
    /// behind it.
    func openAgentsFixture(_ name: String) {
        let controller = presentAgents(fixture: true)
        controller.setMode(name == "agents-watch" ? .watch : .now)
        switch name {
        case "agents-hour":
            controller.setMode(.hour)
            Task { @MainActor [weak controller] in
                try? await Task.sleep(for: .milliseconds(500))
                controller?.select(key: AgentDemo.homelab + "/ask", from: .code)
            }
        case "agents-watch":
            break
        case "agent-peek":
            controller.select(key: AgentDemo.studio + "/w", from: .code)
        case "agents-long":
            let title = String(String(repeating: "A very long title that keeps going ", count: 6).prefix(200))
            let command = String(String(repeating: "swift build -c release --product TailscodeMac && ", count: 12).prefix(600))
            (controller.feed as? DemoFeed)?.replace(AgentsFixtures.longBoard(title: title, command: command))
            if let key = controller.feed.board.needsYou.first?.id { controller.select(key: key, from: .code) }
        case "agents-away":
            (controller.feed as? DemoFeed)?.replace(AgentsFixtures.awayBoard())
        default:
            break
        }
    }
}
