import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MainWindow {
    /// The faces the sidebar's Agents card can be told to wear for a headless look at each of its
    /// states: `idle`, `working`, `needs`, and `long`, whose titles and counts are the most a
    /// narrow sidebar will ever be asked to hold.
    static func agentsFace(_ name: String) -> AgentsReading? {
        let demo = AgentsReading(board: AgentsRuntime.shared.demoBoard)
        switch name {
        case "idle":
            return .quiet
        case "working":
            let rows = demo.rows.filter { !$0.needsYou }
            return AgentsReading(
                chip: AgentsChip(needsYou: 0, working: rows.count), running: rows.count + 1, rows: rows)
        case "needs":
            return demo
        case "long":
            let title = String(repeating: "A chat title that runs on past any sidebar ", count: 4)
            let rows = (0..<4).map {
                AgentsOnNowRow(
                    key: "long\($0)", title: title, words: title, since: Date().addingTimeInterval(-3725),
                    needsYou: $0 == 0)
            }
            return AgentsReading(chip: AgentsChip(needsYou: 12, working: 345), running: 357, rows: rows)
        default:
            return nil
        }
    }

    func driveAgentsFace(_ verb: String, _ argument: String) {
        switch verb {
        case "agents-face":
            agentsFace = argument.isEmpty ? nil : Self.agentsFace(argument)
            refreshAgentsEntry()
        case "agents-sidebar":
            guard let width = Int32(argument), let splitWidget else { return }
            gtk_paned_set_position(op(splitWidget), width)
        default: break
        }
    }
}
