import AppKit
import TailscodeCore

extension SidebarViewController {
    func observeAgents() {
        agentsEntry.onOpen = { [weak self] in self?.onOpenAgents?() }
        NotificationCenter.default.addObserver(
            forName: AgentsCenter.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainThread.call { self?.refreshAgentsEntry() }
        }
        let menu = NSMenu()
        let show = NSMenuItem(
            title: Localized.text("Show Agents"), action: #selector(showAgentsFromMenu), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let needing = NSMenuItem(
            title: Localized.text("Open the Chat That Needs You"), action: #selector(openOrbTargetFromMenu),
            keyEquivalent: "")
        needing.target = self
        menu.addItem(needing)
        orb.menu = menu
    }

    @objc private func showAgentsFromMenu() { onOpenAgents?() }
    @objc private func openOrbTargetFromMenu() { openOrbTarget() }

    /// The count on the entry: what the open board says when one is open, and otherwise what the
    /// listing and the open panes already know — a chat stopped to ask, a turn running.
    func refreshAgentsEntry() {
        if let board = AgentsCenter.shared.liveBoard {
            agentsEntry.render(needsYou: board.headline.needsYou, working: board.headline.working)
            return
        }
        agentsEntry.render(
            needsYou: known.filter { $0.state == .awaitingApproval }.count,
            working: known.filter { $0.state == .live }.count)
    }
}
