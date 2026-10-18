import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A card becoming the stage, or the stage becoming a card, in flight.
///
/// Core owns the choreography: `NeuralTransition` says where the head is, how tall the row is, how
/// far each node and wire has come, where the readout and footer stand and how visible every
/// piece is, for any progress. This holds the move that is running, and the view applies what it
/// is told on each frame of the display's own clock.
final class BrainMove: @unchecked Sendable {
    /// Which nodes, wires, ties and names are drawn at this instant.
    struct Reveal {
        var nodes: NeuralNodeReveal
        var wires: Double
        var ties: Double
        var labels: Double
    }

    /// How many times slower than Core's own timing the moves run, for a harness that looks at
    /// the frames of one.
    nonisolated(unsafe) static var timeScale = 1.0

    var transition: NeuralTransition
    var start: Double
    var opening: Bool
    let swapped: Bool
    let stageGeometry: NeuralTransition.Geometry
    let cardGeometry: NeuralTransition.Geometry
    let stageRect: NeuralRect
    let cardPicture: NeuralRect
    let metricsWidth: Double
    private(set) var frame: NeuralTransitionFrame
    private(set) var progress = 0.0
    var lastTick: Double?
    var gaps: [Double] = []
    var frames = 0
    var applyMicroseconds: [Double] = []

    /// Where the readout and the footer stand when the stage is open.
    var openingGeometry: NeuralTransition.Geometry { stageGeometry }

    init(
        transition: NeuralTransition, start: Double, opening: Bool, swapped: Bool,
        metrics: NeuralStageMetrics
    ) {
        self.transition = transition
        self.start = start
        self.opening = opening
        self.swapped = swapped
        stageGeometry = metrics.stageGeometry
        cardGeometry = metrics.cardGeometry
        stageRect = metrics.stage
        cardPicture = metrics.card.picture
        metricsWidth = metrics.width
        frame = transition.frame(at: 0, clock: BrainClock.now)
    }

    func advance(to u: Double, clock: Double = BrainClock.now) {
        progress = u
        frame = transition.frame(at: u, clock: clock)
    }

    /// The part of the move's travel the head has made, from the card's picture to the stage.
    var travelled: Double {
        let from = cardPicture.width
        let to = stageRect.width
        guard to > from else { return 1 }
        return min(1, max(0, (frame.traveller.width - from) / (to - from)))
    }
}

extension BrainView {
    /// Whether a move is in flight, for the clock and the harness.
    var isMoving: Bool { moveState != nil }

    func startOpeningIfReady() {
        guard let pending = pendingOpen, let stage, stage.hasPicture, !holdPictureForTest, phase == .closed else { return }
        pendingOpen = nil
        beginMove(opening: true, swapped: pending.swapped)
    }

    func startClosing(swapped: Bool) {
        beginMove(opening: false, swapped: swapped)
    }

    private func beginMove(opening: Bool, swapped: Bool) {
        let metrics = currentMetrics
        let direction: NeuralTransition.Direction =
            opening ? (swapped ? .swap : .open) : (swapped ? .swapClose : .close)
        let transition = NeuralTransition.make(
            direction, metrics: metrics, nodeCount: max(1, model.nodeCount),
            reduceMotion: BrainBudget.reduceMotion, level: CascadeBudget.level,
            live: model.turn.outcome == .running)
        let move = BrainMove(
            transition: transition, start: BrainClock.now, opening: opening, swapped: swapped,
            metrics: metrics)
        moveState = move
        stage?.enterLayered()
        host?.anchor?()
        if opening {
            host?.userOpened()
        }
        refreshReadout(animate: false)
        readout?.setBodyAlpha(opening ? 0 : 1)
        account?.setBodyAlpha(1)
        footer?.sync(BrainClock.now)
        if !opening { card.refresh() }
        setPhase(.moving)
        applyMove(at: BrainClock.now)
        updateClock()
    }

    func reverseMove() {
        guard let move = moveState else { return }
        let now = BrainClock.now
        let duration = move.transition.duration * BrainMove.timeScale
        let u = min(1, max(0, (now - move.start) / max(duration, 0.001)))
        move.transition = move.transition.reversed(from: u)
        move.opening.toggle()
        move.start = now
        move.advance(to: 0)
        move.lastTick = nil
        if move.opening {
            readout?.setBodyAlpha(0)
            account?.setBodyAlpha(1)
        } else {
            readout?.setBodyAlpha(1)
            account?.setBodyAlpha(1)
            contentFade = nil
        }
        applyMove(at: now)
        updateClock()
    }

    func moveStep(_ time: Double) {
        guard let move = moveState else { return }
        if let last = move.lastTick { move.gaps.append(time - last) }
        move.lastTick = time
        if frozen { return }
        let duration = max(move.transition.duration * BrainMove.timeScale, 0.001)
        let u = (time - move.start) / duration
        if u >= 1 {
            finishMove(snapTo: move.opening)
            return
        }
        move.advance(to: max(0, u), clock: time)
        applyMove(at: time)
    }

    private func applyMove(at time: Double) {
        guard let move = moveState else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let f = move.frame
        gtk_widget_set_opacity(card.surface, f.cardSurfaceAlpha)
        gtk_widget_set_opacity(card.edgeLive, f.cardSurfaceAlpha)
        gtk_widget_set_opacity(card.text, f.cardTextAlpha)
        gtk_widget_set_opacity(card.buttons, f.cardTextAlpha)
        gtk_widget_set_opacity(card.picture, f.cardPictureAlpha)
        if let edgeCanvas { gtk_widget_set_opacity(edgeCanvas, f.edge.alpha) }
        if let readout { gtk_widget_set_opacity(readout.widget, f.readoutAlpha) }
        if let account { gtk_widget_set_opacity(account.root, f.readoutAlpha) }
        if let footer { gtk_widget_set_opacity(footer.widget, f.footerAlpha) }
        if let filters { gtk_widget_set_opacity(filters.canvas, f.panelAlpha) }
        list?.setReveal(f.listRows, headerAlpha: f.listHeaderAlpha)
        if let list { gtk_widget_set_opacity(list.entry, f.listHeaderAlpha) }
        let labels = f.nodes.count > 0 ? f.nodes.alpha(0) : f.wireDraw
        revealOverride = BrainMove.Reveal(nodes: f.nodes, wires: f.wireDraw, ties: f.tieDraw, labels: labels)
        stage?.refreshScene(time)
        if let moveCanvas { gtk_widget_queue_draw(moveCanvas) }
        if let edgeCanvas { gtk_widget_queue_draw(edgeCanvas) }
        relayout()
        move.applyMicroseconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1000)
    }

    /// Lands the move: at its end the stage or the card stands exactly as it would have without
    /// any move, which is why nothing is redrawn to match.
    func finishMove(snapTo opening: Bool) {
        guard let move = moveState else { return }
        host?.anchor?()
        moveState = nil
        revealOverride = nil
        for part in [card.surface, card.edgeLive, card.text, card.buttons, card.picture] {
            gtk_widget_set_opacity(part, 1)
        }
        if let edgeCanvas { gtk_widget_set_opacity(edgeCanvas, 0) }
        if let readout { gtk_widget_set_opacity(readout.widget, 1) }
        if let account { gtk_widget_set_opacity(account.root, 1) }
        if let footer { gtk_widget_set_opacity(footer.widget, 1) }
        if let filters { gtk_widget_set_opacity(filters.canvas, 1) }
        list?.setReveal(nil, headerAlpha: 1)
        if let list { gtk_widget_set_opacity(list.entry, 1) }
        recordMove(move)
        if opening {
            stage?.leaveLayered()
            setPhase(.open)
            stage?.invalidate()
            stage?.render(BrainClock.now)
            footer?.sync(BrainClock.now)
            refreshReadout(animate: false)
            contentFadeStart = BrainClock.now
            contentFade = BrainBudget.reduceMotion ? nil : 0
            readout?.setBodyAlpha(contentFade == nil ? 1 : 0)
            account?.setBodyAlpha(1)
            applyPendingDive()
            refitFooterSoon()
        } else {
            hideStage()
        }
        host?.moveFinished(self, opening: opening)
        relayout()
        updateClock()
    }

    private func recordMove(_ move: BrainMove) {
        let gaps = move.gaps
        guard !gaps.isEmpty else { return }
        let worst = gaps.max() ?? 0
        BrainMoveLog.record(
            opening: move.opening, frames: gaps.count + 1, maximumGap: worst, gaps: gaps,
            apply: move.applyMicroseconds)
        Trace.mark(
            String(
                format: "brain move %@ frames=%d max gap %.1f ms mean apply %.0f us",
                move.opening ? "open" : "close", gaps.count + 1, worst * 1000,
                move.applyMicroseconds.isEmpty
                    ? 0 : move.applyMicroseconds.reduce(0, +) / Double(move.applyMicroseconds.count)))
    }

    func installMoveCanvas() {
        guard moveCanvas == nil else { return }
        let holder = MoveHolder()
        holder.view = self
        _ = Gtk.releaseInstalled
        let canvas = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                Unmanaged<MoveHolder>.fromOpaque(raw).takeUnretainedValue().view?.paintMove(
                    cr, width: Double(width), height: Double(height))
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<MoveHolder>.fromOpaque(raw).release()
            })!
        gtk_widget_set_can_target(canvas, 0)
        gtk_widget_set_can_focus(canvas, 0)
        tailscode_set_accessible_hidden(canvas, 1)
        tailscode_brain_row_add(widget, canvas)
        moveCanvas = canvas
        let edgeHolder = MoveHolder()
        edgeHolder.view = self
        let edge = tailscode_canvas_new(
            { cr, width, height, raw in
                guard let cr, let raw else { return }
                Unmanaged<MoveHolder>.fromOpaque(raw).takeUnretainedValue().view?.paintEdge(
                    cr, width: Double(width), height: Double(height))
            }, Unmanaged.passRetained(edgeHolder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<MoveHolder>.fromOpaque(raw).release()
            })!
        gtk_widget_set_can_target(edge, 0)
        gtk_widget_set_can_focus(edge, 0)
        tailscode_set_accessible_hidden(edge, 1)
        gtk_widget_set_opacity(edge, 0)
        tailscode_brain_row_add(widget, edge)
        edgeCanvas = edge
    }

    /// The card's tone edge as it rides the head's left side for the first moments of a move.
    private func paintEdge(_ cr: OpaquePointer, width: Double, height: Double) {
        let tone = inks.corrected(card.card.edgeTone)
        BrainPainter.round(cr, 0, 0, width, height, 1.5)
        cairo_set_source_rgba(cr, tone.red, tone.green, tone.blue, 1)
        cairo_fill(cr)
    }

    final class MoveHolder: @unchecked Sendable {
        weak var view: BrainView?
    }

    /// The head as the traveller: the stage's own two pictures scaled into the rectangle the
    /// move gives it, the card's lights over them while they last, the nodes between the pictures
    /// at the traveller's own scale, and the sweep that powers the head on.
    private func paintMove(_ cr: OpaquePointer, width: Double, height: Double) {
        guard let move = moveState, let stage, let pictures = stage.pictures else { return }
        let f = move.frame
        let inks = self.inks
        let travelled = move.travelled
        let rect = NeuralRect(x: 0, y: 0, width: width, height: height)
        cairo_save(cr)
        let radius = 8 * (1 - travelled)
        BrainPainter.round(cr, 0, 0, width, height, radius)
        cairo_clip(cr)
        if f.travellerAlpha < 0.999 { cairo_push_group(cr) }
        BrainCardPainter.layer(
            cr, surface: pictures.interior, logicalWidth: pictures.width, logicalHeight: pictures.height,
            rect: rect)
        let mapping = BrainCardPainter.Mapping(
            x: 0, y: 0, scale: width / NeuralStageMetrics.designWidth)
        let lift = 1 - f.zoneLift
        let breath = move.transition.live ? card.card.live?.activeZone : nil
        BrainCardPainter.lights(
            cr, card: card.card, mapping: mapping, inks: inks, hovered: false, lift: lift,
            breathing: breath.map { ($0, f.travellerSwell) })
        if let zone = breath {
            BrainCardPainter.lights(
                cr, card: card.card, mapping: mapping, inks: inks, hovered: false,
                lift: (1 - lift) * 0.5 * f.travellerSwell, only: zone)
        }
        BrainCardPainter.rings(cr, card: card.card, mapping: mapping, inks: inks, alpha: lift)
        BrainPainter.paint(cr, width: Int32(width.rounded()), height: Int32(height.rounded()), scene: stage.scene, inks: inks)
        BrainCardPainter.layer(
            cr, surface: pictures.front, logicalWidth: pictures.width, logicalHeight: pictures.height,
            rect: rect)
        if f.sweepAmount > 0.002 { sweep(cr, f, width: width, height: height) }
        if f.travellerAlpha < 0.999 {
            cairo_pop_group_to_source(cr)
            cairo_paint_with_alpha(cr, f.travellerAlpha)
        }
        cairo_restore(cr)
    }

    /// The band that crosses the head once as it powers on: a bright slant in the live tone
    /// screened over the picture, rising and falling with the sweep's own envelope.
    private func sweep(_ cr: OpaquePointer, _ f: NeuralTransitionFrame, width: Double, height: Double) {
        let live = inks.live
        let centre = (-0.25 + 1.5 * f.sweepPhase) * width
        let half = 0.14 * width
        let direction = (x: 0.966, y: 0.259)
        let gradient = cairo_pattern_create_linear(
            centre - direction.x * half, height / 2 - direction.y * half, centre + direction.x * half,
            height / 2 + direction.y * half)
        let peak = 0.7 * f.sweepAmount
        cairo_pattern_add_color_stop_rgba(gradient, 0, live.red, live.green, live.blue, 0)
        cairo_pattern_add_color_stop_rgba(gradient, 0.5, live.red, live.green, live.blue, peak)
        cairo_pattern_add_color_stop_rgba(gradient, 1, live.red, live.green, live.blue, 0)
        cairo_save(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_SCREEN)
        cairo_set_source(cr, gradient)
        cairo_rectangle(cr, 0, 0, width, height)
        cairo_fill(cr)
        cairo_restore(cr)
        cairo_pattern_destroy(gradient)
    }

    /// Freezes the move at a progress, for a screenshot: the frames of the move are what Core
    /// computes there, and nothing runs until the next press.
    func freezeMove(opening: Bool, at progress: Double, attempt: Int = 0) {
        guard NeuralAssetFiles.isAvailable else { return }
        makeFrozenParts()
        stage?.enterLayered()
        if stage?.hasPicture != true, attempt < 24 {
            Gtk.after(300) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, !self.disposed else { return }
                    self.freezeMove(opening: opening, at: progress, attempt: attempt + 1)
                }
            }
            return
        }
        let metrics = currentMetrics
        let direction: NeuralTransition.Direction = opening ? .open : .close
        let transition = NeuralTransition.make(
            direction, metrics: metrics, nodeCount: max(1, model.nodeCount),
            reduceMotion: BrainBudget.reduceMotion, level: CascadeBudget.level,
            live: model.turn.outcome == .running)
        let move = BrainMove(
            transition: transition, start: .infinity, opening: opening, swapped: false, metrics: metrics)
        move.advance(to: progress)
        moveState = move
        frozen = true
        refreshReadout(animate: false)
        readout?.setBodyAlpha(opening ? (progress >= 1 ? 1 : 0) : 1)
        account?.setBodyAlpha(1)
        setPhase(.moving)
        applyMove(at: BrainClock.now)
    }

    /// Lets a frozen move go: the arrangement it was heading for stands.
    func releaseFrozenMove() {
        guard frozen, let move = moveState else { return }
        frozen = false
        finishMove(snapTo: move.opening)
    }
}

/// How the moves went, kept to say so: the selftest and the harness read it.
enum BrainMoveLog {
    nonisolated(unsafe) private(set) static var moves = 0
    nonisolated(unsafe) private(set) static var worstGap = 0.0
    nonisolated(unsafe) private(set) static var lastGaps: [Double] = []
    nonisolated(unsafe) private(set) static var lastApply: [Double] = []
    nonisolated(unsafe) private(set) static var lastOpening = true
    nonisolated(unsafe) private(set) static var lastFrames = 0

    static func record(opening: Bool, frames: Int, maximumGap: Double, gaps: [Double], apply: [Double]) {
        moves += 1
        worstGap = max(worstGap, maximumGap)
        lastGaps = gaps
        lastApply = apply
        lastOpening = opening
        lastFrames = frames
    }

    static func reset() {
        moves = 0
        worstGap = 0
        lastGaps = []
        lastApply = []
    }
}
