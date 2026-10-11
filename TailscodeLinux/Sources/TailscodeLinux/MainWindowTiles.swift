import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MainWindow {
    /// The drive verbs that read and move the canvas: `density` prints what every pane wears,
    /// `canvas` the counters that prove nothing is re-parented, `strip` the overflow chips, and the
    /// rest press what a person would press — a chip, a glance's actions, the live chip's switch —
    /// without a pointer. Answers whether the verb was one of these.
    func driveTiles(_ verb: String, _ argument: String) -> Bool {
        guard let tile = splitHost as? TileHost else {
            switch verb {
            case "density", "tilecanvas", "strip", "tiles", "glance", "parked", "pin", "park", "pane":
                FileHandle.standardOutput.write(Data("\(verb.uppercased()) legacy tiling\n".utf8))
                return true
            default:
                return false
            }
        }
        func say(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
        let index = Int(argument) ?? 0
        switch verb {
        case "density": say(tile.driveDensity())
        case "tilecanvas": say(tile.driveCanvas())
        case "strip": say(tile.driveStrip())
        case "tiles": say(tile.driveGeometry())
        case "glance": say(tile.driveGlance(index))
        case "parked": say(tile.driveParked(index))
        case "pin": say("PIN \(index) \(tile.drivePin(index))")
        case "park": say("PARK \(index) \(tile.drivePark(index))")
        case "resumepane": say("RESUMEPANE \(index) \(tile.driveResume(index))")
        case "pressresume": say("PRESSRESUME \(index) \(tile.pressResume(index))")
        case "openfull": say("OPENFULL \(index) \(tile.driveOpenFull(index))")
        case "chip": say("CHIP \(tile.pressChip(index))")
        case "promote":
            _ = tile.drive(pane: index) { tile.focusPane($0) }
            _ = perform(.promoteSplit)
            say("PROMOTE \(index)")
        case "arrange":
            let arrangement = SplitArrangement.allCases.first { "\($0)".lowercased() == argument.lowercased() }
            if let arrangement { tile.arrange(arrangement) }
            say("ARRANGE \(argument) -> \(SplitEven.shape(of: tile.layout))")
        case "ghost":
            tile.forcedGhost = argument == "on" ? true : argument == "off" ? false : nil
            say("GHOST \(argument)")
        case "dragbench":
            tile.driveDragBench(steps: Int(argument) ?? 20) {
                FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
            }
        case "keeplive":
            Seatbelts.shared.setLiveBudget(argument == "off" ? .auto : .all)
            say("KEEPLIVE \(Seatbelts.shared.liveBudget == .all)")
        case "chiptext":
            say("CHIPTEXT \(liveChipText) shown=\(liveChip.map { gtk_widget_get_visible($0) != 0 } ?? false)")
        case "winsize":
            let fields = argument.split(separator: "x").compactMap { Int32($0) }
            if fields.count == 2, let window = windowWidget {
                gtk_window_set_default_size(ptr(window), fields[0], fields[1])
            }
            say("WINSIZE \(argument)")
        default:
            return false
        }
        return true
    }
}
