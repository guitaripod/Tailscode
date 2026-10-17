import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What the window's budget lets a brain do, read where it is drawn. The governor's levels are the
/// whole answer: calm and busy draw everything at the activity tempo, loaded slows the clock, from
/// strained up nothing breathes (the ripple, the sweep and the crunch go, and every state is held
/// still in its own tone), and at critical nothing opens by itself: a head the person opens is
/// still built, once, as a settled picture with no clock and no move.
///
/// The verdict that the head may not be drawn has hysteresis: the level has to stay at critical for
/// three seconds before it is entered and below it for ten before it is left, so a window hovering
/// at the threshold cannot make every head give up its picture and take it again.
enum BrainBudget {
    static var reduceMotion: Bool { !RepeatingMotion.allowed }
    static var stageAllowed: Bool { allowed }

    /// How long the level must stay at critical before the stage is given up, and how long below
    /// it before the stage is taken again, in seconds.
    nonisolated(unsafe) static var enterDelay = 3.0
    nonisolated(unsafe) static var leaveDelay = 10.0
    nonisolated(unsafe) private static var allowed = true
    nonisolated(unsafe) private static var ticket = 0

    /// How many times the verdict has changed since launch.
    nonisolated(unsafe) private(set) static var flips = 0

    /// The governor moved. Starts the clock on the verdict that would follow and lets it go
    /// again if the level comes back first. `flipped` runs on the main loop when the verdict
    /// changes.
    static func observe(flipped: @escaping @Sendable () -> Void) {
        let critical = CascadeBudget.level >= .critical
        ticket += 1
        let mine = ticket
        guard critical == allowed else { return }
        let delay = critical ? enterDelay : leaveDelay
        Gtk.after(UInt32(delay * 1000)) {
            Gtk.onMain {
                guard ticket == mine, (CascadeBudget.level >= .critical) == critical else { return }
                allowed = !critical
                flips += 1
                flipped()
            }
        }
    }

    /// Puts the verdict back to allowed with nothing pending, for a harness.
    static func reset() {
        ticket += 1
        allowed = true
    }

    /// Holds the verdict, for a harness that looks at what a shed window does.
    static func force(allowed value: Bool) {
        ticket += 1
        allowed = value
    }
}

/// The open brain's head: the interior, the nodes, the front, the leader's own layer and the
/// surface the pointer and the keyboard land on, each a widget the row places at the rectangle
/// Core's metrics give it.
///
/// The head's two pictures come from Core's CPU compositor: a full frame when the look, the size or
/// the dive changes, and a delta for everything else, copied row by row into cairo surfaces the
/// shim owns. The compositor draws the whole design space; the layers show the part of it the
/// stage keeps (design x 64 to 640), so the chassis is flush with the column's left edge. The nodes
/// are painted over the interior and under the front with cairo, so they sit inside the glass, and
/// the leader line is painted over all of it, because it has to leave the head to reach the readout.
/// Nothing here owns a clock; the view hands each frame in, and a head that has settled is drawn
/// once and asks for none.
final class BrainStage: @unchecked Sendable {
    unowned let owner: BrainView
    let interior: UnsafeMutablePointer<GtkWidget>
    /// The head as one picture: the interior, the nodes and the front composed by this stage into
    /// a single layer, which is what a head at rest or breathing is drawn with. Three layers one
    /// over another are what the software renderer pays for on every frame, so the layers are kept
    /// for the two things that need them apart, a dive and a move.
    let merged: UnsafeMutablePointer<GtkWidget>
    let nodes: UnsafeMutablePointer<GtkWidget>
    let front: UnsafeMutablePointer<GtkWidget>
    let leader: UnsafeMutablePointer<GtkWidget>
    let hit: UnsafeMutablePointer<GtkWidget>

    /// Every widget of the stage, bottom to top, which is also the order the row stacks them in.
    var widgets: [UnsafeMutablePointer<GtkWidget>] { [merged, interior, nodes, front, leader, hit] }

    /// The widgets that draw the head right now, bottom to top.
    var visibleLayers: [UnsafeMutablePointer<GtkWidget>] { layered ? [interior, nodes, front] : [merged] }

    /// Whether the head is drawn as three layers (a dive or a move) rather than one.
    private(set) var layered = false

    private var compositor: NeuralCompositor?
    private var composer: Composer?
    private var submitted: NeuralFrame?
    private var submittedDive = NeuralDive.none
    private var generation = 0
    private var inFlight = false
    private var queued: Job?
    private var lastSubmitTime = 0.0
    private(set) var hasDrawn = false
    private var surfaceSize = (width: 0, height: 0, scale: 1.0)
    private var table: NeuralToneTable?
    private var requested: (width: Int, height: Int, table: NeuralToneTable)?
    private var resizeTicket = 0
    private var needsFull = true
    private(set) var scene = BrainScene()
    private(set) var inks: BrainInks
    private var dive: Dive?
    private(set) var diveZone: NeuralZone?
    private var torndown = false
    private var wires: (key: WireKey, value: NeuralWires)?
    private(set) var logical = (width: 0, height: 0)
    private var pixelScale = 1

    private struct WireKey: Equatable {
        let revision: Int
        let selected: String?
        let hovered: String?
        let token: String?
        let reduce: Bool
    }
    private(set) var frames = 0
    private(set) var deltaFrames = 0
    private var frameNanoseconds: UInt64 = 0
    private var deltaNanoseconds: UInt64 = 0
    private var fullNanoseconds: UInt64 = 0
    private(set) var fulls = 0
    private(set) var droppedJobs = 0
    private(set) var mainNanoseconds: UInt64 = 0
    private var averageCompose = 0.0
    var drawing = true
    /// The front picture (the chassis and the glass) changes in the eye and the ribs, slowly, so it
    /// is copied to its layer at most ten times a second with the union of what changed.
    static let frontInterval = 0.1
    private var frontPending: NeuralRegion?
    private var lastFrontBlit = 0.0
    nonisolated(unsafe) static var debugSkip: Set<String> = []

    /// The most a head's two pictures are rendered at, in device pixels: a stage larger than this
    /// is drawn at this size and stretched by cairo, never rendered larger.
    static let renderWidthCap = 1100
    static let renderHeightCap = 720

    /// What the compositor is asked for at one instant.
    struct Job: @unchecked Sendable {
        let frame: NeuralFrame
        let dive: NeuralDive
        let stamp: Float
        var full: Bool
    }

    /// What one job drew, for the main loop to copy to the layers.
    struct Outcome: @unchecked Sendable {
        let whole: Bool
        let region: NeuralRegion
        let ripple: Bool
        let drew: Bool
        let nanoseconds: UInt64
    }

    /// The compositor and the two surfaces it draws into, confined to one serial queue: the main
    /// loop only reads the surfaces while no job is running.
    final class Composer: @unchecked Sendable {
        let queue = DispatchQueue(label: "tailscode.brain.compose", qos: .userInteractive)
        let compositor: NeuralCompositor
        var pair: NeuralSurfacePair
        var rendered: NeuralFrame?
        var renderedDive = NeuralDive.none

        init(compositor: NeuralCompositor) {
            self.compositor = compositor
            pair = compositor.makeSurfacePair()
        }

        nonisolated(unsafe) static var mainThreadRuns = 0
        nonisolated(unsafe) static var runs = 0

        func run(_ job: Job) -> Outcome {
            if Thread.isMainThread { Composer.mainThreadRuns += 1 }
            Composer.runs += 1
            let begun = DispatchTime.now().uptimeNanoseconds
            let width = pair.interior.width
            let height = pair.interior.height
            let whole = job.full || rendered == nil || job.dive != renderedDive
            var region = NeuralRegion(minX: 0, minY: 0, maxX: width, maxY: height)
            var ripple = false
            var drew = true
            if whole {
                NeuralParallelism.maximumWorkers = NeuralAssetFiles.fullWorkers
                compositor.renderFull(job.frame, dive: job.dive, time: job.stamp, into: &pair)
                NeuralParallelism.maximumWorkers = NeuralAssetFiles.deltaWorkers
            } else if let last = rendered, job.frame != last || !job.frame.settled {
                region = compositor.dirtyRegion(for: job.frame, previous: last)
                compositor.renderDelta(
                    job.frame, previous: last, into: &pair, region: region, dive: job.dive, time: job.stamp)
                ripple = job.frame.ripple != 0 || last.ripple != 0
            } else {
                drew = false
            }
            rendered = job.frame
            renderedDive = job.dive
            return Outcome(
                whole: whole, region: region, ripple: ripple, drew: drew,
                nanoseconds: DispatchTime.now().uptimeNanoseconds - begun)
        }
    }

    private struct Dive {
        let zone: NeuralZone
        let from: Double
        let to: Double
        let start: Double
        let duration: Double
    }

    init(owner: BrainView) {
        self.owner = owner
        inks = BrainInks(palette: MatrixTheme.palette, face: owner.model.face)
        interior = tailscode_layer_new(1)!
        merged = tailscode_layer_new(1)!
        front = tailscode_layer_new(0)!
        let holder = CanvasHolder()
        nodes = holder.make(kind: .nodes)
        let leaderHolder = CanvasHolder()
        leader = leaderHolder.make(kind: .leader)
        hit = gtk_drawing_area_new()!
        holder.stage = self
        leaderHolder.stage = self
        build()
    }

    /// Hands a canvas a closure that reaches the stage without keeping it alive: the canvas
    /// outlives a stage that was closed in the middle of a frame.
    private final class CanvasHolder: @unchecked Sendable {
        enum Kind { case nodes, leader }
        weak var stage: BrainStage?
        var kind = Kind.nodes

        func make(kind: Kind) -> UnsafeMutablePointer<GtkWidget> {
            _ = Gtk.releaseInstalled
            self.kind = kind
            let box = Unmanaged.passRetained(self).toOpaque()
            return tailscode_canvas_new(
                { cr, width, height, raw in
                    guard let cr, let raw else { return }
                    let holder = Unmanaged<CanvasHolder>.fromOpaque(raw).takeUnretainedValue()
                    guard let stage = holder.stage else { return }
                    switch holder.kind {
                    case .nodes: stage.drawNodes(cr, width: width, height: height)
                    case .leader: stage.drawLeader(cr, width: width, height: height)
                    }
                }, box,
                { raw in
                    guard let raw else { return }
                    Unmanaged<CanvasHolder>.fromOpaque(raw).release()
                })!
        }
    }

    private func build() {
        for widget in [merged, interior, nodes, front, leader] {
            gtk_widget_set_can_target(widget, 0)
            gtk_widget_set_can_focus(widget, 0)
        }
        gtk_widget_set_focusable(hit, 1)
        gtk_widget_set_can_focus(hit, 1)
        Gtk.addClass(hit, "brain-stage")
        tailscode_set_accessible_label(hit, owner.model.spoken)
        installInput()
        RepeatingMotion.watch(hit) { [weak self] in self?.motionPreferenceChanged() }
    }

    private func installInput() {
        Gtk.onPointer(
            hit,
            move: { [weak self] x, y in self?.pointer(x: x, y: y) },
            leave: { [weak self] in self?.pointerLeft() })
        let box = Unmanaged.passRetained(ClickBox { [weak self] x, y, presses, button in
            self?.clicked(x: x, y: y, presses: Int(presses), button: Int(button))
        }).toOpaque()
        _ = Gtk.releaseInstalled
        tailscode_on_click_at(
            hit,
            { x, y, presses, button, raw in
                guard let raw else { return }
                Unmanaged<ClickBox>.fromOpaque(raw).takeUnretainedValue().handler(x, y, presses, button)
            }, box)
        let focus = Unmanaged.passRetained(FocusBox { [weak self] entered in
            self?.focusChanged(entered: entered)
        }).toOpaque()
        tailscode_on_focus_change(
            hit,
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().changed(true)
            },
            { raw in
                guard let raw else { return }
                Unmanaged<FocusBox>.fromOpaque(raw).takeUnretainedValue().changed(false)
            }, focus)
    }

    private final class FocusBox: @unchecked Sendable {
        let changed: (Bool) -> Void
        init(_ changed: @escaping (Bool) -> Void) { self.changed = changed }
    }

    private final class ClickBox: @unchecked Sendable {
        let handler: (Double, Double, Int32, Int32) -> Void
        init(_ handler: @escaping (Double, Double, Int32, Int32) -> Void) { self.handler = handler }
    }

    deinit { teardown() }

    /// Lets go of the compositor and stops answering the widget's signals. The widgets themselves
    /// are not touched: this runs from the row's teardown, by which time GTK may already have taken
    /// them down, and their surfaces go with them.
    func teardown() {
        guard !torndown else { return }
        torndown = true
        releaseRenderer()
    }

    /// Frees the two surfaces now, for a stage that is leaving a row that stays.
    func releaseSurfaces() {
        tailscode_layer_release(interior)
        tailscode_layer_release(front)
        tailscode_layer_release(merged)
    }

    private func releaseRenderer() {
        if let held = compositor { BrainCompositors.release(held) }
        compositor = nil
        composer = nil
        generation += 1
        inFlight = false
        queued = nil
        submitted = nil
        hasDrawn = false
        table = nil
        requested = nil
        needsFull = true
    }

    /// Gives up everything the picture costs while the pane is hidden: the compositor, its
    /// surfaces and the pictures drawn into them. The nodes and the words stay, being cheap.
    func suspend() {
        releaseRenderer()
        releaseSurfaces()
        surfaceSize = (0, 0, 1.0)
    }

    func resume() {
        resized()
    }

    var hasRenderer: Bool { compositor != nil && composer != nil }

    var footprint: Int {
        Int(
            tailscode_layer_footprint(interior) + tailscode_layer_footprint(front)
                + tailscode_layer_footprint(merged))
    }

    /// The two pictures the layers hold, which a move paints scaled: the interior, the front, and
    /// the size they are drawn at in points.
    var pictures: (interior: OpaquePointer, front: OpaquePointer, width: Double, height: Double)? {
        guard hasPicture, layered, surfaceSize.width > 0, let inner = tailscode_layer_surface(interior),
            let outer = tailscode_layer_surface(front)
        else { return nil }
        return (
            inner, outer, Double(surfaceSize.width) / surfaceSize.scale,
            Double(surfaceSize.height) / surfaceSize.scale
        )
    }

    /// Frame costs measured since the stage opened, in microseconds a frame, for the harness.
    var timings: (full: Double, delta: Double, fulls: Int, deltas: Int) {
        (
            fulls == 0 ? 0 : Double(fullNanoseconds) / Double(fulls) / 1000,
            deltaFrames == 0 ? 0 : Double(deltaNanoseconds) / Double(deltaFrames) / 1000, fulls,
            deltaFrames
        )
    }

    var size: (width: Int, height: Int) { logical }

    /// How many design units a point of the stage is.
    var unit: Double {
        logical.width > 0 ? Double(logical.width) / NeuralStageMetrics.designWidth : 0
    }

    private func motionPreferenceChanged() {
        owner.motionChanged()
    }

    /// The stage's size in points, from the row's metrics. The compositor is made for it a moment
    /// after the last change, so a window being dragged wider does not build one per pixel.
    func configure(width: Int, height: Int, scaleFactor: Int) {
        guard width != logical.width || height != logical.height || scaleFactor != pixelScale else { return }
        logical = (width, height)
        pixelScale = max(1, scaleFactor)
        resized()
    }

    private func resized() {
        guard !torndown, !owner.isSuspended else { return }
        resizeTicket += 1
        let ticket = resizeTicket
        Gtk.after(60) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.resizeTicket == ticket else { return }
                self.ensureRenderer()
            }
        }
    }

    /// The size the head is rendered at: the stage's own size at the display's scale, held to
    /// the layers' resolution and to `renderWidthCap` by `renderHeightCap` device pixels. A stage
    /// larger than the cap is rendered at the cap and stretched by cairo, which is what a
    /// fractional device scale on the surface does.
    func targetSize() -> (width: Int, height: Int, scale: Double)? {
        guard logical.width > 8, logical.height > 8 else { return nil }
        let wholeWidth =
            Double(logical.width) * NeuralDesign.width / NeuralStageMetrics.designWidth
        var scale = Double(pixelScale)
        scale = min(scale, Double(NeuralAssetName.fullWidth) / wholeWidth)
        scale = min(scale, Double(Self.renderWidthCap) / wholeWidth)
        scale = min(scale, Double(Self.renderHeightCap) / Double(logical.height))
        scale = max(scale, 0.1)
        if scale > 1 { scale = scale.rounded(.down) }
        let width = max(1, Int((wholeWidth * scale).rounded()))
        let height = max(1, Int((Double(logical.height) * scale).rounded()))
        return (width, height, Double(width) / wholeWidth)
    }

    private func currentTable() -> NeuralToneTable {
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

    private(set) var recomposeNanoseconds: UInt64 = 0
    private(set) var recomposes = 0

    /// The look changed: another palette, or another model answered.
    func retheme() {
        inks = BrainInks(palette: MatrixTheme.palette, face: owner.model.face)
        ensureRenderer()
        needsFull = true
        owner.redrawNow()
    }

    private func currentDive(at time: Double) -> (dive: NeuralDive, scale: Double, zone: NeuralZone?) {
        guard let active = dive ?? stillDive() else { return (.none, 1, nil) }
        let progress = min(1, max(0, (time - active.start) / active.duration))
        let eased = progress < 0.5 ? 4 * progress * progress * progress : 1 - pow(-2 * progress + 2, 3) / 2
        let reduced = BrainBudget.reduceMotion
        let value = reduced || progress >= 1 ? active.to : active.from + (active.to - active.from) * eased
        let center = active.zone.center
        let dive = NeuralDive(
            center: NeuralPoint(center.x / NeuralDesign.width, center.y / NeuralDesign.height),
            chassisScale: Float(1 + (value - 1) * 1.7), glassScale: Float(1 + (value - 1) * 1.25),
            fade: Float(min(1, max(0, 1 - (value - 1.5) / 1.1))))
        return (value == 1 ? .none : dive, value, active.zone)
    }

    private func stillDive() -> Dive? {
        guard let zone = diveZone else { return nil }
        return Dive(zone: zone, from: Self.depth(of: zone), to: Self.depth(of: zone), start: 0, duration: 1)
    }

    private static func depth(of zone: NeuralZone) -> Double { zone == .say ? 3.4 : 2.6 }

    var isDiving: Bool { dive != nil }

    /// How far the head is dived, one at rest.
    var zoom: Double { scene.zoom }

    /// Flies into a zone, or out of it for nil, over half a second at the display's rate.
    func dive(into zone: NeuralZone?) {
        let time = BrainClock.now
        let (_, current, _) = currentDive(at: time)
        if let zone {
            guard owner.model.steps.contains(where: { $0.zone == zone }) else { return }
            diveZone = zone
            dive = Dive(zone: zone, from: current, to: Self.depth(of: zone), start: time, duration: 0.52)
        } else if let held = diveZone {
            dive = Dive(zone: held, from: current, to: 1, start: time, duration: 0.42)
            diveZone = held
        } else {
            return
        }
        enterLayered()
        owner.model.setDiving(true)
        owner.model.setDive(zone: zone)
        if BrainBudget.reduceMotion { finishDive(at: time) }
        owner.diveChanged()
        owner.redrawNow()
        owner.updateClock()
    }

    private func finishDive(at time: Double) {
        guard let active = dive else { return }
        let surfaced = active.to == 1
        dive = nil
        if surfaced { diveZone = nil }
        owner.model.setDiving(false)
        needsFull = true
        if surfaced { leaveLayered() }
        owner.diveChanged()
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
    private func nodesDue(_ time: Double, state scale: Double) -> Bool {
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

    private struct NodesKey: Equatable {
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
    private var lastNodesKey: NodesKey?
    private var lastNodesDraw = 0.0
    private var recomposePending = false

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
    private var minimumInterval: Double {
        averageCompose > 0.010 ? averageCompose * 2.5 : 0
    }

    private func submit(_ job: Job, at time: Double) {
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

    private func start(_ job: Job) {
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
    private func flushFront(generation made: Int) {
        guard !torndown, made == generation, !inFlight, let held = frontPending, let composer else { return }
        frontPending = nil
        lastFrontBlit = BrainClock.now
        let (w, h) = (surfaceSize.width, surfaceSize.height)
        composer.pair.front.bytes.withUnsafeBufferPointer {
            tailscode_layer_blit(front, $0.baseAddress, Int32(w), Int32(h), Int32(held.minX), Int32(held.minY), Int32(held.width), Int32(held.height))
        }
    }

    private func completed(_ outcome: Outcome, generation made: Int, composer finished: Composer) {
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

    private func buildScene(_ time: Double, scale: Double, reduce: Bool, zone: NeuralZone?) {
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

    private func drawNodes(_ cr: OpaquePointer, width: Int32, height: Int32) {
        let begun = DispatchTime.now().uptimeNanoseconds
        BrainPainter.paint(cr, width: width, height: height, scene: scene, inks: inks)
        nodeNanoseconds += DispatchTime.now().uptimeNanoseconds - begun
        nodeDraws += 1
    }

    private func drawLeader(_ cr: OpaquePointer, width: Int32, height: Int32) {
        let begun = DispatchTime.now().uptimeNanoseconds
        owner.paintLeader(cr, width: Double(width), height: Double(height))
        leaderNanoseconds += DispatchTime.now().uptimeNanoseconds - begun
        leaderDraws += 1
    }

    private(set) var nodeNanoseconds: UInt64 = 0
    private(set) var nodeDraws = 0
    private(set) var leaderNanoseconds: UInt64 = 0
    private(set) var leaderDraws = 0

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

    private func pointer(x: Double, y: Double) {
        guard !isDiving, unit > 0 else { return }
        let found = owner.model.hit(at: design(x, y), slop: 4 / unit / max(0.05, scene.zoom))
        owner.stagePointer(over: found)
    }

    private func pointerLeft() {
        owner.stagePointer(over: nil)
    }

    private func focusChanged(entered: Bool) {
        owner.stageFocus(entered)
        gtk_widget_queue_draw(leader)
    }

    private func clicked(x: Double, y: Double, presses: Int, button: Int) {
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

    private func zoneLabel(at point: NeuralPoint) -> NeuralZone? {
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
