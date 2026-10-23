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
    var layered = false

    var compositor: NeuralCompositor?
    var composer: Composer?
    var submitted: NeuralFrame?
    var submittedDive = NeuralDive.none
    var generation = 0
    var inFlight = false
    var queued: Job?
    var lastSubmitTime = 0.0
    var hasDrawn = false
    var surfaceSize = (width: 0, height: 0, scale: 1.0)
    var table: NeuralToneTable?
    var requested: (width: Int, height: Int, table: NeuralToneTable)?
    var resizeTicket = 0
    var needsFull = true
    var scene = BrainScene()
    var inks: BrainInks
    var dive: Dive?
    var diveZone: NeuralZone?
    var torndown = false
    var wires: (key: WireKey, value: NeuralWires)?
    var logical = (width: 0, height: 0)
    var pixelScale = 1

    struct WireKey: Equatable {
        let revision: Int
        let selected: String?
        let hovered: String?
        let token: String?
        let reduce: Bool
    }
    var frames = 0
    var deltaFrames = 0
    var frameNanoseconds: UInt64 = 0
    var deltaNanoseconds: UInt64 = 0
    var fullNanoseconds: UInt64 = 0
    var fulls = 0
    var droppedJobs = 0
    var mainNanoseconds: UInt64 = 0
    var averageCompose = 0.0
    var drawing = true
    /// The front picture (the chassis and the glass) changes in the eye and the ribs, slowly, so it
    /// is copied to its layer at most ten times a second with the union of what changed.
    static let frontInterval = 0.1
    var frontPending: NeuralRegion?
    var lastFrontBlit = 0.0
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

    struct Dive {
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
    final class CanvasHolder: @unchecked Sendable {
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

    func build() {
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

    func installInput() {
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

    final class FocusBox: @unchecked Sendable {
        let changed: (Bool) -> Void
        init(_ changed: @escaping (Bool) -> Void) { self.changed = changed }
    }

    final class ClickBox: @unchecked Sendable {
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

    func releaseRenderer() {
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

    func motionPreferenceChanged() {
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

    func resized() {
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

    var recomposeNanoseconds: UInt64 = 0
    var recomposes = 0

    func currentDive(at time: Double) -> (dive: NeuralDive, scale: Double, zone: NeuralZone?) {
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

    func stillDive() -> Dive? {
        guard let zone = diveZone else { return nil }
        return Dive(zone: zone, from: Self.depth(of: zone), to: Self.depth(of: zone), start: 0, duration: 1)
    }

    static func depth(of zone: NeuralZone) -> Double { zone == .say ? 3.4 : 2.6 }

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

    func finishDive(at time: Double) {
        guard let active = dive else { return }
        let surfaced = active.to == 1
        dive = nil
        if surfaced { diveZone = nil }
        owner.model.setDiving(false)
        needsFull = true
        if surfaced { leaveLayered() }
        owner.diveChanged()
    }

    var lastNodesKey: NodesKey?
    var lastNodesDraw = 0.0
    var recomposePending = false

    var nodeNanoseconds: UInt64 = 0
    var nodeDraws = 0
    var leaderNanoseconds: UInt64 = 0
    var leaderDraws = 0
}
