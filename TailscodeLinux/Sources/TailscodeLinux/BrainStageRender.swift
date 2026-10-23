import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension BrainStage {
    func currentTable() -> NeuralToneTable {
        NeuralToneTable(palette: MatrixTheme.palette, face: owner.model.face)
    }

    /// Makes sure a compositor of the right size and look is held, asking for one when it is not.
    func ensureRenderer() {
        guard !torndown, !owner.isSuspended, NeuralAssetFiles.isAvailable, let target = targetSize()
        else { return }
        let wanted = currentTable()
        if compositor != nil, surfaceSize == target, table == wanted { return }
        if let requested, requested.width == target.width, requested.height == target.height,
            requested.table == wanted
        {
            return
        }
        requested = (target.width, target.height, wanted)
        BrainCompositors.acquire(width: target.width, height: target.height, table: wanted) {
            [weak self] built in
            guard let self, !self.torndown, !self.owner.isSuspended,
                let request = self.requested, request.width == target.width,
                request.height == target.height, request.table == wanted, let built
            else {
                if let built { BrainCompositors.release(built) }
                return
            }
            self.requested = nil
            if let held = self.compositor { BrainCompositors.release(held) }
            self.compositor = built
            self.table = wanted
            self.surfaceSize = target
            self.composer = Composer(compositor: built)
            self.generation += 1
            self.inFlight = false
            self.queued = nil
            self.submitted = nil
            self.hasDrawn = false
            tailscode_layer_resize_scaled(self.interior, Int32(target.width), Int32(target.height), target.scale)
            tailscode_layer_resize_scaled(self.front, Int32(target.width), Int32(target.height), target.scale)
            let cut = self.croppedWidth(of: target.width)
            tailscode_layer_resize_scaled(self.merged, Int32(cut.width), Int32(target.height), target.scale)
            let offset = NeuralStageMetrics.designCrop.x / NeuralDesign.width
                * Double(target.width) / target.scale
            tailscode_layer_set_offset(self.interior, offset, 0)
            tailscode_layer_set_offset(self.front, offset, 0)
            self.needsFull = true
            self.owner.stageRendererReady()
        }
    }

    /// Where the stage's own part of a picture rendered over the whole design space begins and how
    /// wide it is, in device pixels: the head is trimmed to design x 64 to 640.
    func croppedWidth(of width: Int) -> (offset: Int, width: Int) {
        let offset = Int((NeuralStageMetrics.designCrop.x / NeuralDesign.width * Double(width)).rounded())
        return (offset, max(1, width - offset))
    }

    /// Draws the head as three layers: the picture is copied to each, the nodes get their own
    /// canvas, and a dive's zoom and a move's scaling can treat them apart.
    func enterLayered() {
        guard !layered else { return }
        layered = true
        needsFull = true
        submitted = nil
        if let composer, !inFlight, hasDrawn {
            let (w, h) = (surfaceSize.width, surfaceSize.height)
            composer.pair.interior.bytes.withUnsafeBufferPointer {
                tailscode_layer_blit(interior, $0.baseAddress, Int32(w), Int32(h), 0, 0, Int32(w), Int32(h))
            }
            composer.pair.front.bytes.withUnsafeBufferPointer {
                tailscode_layer_blit(front, $0.baseAddress, Int32(w), Int32(h), 0, 0, Int32(w), Int32(h))
            }
        }
        owner.relayout()
    }

    /// Goes back to one picture once nothing needs the layers apart.
    func leaveLayered() {
        guard layered, dive == nil, diveZone == nil else { return }
        layered = false
        needsFull = true
        submitted = nil
        owner.relayout()
        owner.redrawNow()
    }

    /// Composes the head as one picture from the compositor's two and the nodes between them. Run
    /// on the main loop whenever the picture or the nodes changed, only while the compositor is
    /// idle, because the surfaces it reads are the one it draws into.
    func recompose() {
        guard !layered, let composer, !inFlight, hasDrawn,
            let surface = tailscode_layer_surface(merged)
        else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let full = surfaceSize
        let cut = croppedWidth(of: full.width)
        let scale = full.scale
        cairo_surface_flush(surface)
        guard let cr = cairo_create(surface) else { return }
        func lay(_ bytes: [UInt8], operator mode: cairo_operator_t) {
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let source = cairo_image_surface_create_for_data(
                    UnsafeMutablePointer(mutating: base) + cut.offset * 4, CAIRO_FORMAT_ARGB32,
                    Int32(cut.width), Int32(full.height), Int32(full.width * 4))
                cairo_surface_set_device_scale(source, scale, scale)
                cairo_set_operator(cr, mode)
                cairo_set_source_surface(cr, source, 0, 0)
                cairo_paint(cr)
                cairo_surface_destroy(source)
            }
        }
        lay(composer.pair.interior.bytes, operator: CAIRO_OPERATOR_SOURCE)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        BrainPainter.paint(cr, width: Int32(logical.width), height: Int32(logical.height), scene: scene, inks: inks)
        lay(composer.pair.front.bytes, operator: CAIRO_OPERATOR_OVER)
        cairo_destroy(cr)
        cairo_surface_mark_dirty(surface)
        gtk_widget_queue_draw(merged)
        recomposeNanoseconds += DispatchTime.now().uptimeNanoseconds - started
        recomposes += 1
    }

    /// The look changed: another palette, or another model answered.
    func retheme() {
        inks = BrainInks(palette: MatrixTheme.palette, face: owner.model.face)
        ensureRenderer()
        needsFull = true
        owner.redrawNow()
    }

    /// One frame: the head's picture, then the nodes over it.
    func step(_ time: Double) {
        guard !torndown else { return }
        if let active = dive, time - active.start >= active.duration { finishDive(at: time) }
        render(time)
    }

    /// The nodes breathe slowly, so they are repainted at fifteen frames a second while only that
    /// moves, and at once when anything about them is chosen, arrives or is dived into: the
    /// software renderer rasterises a whole layer for every repaint of it.
    func nodesDue(_ time: Double, state scale: Double) -> Bool {
        let model = owner.model
        let signature = NodesKey(
            revision: model.revision, selected: model.selected, hovered: model.hovered,
            token: model.provenanceToken, zoom: scale, reveal: owner.revealOverride != nil,
            replaying: model.isReplaying, focused: gtk_widget_has_focus(hit) != 0)
        defer { lastNodesKey = signature }
        if signature != lastNodesKey || model.isReplaying || owner.revealOverride != nil || scale != 1 {
            lastNodesDraw = time
            return true
        }
        if time - lastNodesDraw >= Self.nodesInterval {
            lastNodesDraw = time
            return true
        }
        return false
    }

    struct NodesKey: Equatable {
        let revision: Int
        let selected: String?
        let hovered: String?
        let token: String?
        let zoom: Double
        let reveal: Bool
        let replaying: Bool
        let focused: Bool
    }

    static let nodesInterval = 1.0 / 15

    /// Asks for the picture at `time`: the scene is built here, which is cheap, and the head's
    /// two pictures are drawn by the compositor off the main loop, the newest request replacing
    /// one that has not started. A frame that changes nothing asks for nothing.
    func render(_ time: Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        frames += 1
        let reduce = BrainBudget.reduceMotion
        let state = currentDive(at: time)
        let frame = owner.model.frame(time: time, reduceMotion: reduce)
        if drawing || !hasDrawn, composer != nil, !Self.debugSkip.contains("compose") {
            let whole = submitted == nil || needsFull || state.dive != submittedDive
            if whole || frame != submitted || !frame.settled {
                let interval = minimumInterval
                if whole || time - lastSubmitTime >= interval {
                    submit(
                        Job(
                            frame: frame, dive: state.dive,
                            stamp: Float(time.truncatingRemainder(dividingBy: 1000)), full: whole),
                        at: time)
                    submitted = frame
                    submittedDive = state.dive
                }
            }
        }
        let crop = NeuralStageMetrics.designCrop
        tailscode_layer_zoom(
            interior, (state.dive.center.x * NeuralDesign.width - crop.x) / crop.width,
            state.dive.center.y, state.scale)
        buildScene(time, scale: state.scale, reduce: reduce, zone: state.zone)
        if !Self.debugSkip.contains("nodes"), nodesDue(time, state: state.scale) {
            if layered {
                gtk_widget_queue_draw(nodes)
            } else if inFlight {
                recomposePending = true
            } else {
                recompose()
            }
        }
        if state.scale != 1 || isDiving { gtk_widget_queue_draw(leader) }
        frameNanoseconds += DispatchTime.now().uptimeNanoseconds - started
        mainNanoseconds += DispatchTime.now().uptimeNanoseconds - started
    }

    /// The gap kept between two requests when the compositor is slower than a frame budget: three
    /// times what it took, so a slow machine draws fewer pictures rather than falling behind.
    var minimumInterval: Double {
        averageCompose > 0.010 ? averageCompose * 2.5 : 0
    }

    func submit(_ job: Job, at time: Double) {
        lastSubmitTime = time
        if inFlight {
            if var held = queued {
                held = Job(frame: job.frame, dive: job.dive, stamp: job.stamp, full: held.full || job.full)
                queued = held
                droppedJobs += 1
            } else {
                queued = job
            }
            needsFull = false
            return
        }
        start(job)
    }

    func start(_ job: Job) {
        guard let composer else { return }
        inFlight = true
        needsFull = false
        let mine = generation
        composer.queue.async { [weak self] in
            let outcome = composer.run(job)
            Gtk.onMain { [weak self] in self?.completed(outcome, generation: mine, composer: composer) }
        }
    }

    /// Copies a held part of the front picture to its layer once the compositor has gone quiet.
    func flushFront(generation made: Int) {
        guard !torndown, made == generation, !inFlight, let held = frontPending, let composer else { return }
        frontPending = nil
        lastFrontBlit = BrainClock.now
        let (w, h) = (surfaceSize.width, surfaceSize.height)
        composer.pair.front.bytes.withUnsafeBufferPointer {
            tailscode_layer_blit(front, $0.baseAddress, Int32(w), Int32(h), Int32(held.minX), Int32(held.minY), Int32(held.width), Int32(held.height))
        }
    }

    func completed(_ outcome: Outcome, generation made: Int, composer finished: Composer) {
        guard !torndown, made == generation, composer === finished else { return }
        inFlight = false
        let first = !hasDrawn
        hasDrawn = true
        let seconds = Double(outcome.nanoseconds) / 1_000_000_000
        if outcome.drew { averageCompose = averageCompose == 0 ? seconds : averageCompose * 0.8 + seconds * 0.2 }
        if !layered, outcome.drew || recomposePending, !Self.debugSkip.contains("blit") {
            recomposePending = false
            recompose()
            if outcome.whole { fullNanoseconds += outcome.nanoseconds; fulls += 1 } else {
                deltaNanoseconds += outcome.nanoseconds
                deltaFrames += 1
            }
        } else if outcome.drew, !Self.debugSkip.contains("blit") {
            let (w, h) = (surfaceSize.width, surfaceSize.height)
            let region = outcome.region
            if outcome.whole {
                finished.pair.interior.bytes.withUnsafeBufferPointer {
                    tailscode_layer_blit(interior, $0.baseAddress, Int32(w), Int32(h), 0, 0, Int32(w), Int32(h))
                }
                finished.pair.front.bytes.withUnsafeBufferPointer {
                    tailscode_layer_blit(front, $0.baseAddress, Int32(w), Int32(h), 0, 0, Int32(w), Int32(h))
                }
                frontPending = nil
                lastFrontBlit = BrainClock.now
                fullNanoseconds += outcome.nanoseconds
                fulls += 1
            } else {
                finished.pair.interior.bytes.withUnsafeBufferPointer {
                    if outcome.ripple {
                        tailscode_layer_blit(interior, $0.baseAddress, Int32(w), Int32(h), 0, 0, Int32(w), Int32(h))
                    } else if !region.isEmpty {
                        tailscode_layer_blit(interior, $0.baseAddress, Int32(w), Int32(h), Int32(region.minX), Int32(region.minY), Int32(region.width), Int32(region.height))
                    }
                }
                if !region.isEmpty {
                    frontPending = frontPending.map { $0.union(region) } ?? region
                }
                let now = BrainClock.now
                if let held = frontPending, now - lastFrontBlit >= Self.frontInterval {
                    frontPending = nil
                    lastFrontBlit = now
                    finished.pair.front.bytes.withUnsafeBufferPointer {
                        tailscode_layer_blit(front, $0.baseAddress, Int32(w), Int32(h), Int32(held.minX), Int32(held.minY), Int32(held.width), Int32(held.height))
                    }
                }
                deltaNanoseconds += outcome.nanoseconds
                deltaFrames += 1
                if deltaFrames == 60 {
                    Trace.mark(
                        "brain delta frame \(Int(timings.delta)) us, full frame \(Int(timings.full)) us at \(surfaceSize.width)x\(surfaceSize.height)")
                }
            }
        }
        if frontPending != nil {
            let mine = generation
            Gtk.after(UInt32(Self.frontInterval * 1000) + 20) { [weak self] in
                Gtk.onMain { [weak self] in self?.flushFront(generation: mine) }
            }
        }
        if let next = queued {
            queued = nil
            start(next)
        }
        if first { owner.stagePictureReady() }
    }

    /// The nodes, wires and ties as they stand at `time`, without touching the picture: what a
    /// move draws between the head's two pictures while the stage's own layers are not shown.
    func refreshScene(_ time: Double) {
        let state = currentDive(at: time)
        buildScene(time, scale: state.scale, reduce: BrainBudget.reduceMotion, zone: state.zone)
    }

    func buildScene(_ time: Double, scale: Double, reduce: Bool, zone: NeuralZone?) {
        let model = owner.model
        var next = BrainScene()
        next.draws = NeuralNodes.draws(model: model, time: time, reduceMotion: reduce)
        let wireKey = WireKey(
            revision: model.revision, selected: model.selected, hovered: model.hovered,
            token: model.provenanceToken, reduce: reduce)
        if model.mode == .live, let held = wires, held.key == wireKey {
            next.wires = held.value
        } else {
            let made = NeuralNodes.wires(model: model, time: time, reduceMotion: reduce)
            next.wires = made
            wires = model.mode == .live ? (wireKey, made) : nil
        }
        next.time = time
        next.reduceMotion = reduce
        next.hasSelection = model.hovered != nil
        next.dimmed = owner.dimmedNodes
        next.cursor = owner.ringed(model.pinnedStep)
        next.preview = model.browseState.hovered.flatMap { $0 == model.pinnedStep ? nil : owner.ringed($0) }
        next.usedZones = Set(model.steps.map(\.zone))
        next.zoom = scale
        let center = (zone ?? .think).center
        next.zoomCenter = zone == nil ? NeuralPoint(320, 210) : center
        next.orbit = owner.model.frame(time: time, reduceMotion: reduce).orbit
        next.crowded = model.nodeCount > 60
        next.hotZone = model.selectedZone
        next.focused = gtk_widget_has_focus(hit) != 0
        if let reveal = owner.revealOverride {
            next.reveal = reveal.nodes
            next.wireDraw = reveal.wires
            next.tieDraw = reveal.ties
            next.labelAlpha = reveal.labels
        }
        scene = next
    }

    func drawNodes(_ cr: OpaquePointer, width: Int32, height: Int32) {
        let begun = DispatchTime.now().uptimeNanoseconds
        BrainPainter.paint(cr, width: width, height: height, scene: scene, inks: inks)
        nodeNanoseconds += DispatchTime.now().uptimeNanoseconds - begun
        nodeDraws += 1
    }

    func drawLeader(_ cr: OpaquePointer, width: Int32, height: Int32) {
        let begun = DispatchTime.now().uptimeNanoseconds
        owner.paintLeader(cr, width: Double(width), height: Double(height))
        leaderNanoseconds += DispatchTime.now().uptimeNanoseconds - begun
        leaderDraws += 1
    }
}
