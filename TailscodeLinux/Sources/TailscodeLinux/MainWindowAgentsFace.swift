import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MainWindow {
    /// The faces the sidebar's Agents card can be told to wear for a headless look at each of its
    /// states: `idle`, `working`, `needs`, `background` (only carried work), `many` (more running
    /// sessions than the orbit has lights) and `long`, whose title and counts are the most a
    /// narrow sidebar will ever be asked to hold.
    static func agentsFace(_ name: String) -> AgentsReading? {
        let demo = AgentsReading(board: AgentsRuntime.shared.demoBoard)
        switch name {
        case "idle":
            return .quiet
        case "working":
            return AgentsReading(
                working: demo.working, needsYou: 0, agents: demo.agents, background: demo.background,
                waiting: nil)
        case "needs":
            return demo
        case "background":
            return AgentsReading(working: 0, needsYou: 0, agents: 0, background: 2, waiting: nil)
        case "many":
            return AgentsReading(working: 6, needsYou: 0, agents: 9, background: 1, waiting: nil)
        case "long":
            let title = String(repeating: "A chat title that runs on past any sidebar ", count: 4)
            return AgentsReading(working: 345, needsYou: 12, agents: 99, background: 7, waiting: title)
        default:
            return nil
        }
    }

    func driveAgentsFace(_ verb: String, _ argument: String) {
        switch verb {
        case "agents-face":
            agentsFace = argument.isEmpty ? nil : Self.agentsFace(argument)
            refreshAgentsEntry()
        case "agents-focus":
            guard let window, let entry = agentsEntry else { return }
            gtk_window_set_focus_visible(ptr(window), 1)
            gtk_widget_grab_focus(entry.button)
        case "agents-rows":
            guard let index = entries.firstIndex(where: { $0.session.isActive == true }) else { return }
            var session = entries[index].session
            session.activeAgents = Int(argument) ?? 2
            let old = entries[index]
            entries[index] = SessionEntry(
                profileID: old.profileID, profileName: old.profileName, host: old.host,
                backendType: old.backendType, session: session)
            lastSidebar = nil
            renderSidebar()
        case "agents-sidebar":
            guard let width = Int32(argument), let splitWidget else { return }
            gtk_paned_set_position(op(splitWidget), width)
        default: break
        }
    }
}
