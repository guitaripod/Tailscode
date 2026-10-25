import CGtkShim
import Foundation
import TailscodeCore

extension MainWindow {
    /// `agents-watch=<scene>` opens the window on the wall showing one of Core's six demo scenes,
    /// `cycle` turns through all of them every eight seconds and an empty argument returns to the
    /// live board; `agents-fullscreen`, `agents-dim` and `agents-keepawake` press the wall's own
    /// controls, and `agents-skew=<seconds>` moves the wall's clock forward without waiting.
    func driveAgentsWatch(_ verb: String, _ argument: String) {
        switch verb {
        case "agents-watch":
            let board = presentAgents(mode: .watch)
            switch argument {
            case "": board.watchView.leaveScene()
            case "cycle": board.watchView.startCycle()
            default: board.watchView.startScene(argument)
            }
        case "agents-fullscreen": AgentsWindow.current?.controls.toggleFullscreen()
        case "agents-dim": AgentsWindow.current?.watchView.toggleDim()
        case "agents-keepawake": AgentsWindow.current?.controls.toggleKeepAwake()
        case "agents-skew":
            guard let board = AgentsWindow.current, let seconds = Double(argument) else { return }
            board.watchView.context.clock.advance(by: seconds)
            board.secondPassed()
        case "agents-hold":
            guard let board = AgentsWindow.current,
                let key = board.watchView.wall.tiles.first(where: { $0.state.isNeedsYou })?.id,
                let tile = board.watchView.tileView(key)
            else { return }
            tile.approveDown()
            board.watchView.context.clock.advance(by: Double(argument) ?? 0)
            tile.evaluateHold()
        case "agents-release":
            AgentsWindow.current?.watchView.tiles.values.forEach { $0.approveUp() }
        default: break
        }
    }
}
