import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension MainWindow {
    /// The sidebar's Agents card, built once and put at the head of the sidebar.
    func makeAgentsEntry() -> UnsafeMutablePointer<GtkWidget> {
        let entry = AgentsSidebarEntry(memory: agentsShimmer) { [weak self] in self?.presentAgents() }
        agentsEntry = entry
        return entry.widget
    }

    /// What the card says, from one reading: the demo's fiction in demo mode, the board while it
    /// is open, and what the chat list can tell while it is not — a turn open and a turn waiting
    /// on an approval.
    func refreshAgentsEntry(rows: [SessionRowModel]? = nil) {
        if let rows { agentsListReading = AgentsReading(list: rows) }
        let reading: AgentsReading
        if let agentsFace {
            reading = agentsFace
        } else if let board = AgentsRuntime.shared.openBoard {
            reading = AgentsReading(board: board)
        } else if DemoMode.isActive {
            reading = AgentsReading(board: AgentsRuntime.shared.demoBoard)
        } else {
            reading = agentsListReading
        }
        agentsEntry?.apply(reading)
    }

    /// The chat list refreshed: tell the tower, but only while a board is watching — a closed
    /// board holds nothing, and nothing is built for it.
    func feedAgents(force: Bool = false) {
        guard force || AgentsRuntime.shared.watching else { return }
        AgentsRuntime.shared.feed(
            AgentsRuntime.listing(
                entries: entries, unreachable: unreachable, lastHeard: lastHeard,
                listedFromNetwork: listedFromNetwork))
    }

    @discardableResult
    func presentAgents(mode: AgentsWindow.Mode? = nil, selecting key: String? = nil) -> AgentsWindow {
        feedAgents(force: true)
        let board = AgentsWindow.present(
            parent: window, source: AgentsRuntime.shared.source, hooks: agentsHooks(), mode: mode,
            onHeadline: { [weak self] in Gtk.onMain { [weak self] in self?.refreshAgentsEntry() } })
        if let key { board.select(key: key) }
        return board
    }

    /// The board, opened on one chat's peek: what a row's agents chip and the orb's secondary
    /// press ask for.
    func presentAgentPeek(of entry: SessionEntry) {
        presentAgents(selecting: entry.profileID + "/" + entry.session.id)
    }

    func toggleAgents() {
        feedAgents(force: true)
        AgentsWindow.toggle(
            parent: window, source: AgentsRuntime.shared.source, hooks: agentsHooks(),
            onHeadline: { [weak self] in Gtk.onMain { [weak self] in self?.refreshAgentsEntry() } })
    }

    /// Where a press on the orb goes: the chat it has always opened, and the board behind the
    /// secondary press — a right click, or control held — with that chat selected in the peek.
    enum OrbDestination: Equatable {
        case chat
        case board
    }

    static func orbDestination(secondary: Bool, control: Bool) -> OrbDestination {
        secondary || control ? .board : .chat
    }

    func orbPressed(secondary: Bool) {
        guard let window else { return }
        switch Self.orbDestination(secondary: secondary, control: Gtk.ctrlHeld(window)) {
        case .chat:
            if let entry = orbTarget { open(entry) }
        case .board:
            presentAgents(selecting: orbTarget.map { $0.profileID + "/" + $0.session.id })
        }
    }

    func agentsHooks() -> AgentsHooks {
        AgentsHooks(
            openChat: { [weak self] key, draft in
                Gtk.onMain { [weak self] in self?.openAgentChat(key: key, draft: draft) }
            },
            confirmStop: { [weak self] title, proceed in
                Gtk.onMain { [weak self] in self?.confirmAgentStop(title: title, proceed: proceed) }
            },
            openStyle: { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.presentSettings(page: .advanced)
                    SettingsWatchStyle.reveal()
                }
            })
    }

    func openAgentChat(key: String, draft: String?) {
        guard let entry = entries.first(where: { $0.profileID + "/" + $0.session.id == key }) else {
            toast(Localized.text("That chat is not in the list right now."))
            return
        }
        if let window { gtk_window_present(ptr(window)) }
        open(entry)
        guard let draft, !draft.isEmpty else { return }
        Gtk.after(400) { [weak self] in
            guard let self else { return }
            self.activePane.insertIntoComposer(draft)
            self.activePane.focusComposer()
        }
    }

    private func confirmAgentStop(title: String, proceed: @escaping @Sendable () -> Void) {
        Dialogs.confirm(
            title: Localized.text("Stop “%@”?", title),
            body: Localized.text("The turn ends where it is. What it already did stays done."),
            confirmLabel: Localized.text("Stop"), parent: AgentsWindow.current?.window ?? window,
            onConfirm: proceed)
    }

    /// `agents`, `agents-hour`, `agent-peek=N`, `agents-close` and the harness's own readings of
    /// the board, for the film rig and a headless look at each state.
    func driveAgents(_ verb: String, _ argument: String) {
        switch verb {
        case "agents": presentAgents(mode: .now)
        case "agents-hour": presentAgents(mode: .hour)
        case "agent-peek":
            guard let board = AgentsWindow.current ?? Optional(presentAgents()) else { return }
            board.peek(at: Int(argument) ?? 0)
        case "agents-close": AgentsWindow.close()
        case "agents-stress":
            AgentsWindow.current?.apply(
                board: AgentsStress.board(
                    now: Date(), askCommand: Int(argument).map { AgentsStress.command(parts: $0) }))
        case "agents-size":
            let sizes = argument.split(separator: "x").compactMap { Int32($0) }
            if sizes.count == 2, let board = AgentsWindow.current {
                gtk_window_set_default_size(ptr(board.window), sizes[0], sizes[1])
            }
        case "agents-state":
            FileHandle.standardOutput.write(
                Data("AGENTS \(AgentsWindow.current?.stateLine ?? "closed")\n".utf8))
        default: break
        }
    }
}
