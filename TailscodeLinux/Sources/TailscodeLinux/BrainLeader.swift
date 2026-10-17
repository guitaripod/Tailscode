import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The line from the node being read to the readout beside the head: cached per step and per
/// width, drawn along its length when it appears and faded when it goes, and never there in a
/// stacked row, which has no readout beside it.
struct BrainLeaderState {
    struct Leg {
        let stepID: String
        let zone: NeuralZone
        /// The route in the head's design space, from the node to the anchor on the readout's edge.
        let route: [NeuralPoint]
        let node: NeuralPoint
        let anchor: NeuralPoint
        let width: Double
        let revision: Int
        let start: Double
        var fadeStart: Double?
        let length: Double
        let pinned: Bool
    }

    static let drawTime = 0.120
    static let fadeTime = 0.120

    var current: Leg?
    var leaving: [Leg] = []
    /// How many routes were searched since the stage opened: a step costs one, whatever the frames.
    var searches = 0
    var wasAnimating = false

    var reading: String {
        guard let current else { return leaving.isEmpty ? "-" : "leaving" }
        return "\(current.stepID) pts=\(current.route.count) len=\(Int(current.length))"
    }

    func isAnimating(at time: Double) -> Bool {
        if let current, time - current.start < Self.drawTime { return true }
        return leaving.contains { leg in
            guard let fade = leg.fadeStart else { return false }
            return time - fade < Self.fadeTime
        }
    }
}

extension BrainView {
    var leaderAnimating: Bool { leaderState.isAnimating(at: BrainClock.now) }

    /// Points the leader at the step the readout is about, from a reading of it: nothing for a
    /// panel that is about no step, and nothing in a stacked row.
    func updateLeader(for readout: NeuralReadout?) {
        let metrics = currentMetrics
        let wanted: String? = metrics.hasLeader && stage != nil && phase == .open ? readout?.leaderStepID : nil
        let now = BrainClock.now
        if let current = leaderState.current,
            wanted != current.stepID || current.width != metrics.width
                || current.revision != model.revision
        {
            var gone = current
            gone.fadeStart = now
            leaderState.leaving.append(gone)
            leaderState.current = nil
        }
        leaderState.leaving.removeAll { leg in
            guard let fade = leg.fadeStart else { return true }
            return now - fade > BrainLeaderState.fadeTime
        }
        if leaderState.current == nil, let wanted, let leg = makeLeg(for: wanted, metrics: metrics, at: now) {
            leaderState.current = leg
        }
        if let stage { gtk_widget_queue_draw(stage.leader) }
        if leaderState.isAnimating(at: now) { updateClock() }
    }

    private func makeLeg(for id: String, metrics: NeuralStageMetrics, at time: Double) -> BrainLeaderState.Leg? {
        guard let step = model.step(id: id), let node = model.point(of: model.layout.representative(of: id)),
            let anchor = metrics.leaderAnchor(forNodeAt: node), let stage
        else { return nil }
        let route = NeuralLeader.route(from: node, to: anchor, around: stage.nodeCentres)
        leaderState.searches += 1
        return BrainLeaderState.Leg(
            stepID: id, zone: step.zone, route: route, node: node, anchor: anchor, width: metrics.width,
            revision: model.revision, start: BrainBudget.reduceMotion ? time - 1 : time, fadeStart: nil,
            length: NeuralLeader.length(route), pinned: model.pinnedStep == id)
    }

    func tickLeader(_ time: Double) {
        guard let stage else { return }
        if !leaderState.leaving.isEmpty || leaderState.current != nil {
            leaderState.leaving.removeAll { leg in
                guard let fade = leg.fadeStart else { return true }
                return time - fade > BrainLeaderState.fadeTime
            }
            let animating = leaderState.isAnimating(at: time)
            if animating || leaderState.wasAnimating { gtk_widget_queue_draw(stage.leader) }
            leaderState.wasAnimating = animating
        }
    }

    /// Paints the leader and the stage's focus ring on the layer above the head.
    func paintLeader(_ cr: OpaquePointer, width: Double, height: Double) {
        guard let stage else { return }
        let metrics = currentMetrics
        let now = BrainClock.now
        if stage.scene.focused {
            let rect = metrics.stage
            let accent = inks.accent
            cairo_save(cr)
            BrainPainter.round(cr, 1, 1, rect.width - 2, rect.height - 2, 10)
            cairo_set_source_rgba(cr, accent.red, accent.green, accent.blue, 0.55)
            cairo_set_line_width(cr, 2)
            cairo_stroke(cr)
            cairo_restore(cr)
        }
        guard metrics.hasLeader else { return }
        for leg in leaderState.leaving {
            guard let fade = leg.fadeStart else { continue }
            let alpha = max(0, 1 - (now - fade) / BrainLeaderState.fadeTime)
            drawLeg(cr, leg, progress: 1, alpha: alpha, metrics: metrics, stage: stage)
        }
        if let leg = leaderState.current {
            let progress = BrainBudget.reduceMotion ? 1 : min(1, (now - leg.start) / BrainLeaderState.drawTime)
            let eased = NeuralTransition.easeOutCubic(progress)
            drawLeg(cr, leg, progress: eased, alpha: 1, metrics: metrics, stage: stage)
        }
    }

    private func drawLeg(
        _ cr: OpaquePointer, _ leg: BrainLeaderState.Leg, progress: Double, alpha: Double,
        metrics: NeuralStageMetrics, stage: BrainStage
    ) {
        let unit = stage.unit
        guard unit > 0, alpha > 0.002 else { return }
        let tone = inks.corrected(leg.zone)
        let crop = NeuralStageMetrics.designCrop
        let zoomed = abs(stage.zoom - 1) > 0.001
        var points: [NeuralPoint]
        if zoomed {
            points = pixelRoute(from: leg.node, to: leg.anchor, stage: stage, metrics: metrics)
        } else {
            points = leg.route.map { NeuralPoint(($0.x - crop.x) * unit, $0.y * unit) }
        }
        guard points.count > 1 else { return }
        let nodeRadius = NeuralDesign.nodeRadius * unit * stage.zoom
        let drawn = NeuralLeader.partial(progress, of: points)
        cairo_save(cr)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        cairo_set_source_rgba(cr, tone.red, tone.green, tone.blue, 0.7 * alpha)
        cairo_set_line_width(cr, 1.25)
        cairo_new_path(cr)
        for (index, point) in drawn.enumerated() {
            if index == 0 {
                cairo_move_to(cr, point.x, point.y)
            } else {
                cairo_line_to(cr, point.x, point.y)
            }
        }
        cairo_stroke(cr)
        cairo_set_source_rgba(cr, tone.red, tone.green, tone.blue, 0.8 * alpha)
        cairo_new_path(cr)
        cairo_arc(cr, points[0].x, points[0].y, nodeRadius + 5 * unit, 0, 2 * .pi)
        cairo_stroke(cr)
        if progress >= 0.999, let end = points.last {
            cairo_set_source_rgba(cr, tone.red, tone.green, tone.blue, alpha)
            cairo_new_path(cr)
            cairo_arc(cr, end.x, end.y, 2.5, 0, 2 * .pi)
            cairo_fill(cr)
            let size = NeuralStageMetrics.tabSize
            BrainPainter.round(
                cr, end.x - (size.width - 1) / 2, end.y - size.height / 2, size.width, size.height, 1)
            cairo_fill(cr)
        }
        cairo_restore(cr)
    }

    /// The route of a dived head, in the stage's own points: the node is where the zoom put it,
    /// the line leaves it level, runs a diagonal and ends level on the readout's edge.
    private func pixelRoute(
        from node: NeuralPoint, to anchor: NeuralPoint, stage: BrainStage, metrics: NeuralStageMetrics
    ) -> [NeuralPoint] {
        let start = stage.screen(node)
        let crop = NeuralStageMetrics.designCrop
        let unit = stage.unit
        let end = NeuralPoint((anchor.x - crop.x) * unit, anchor.y * unit)
        let target = NeuralPoint(end.x, min(max(start.y, 56), max(56, metrics.stage.height - 48)))
        let stub = 18.0
        let first = NeuralPoint(start.x + stub, start.y)
        let rise = abs(target.y - start.y)
        var points = [start, first]
        if rise > 1 {
            let along = max(first.x, target.x - rise - 10)
            points.append(NeuralPoint(along, start.y))
            points.append(NeuralPoint(along + rise, target.y))
        }
        points.append(target)
        return points
    }
}
