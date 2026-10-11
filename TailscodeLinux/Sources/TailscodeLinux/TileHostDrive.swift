import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension TileHost {
    private func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func faceWord(_ id: PaneID) -> String {
        guard let shell = shells[id] else { return "-" }
        guard placement?.isPlaced(id) == true else { return "hidden" }
        switch shell.face {
        case .full: return "full"
        case .glance: return "glance"
        case .paused: return "paused"
        }
    }

    /// What every pane wears and owns, in reading order, for the harness: its face, whether it is
    /// kept live, its lease, its glance feed and how many row widgets it holds.
    func driveDensity() -> String {
        let counts = liveCounts
        let level = lastDecision?.level.rawValue ?? -1
        let budget = lastDecision?.fullBudget ?? -1
        let chip = LiveChipReading.title(
            live: counts.live, chats: counts.chats, decision: lastDecision)
        let described = layout.paneIDs.enumerated().map { index, id -> String in
            let pane = panes[id]
            let pin = activePinned(id) ? "+pin" : ""
            return "\(index):\(faceWord(id))\(pin) lease=\(pane?.lease != nil) "
                + "feed=\(feedExists(id)) rows=\(pane?.rowCount ?? -1)"
        }
        return "DENSITY level=\(level) budget=\(budget) chip=\"\(chip)\" " + described.joined(separator: " | ")
    }

    /// The overflow strip as the harness reads it: the chips, how many fit, and the count.
    func driveStrip() -> String {
        let names = strip.chips.map { OverflowStrip.cut($0.title) }.joined(separator: ",")
        let shown = placement?.strip != nil
        return "STRIP shown=\(shown) chips=\(strip.chips.count) visible=\(strip.visibleChips) "
            + "more=\(strip.hiddenCount) reason=\(placement?.hiddenReason.map { "\($0)" } ?? "-") \(names)"
    }

    /// The canvas's own counters: its children, the adds refused for already having a parent, the
    /// allocation passes and what the last one cost.
    func driveCanvas() -> String {
        String(
            format: "CANVAS children=%d reparents=%d allocations=%d last=%.2fms drag=%.2fms ratios=%d persists=%d",
            canvasChildCount, TileCanvas.reparents, canvasAllocations, canvasLastMilliseconds,
            lastDragMilliseconds, ratioWrites, persistRequests)
    }

    func driveGeometry() -> String {
        let frames = layout.paneIDs.enumerated().map { index, id -> String in
            guard let shell = shells[id] else { return "\(index)(-)" }
            let box = Gtk.bounds(of: shell.widget, in: container) ?? (0, 0, 0, 0)
            let mapped = gtk_widget_get_mapped(shell.widget) != 0
            return String(
                format: "%d(%.0f,%.0f %.0fx%.0f%@)", index, box.x, box.y, box.width, box.height,
                mapped ? "" : " hidden")
        }
        return "TILES " + frames.joined(separator: " ") + " canvas=\(canvasSummary)"
    }

    func drive(pane index: Int, _ act: (PaneID) -> Void) -> Bool {
        let ids = layout.paneIDs
        guard ids.indices.contains(index) else { return false }
        act(ids[index])
        return true
    }

    func drivePin(_ index: Int) -> Bool { drive(pane: index) { togglePin($0) } }
    func drivePark(_ index: Int) -> Bool { drive(pane: index) { togglePark($0) } }
    func driveResume(_ index: Int) -> Bool { drive(pane: index) { resume($0) } }
    func driveOpenFull(_ index: Int) -> Bool { drive(pane: index) { openFullPane($0) } }

    func driveGlance(_ index: Int) -> String {
        let ids = layout.paneIDs
        guard ids.indices.contains(index), let tile = shells[ids[index]]?.glance else {
            return "GLANCE - no tile"
        }
        return "GLANCE \(index) renders=\(tile.renders) clock=\(tile.ownsClock) "
            + "title=\"\(tile.titleText)\" tail=\"\(tile.shownTail.prefix(60))\" "
            + "spoken=\"\(tile.spokenLabel)\""
    }

    func driveParked(_ index: Int) -> String {
        let ids = layout.paneIDs
        guard ids.indices.contains(index), let face = shells[ids[index]]?.parked else {
            return "PARKED - no face"
        }
        return "PARKED \(index) renders=\(face.renders) title=\"\(face.titleText)\" "
            + "words=\(face.hasWords) resume=\(face.hasResume)"
    }

    func pressResume(_ index: Int) -> Bool {
        let ids = layout.paneIDs
        guard ids.indices.contains(index), let face = shells[ids[index]]?.parked else { return false }
        face.pressResume()
        return true
    }

    func pressChip(_ index: Int) -> Bool {
        guard strip.chips.indices.contains(index) else { return false }
        strip.press(strip.chips[index].id)
        return true
    }
}
