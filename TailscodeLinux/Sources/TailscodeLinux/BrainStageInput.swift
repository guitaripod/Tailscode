import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension BrainStage {
    /// What painting the nodes and the leader has cost since the stage opened, for the harness.
    var paintReading: String {
        String(
            format: "nodes=%d draws %.0fus each, leader=%d draws %.0fus each",
            nodeDraws, nodeDraws == 0 ? 0 : Double(nodeNanoseconds) / Double(nodeDraws) / 1000, leaderDraws,
            leaderDraws == 0 ? 0 : Double(leaderNanoseconds) / Double(leaderDraws) / 1000)
    }

    /// Whether the compositor has drawn at least one frame, for the harness.
    var hasPicture: Bool { hasDrawn }

    /// The design point under a point of the hit surface, undoing the dive's zoom.
    func design(_ x: Double, _ y: Double) -> NeuralPoint {
        let factor = unit
        guard factor > 0 else { return NeuralPoint(0, 0) }
        let zoom = max(0.05, scene.zoom)
        let center = scene.zoomCenter
        let flat = NeuralPoint(NeuralStageMetrics.designCrop.x + x / factor, y / factor)
        return NeuralPoint(center.x + (flat.x - center.x) / zoom, center.y + (flat.y - center.y) / zoom)
    }

    /// Where a design point is drawn on the stage, in points, with the dive's zoom applied.
    func screen(_ point: NeuralPoint) -> NeuralPoint {
        let factor = unit
        let zoom = scene.zoom
        let center = scene.zoomCenter
        let flat = NeuralPoint(
            center.x + (point.x - center.x) * zoom, center.y + (point.y - center.y) * zoom)
        return NeuralPoint((flat.x - NeuralStageMetrics.designCrop.x) * factor, flat.y * factor)
    }

    func pointer(x: Double, y: Double) {
        guard !isDiving, unit > 0 else { return }
        let found = owner.model.hit(at: design(x, y), slop: 4 / unit / max(0.05, scene.zoom))
        owner.stagePointer(over: found)
    }

    func pointerLeft() {
        owner.stagePointer(over: nil)
    }

    func focusChanged(entered: Bool) {
        owner.stageFocus(entered)
        gtk_widget_queue_draw(leader)
    }

    func clicked(x: Double, y: Double, presses: Int, button: Int) {
        guard !isDiving, unit > 0 else { return }
        gtk_widget_grab_focus(hit)
        owner.dismissLegendOnPress()
        let point = design(x, y)
        let found = owner.model.hit(at: point, slop: 4 / unit / max(0.05, scene.zoom))
        if button == 3 {
            if let found { owner.browse(.contextMenu(found), grabFocus: false, menuAt: nil) }
            return
        }
        guard button == 1 else { return }
        if let found {
            if presses >= 2, owner.opensSubagent(found) {
                owner.openSubagent(of: found)
            } else {
                owner.nodeClicked(found, double: presses >= 2)
            }
            return
        }
        if let zone = zoneLabel(at: point) {
            dive(into: zone)
        }
    }

    func zoneLabel(at point: NeuralPoint) -> NeuralZone? {
        let used = Set(owner.model.steps.map(\.zone))
        for zone in NeuralZone.allCases where used.contains(zone) {
            let rect = BrainPainter.zoneLabelRect(zone)
            if point.x >= rect.x - 4, point.x <= rect.x + rect.width + 4, point.y >= rect.y - 4,
                point.y <= rect.y + rect.height + 4
            {
                return zone
            }
        }
        return nil
    }

    /// The model changed under an open stage: a step arrived, a status moved, a node was chosen.
    func modelChanged() {
        tailscode_set_accessible_label(hit, owner.accessibleLabel)
        ensureRenderer()
    }

    func invalidate() {
        needsFull = true
        submitted = nil
    }

    /// How long the compositor takes for a frame on average, in milliseconds, and how many
    /// requests were replaced before they started.
    var composeReading: String {
        String(
            format: "compose=%.1fms dropped=%d inflight=%d main=%.0fus/frame", averageCompose * 1000,
            droppedJobs, inFlight ? 1 : 0, frames == 0 ? 0 : Double(mainNanoseconds) / Double(frames) / 1000)
    }

    /// Whether the compositor has no request running or waiting, for the harness.
    var isIdle: Bool { !inFlight && queued == nil }

    /// The nodes' centres in the head's design space, the obstacles a leader line goes around.
    var nodeCentres: [NeuralPoint] { scene.draws.map(\.point) }
}
