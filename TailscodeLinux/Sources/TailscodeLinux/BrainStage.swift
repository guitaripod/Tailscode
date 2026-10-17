import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What the window's budget lets a brain do, read where it is drawn. The governor's levels are the
/// whole answer: calm and busy draw everything at the activity tempo, loaded slows the clock, from
/// strained up nothing breathes (the ripple, the sweep and the crunch go, and every state is held
/// still in its own tone), and at critical the head is a glyph and no stage is built at all.
enum BrainBudget {
    static var reduceMotion: Bool { !RepeatingMotion.allowed }
    static var stageAllowed: Bool { CascadeBudget.level < .critical }
}

/// The open brain: three drawing areas stacked in one overlay (the interior, the nodes, the front),
/// the ticker line, the scrubber, the answer's chips and the list a dive ends on.
///
/// The head's two pictures come from Core's CPU compositor: a full frame when the look, the size or
/// the dive changes, and a delta for everything else, copied row by row into cairo surfaces the
/// shim owns. The nodes are painted over the interior and under the front with cairo, so they sit
/// inside the glass. Nothing here owns a clock; the view hands each frame in, and a head that has
/// settled is drawn once and asks for none.
final class BrainStage: @unchecked Sendable {
    unowned let owner: BrainView
    let root: UnsafeMutablePointer<GtkWidget>
    let overlay: UnsafeMutablePointer<GtkWidget>
    private let interior: UnsafeMutablePointer<GtkWidget>
    private let nodes: UnsafeMutablePointer<GtkWidget>
    private let cards: UnsafeMutablePointer<GtkWidget>
    private let front: UnsafeMutablePointer<GtkWidget>
    private let ticker: UnsafeMutablePointer<GtkWidget>
    private let scrubRow: UnsafeMutablePointer<GtkWidget>
    private let scale: UnsafeMutablePointer<GtkWidget>
    private let chipRow: UnsafeMutablePointer<GtkWidget>
    private let diveBox: UnsafeMutablePointer<GtkWidget>

    private var compositor: NeuralCompositor?
    private var pair: NeuralSurfacePair?
    private var lastFrame: NeuralFrame?
    private var lastDive = NeuralDive.none
    private var surfaceSize = (width: 0, height: 0, scale: 1)
    private var table: NeuralToneTable?
    private var requested: (width: Int, height: Int, table: NeuralToneTable)?
    private var resizeTicket = 0
    private var needsFull = true
    private var scene = BrainScene()
    private var inks: BrainInks
    private var dive: Dive?
    private(set) var diveZone: NeuralZone?
    private var suppressScale = false
    private var scrubTicket = 0
    private var tickerText = ""
    private var chipSignature = ""
    private var listedZone: NeuralZone?
    private var torndown = false
    private var cardDrawn = false
    private var wires: (key: WireKey, value: NeuralWires)?

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

    private struct Dive {
        let zone: NeuralZone
        let from: Double
        let to: Double
        let start: Double
        let duration: Double
    }

    private static let maximumWidth: Int32 = 760

    init(owner: BrainView) {
        self.owner = owner
        inks = BrainInks(palette: MatrixTheme.palette, face: owner.model.face)
        root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(root, "brain-stage-box")
        overlay = gtk_overlay_new()!
        interior = tailscode_layer_new(1)!
        front = tailscode_layer_new(0)!
        let holder = BrainStage.CanvasHolder()
        nodes = holder.make(card: false)
        let cardHolder = BrainStage.CanvasHolder()
        cards = cardHolder.make(card: true)
        ticker = Gtk.label("", css: "brain-ticker", selectable: false)
        scrubRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1000, 1)!
        chipRow = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        diveBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        holder.stage = self
        cardHolder.stage = self
        build()
    }

    /// Hands the canvas a closure that reaches the stage without keeping it alive: the canvas
    /// outlives a stage that was closed in the middle of a frame.
    private final class CanvasHolder: @unchecked Sendable {
        weak var stage: BrainStage?
        var isCard = false

        func make(card: Bool) -> UnsafeMutablePointer<GtkWidget> {
            _ = Gtk.releaseInstalled
            isCard = card
            let box = Unmanaged.passRetained(self).toOpaque()
            return tailscode_canvas_new(
                { cr, width, height, raw in
                    guard let cr, let raw else { return }
                    let holder = Unmanaged<CanvasHolder>.fromOpaque(raw).takeUnretainedValue()
                    guard let stage = holder.stage else { return }
                    if holder.isCard {
                        stage.drawCard(cr, width: width, height: height)
                    } else {
                        stage.drawNodes(cr, width: width, height: height)
                    }
                }, box,
                { raw in
                    guard let raw else { return }
                    Unmanaged<CanvasHolder>.fromOpaque(raw).release()
                })!
        }
    }

    private func build() {
        gtk_widget_set_hexpand(overlay, 1)
        gtk_overlay_set_child(op(overlay), interior)
        gtk_overlay_add_overlay(op(overlay), nodes)
        gtk_overlay_add_overlay(op(overlay), front)
        gtk_overlay_add_overlay(op(overlay), cards)
        gtk_widget_set_can_target(cards, 0)
        gtk_widget_set_can_target(interior, 0)
        gtk_widget_set_can_target(nodes, 0)
        gtk_widget_set_can_target(front, 0)
        gtk_widget_set_focusable(overlay, 1)
        gtk_widget_set_can_focus(overlay, 1)
        Gtk.addClass(overlay, "brain-stage")
        gtk_widget_set_overflow(overlay, GTK_OVERFLOW_HIDDEN)
        tailscode_set_accessible_label(overlay, owner.model.spoken)
        let aspect = tailscode_aspect_new(
            NeuralDesign.width / NeuralDesign.height, Int32(Self.maximumWidth))!
        tailscode_aspect_set_child(aspect, overlay)
        gtk_box_append(ptr(root), aspect)

        gtk_label_set_ellipsize(op(ticker), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(op(ticker), 1)
        gtk_widget_set_visible(ticker, 0)
        gtk_box_append(ptr(root), ticker)

        gtk_scale_set_draw_value(ptr(scale), 0)
        gtk_widget_set_hexpand(scale, 1)
        Gtk.addClass(scale, "brain-scrub")
        tailscode_set_accessible_label(scale, NeuralReading.scrubLabel)
        gtk_box_append(ptr(scrubRow), scale)
        gtk_widget_set_visible(scrubRow, 0)
        gtk_box_append(ptr(root), scrubRow)
        Gtk.connect(UnsafeMutableRawPointer(scale), "value-changed") { [weak self] in
            self?.scaleMoved()
        }

        gtk_widget_set_visible(chipRow, 0)
        gtk_box_append(ptr(root), chipRow)
        gtk_widget_set_visible(diveBox, 0)
        gtk_box_append(ptr(root), diveBox)

        installInput()
        Gtk.onResize(interior) { [weak self] in self?.resized() }
        RepeatingMotion.watch(overlay) { [weak self] in self?.motionPreferenceChanged() }
    }

    private func installInput() {
        Gtk.onPointer(
            overlay,
            move: { [weak self] x, y in self?.pointer(x: x, y: y) },
            leave: { [weak self] in self?.pointerLeft() })
        let box = Unmanaged.passRetained(ClickBox { [weak self] x, y, presses, button in
            self?.clicked(x: x, y: y, presses: Int(presses), button: Int(button))
        }).toOpaque()
        _ = Gtk.releaseInstalled
        tailscode_on_click_at(
            overlay,
            { x, y, presses, button, raw in
                guard let raw else { return }
                Unmanaged<ClickBox>.fromOpaque(raw).takeUnretainedValue().handler(x, y, presses, button)
            }, box)
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
    }

    private func releaseRenderer() {
        if let held = compositor { BrainCompositors.release(held) }
        compositor = nil
        pair = nil
        lastFrame = nil
        table = nil
        requested = nil
        needsFull = true
    }

    /// Gives up everything the picture costs while the pane is hidden: the compositor, its
    /// surfaces and the pictures drawn into them. The nodes and the words stay, being cheap.
    func suspend() {
        releaseRenderer()
        releaseSurfaces()
        surfaceSize = (0, 0, 1)
    }

    func resume() {
        resized()
    }

    var hasRenderer: Bool { compositor != nil && pair != nil }

    var footprint: Int {
        Int(tailscode_layer_footprint(interior) + tailscode_layer_footprint(front))
    }

    /// Frame costs measured since the stage opened, in microseconds a frame, for the harness.
    var timings: (full: Double, delta: Double, fulls: Int, deltas: Int) {
        (
            fulls == 0 ? 0 : Double(fullNanoseconds) / Double(fulls) / 1000,
            deltaFrames == 0 ? 0 : Double(deltaNanoseconds) / Double(deltaFrames) / 1000, fulls,
            deltaFrames
        )
    }

    /// The selected node's card as one sentence, for the stage's accessible description: a screen
    /// reader cannot read a card drawn on a canvas, so what the card says is said here as well.
    private var cardWords: String {
        guard let card = owner.model.card else { return "" }
        var parts = [card.title, card.statusWord]
        if !card.body.isEmpty { parts.append(card.body) }
        if let tally = card.tally { parts.append(tally) }
        parts.append(contentsOf: card.output)
        parts.append(card.footer)
        return parts.joined(separator: ". ")
    }

    var cardSummary: String? {
        guard let card = owner.model.card else { return nil }
        return "\(card.title)|\(card.statusWord)|\(card.footer)"
    }

    var size: (width: Int, height: Int) {
        (Int(gtk_widget_get_width(overlay)), Int(gtk_widget_get_height(overlay)))
    }

    private func motionPreferenceChanged() {
        owner.motionChanged()
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

    private func targetSize() -> (width: Int, height: Int, scale: Int)? {
        let width = Int(gtk_widget_get_width(interior))
        let height = Int(gtk_widget_get_height(interior))
        guard width > 8, height > 8 else { return nil }
        let factor = max(1, Int(gtk_widget_get_scale_factor(interior)))
        let cap = max(1, NeuralAssetName.fullWidth / max(1, width))
        let scaled = min(factor, cap)
        return (width * scaled, height * scaled, scaled)
    }

    private func currentTable() -> NeuralToneTable {
        NeuralToneTable(palette: MatrixTheme.palette, face: owner.model.face)
    }

    /// Makes sure a compositor of the right size and look is held, asking for one when it is not.
    func ensureRenderer() {
        guard !torndown, !owner.isSuspended, NeuralAssetFiles.isAvailable,
            let target = targetSize()
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
            self.pair = built.makeSurfacePair()
            tailscode_layer_resize(self.interior, Int32(target.width), Int32(target.height), Int32(target.scale))
            tailscode_layer_resize(self.front, Int32(target.width), Int32(target.height), Int32(target.scale))
            self.lastFrame = nil
            self.needsFull = true
            self.owner.stageRendererReady()
        }
    }

    /// The look changed: another palette, or another model answered.
    func retheme() {
        inks = BrainInks(palette: MatrixTheme.palette, face: owner.model.face)
        ensureRenderer()
        needsFull = true
        owner.redrawNow()
    }

    private func motionScale() -> Double {
        Double(gtk_widget_get_width(nodes)) / NeuralDesign.width
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
            clearList()
        } else {
            return
        }
        owner.model.setDiving(true)
        if BrainBudget.reduceMotion { finishDive(at: time) }
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
        if !surfaced { showList(for: active.zone) }
    }

    /// One frame: the head's picture, then the nodes over it. `force` draws even a settled head,
    /// which is what a hover, a pin or a new step needs.
    func step(_ time: Double) {
        guard !torndown else { return }
        if let active = dive, time - active.start >= active.duration { finishDive(at: time) }
        render(time)
        syncScrubber(time)
        syncTicker(time)
    }

    func render(_ time: Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        frames += 1
        let reduce = BrainBudget.reduceMotion
        let state = currentDive(at: time)
        let frame = owner.model.frame(time: time, reduceMotion: reduce)
        if let compositor, var surfaces = pair {
            let stamp = Float(time.truncatingRemainder(dividingBy: 1000))
            let wholeFrame = lastFrame == nil || needsFull || state.dive != lastDive
            if wholeFrame {
                let begun = DispatchTime.now().uptimeNanoseconds
                NeuralParallelism.maximumWorkers = NeuralAssetFiles.fullWorkers
                compositor.renderFull(frame, dive: state.dive, time: stamp, into: &surfaces)
                NeuralParallelism.maximumWorkers = NeuralAssetFiles.deltaWorkers
                let (w, h) = (surfaceSize.width, surfaceSize.height)
                surfaces.interior.bytes.withUnsafeBufferPointer {
                    tailscode_layer_blit(interior, $0.baseAddress, Int32(w), Int32(h), 0, 0, Int32(w), Int32(h))
                }
                surfaces.front.bytes.withUnsafeBufferPointer {
                    tailscode_layer_blit(front, $0.baseAddress, Int32(w), Int32(h), 0, 0, Int32(w), Int32(h))
                }
                fullNanoseconds += DispatchTime.now().uptimeNanoseconds - begun
                fulls += 1
                needsFull = false
            } else if let last = lastFrame, frame != last || !frame.settled {
                let begun = DispatchTime.now().uptimeNanoseconds
                let region = compositor.dirtyRegion(for: frame, previous: last)
                compositor.renderDelta(
                    frame, previous: last, into: &surfaces, region: region, dive: state.dive, time: stamp)
                let (w, h) = (surfaceSize.width, surfaceSize.height)
                let ripple = frame.ripple != 0 || last.ripple != 0
                surfaces.interior.bytes.withUnsafeBufferPointer {
                    if ripple {
                        tailscode_layer_blit(interior, $0.baseAddress, Int32(w), Int32(h), 0, 0, Int32(w), Int32(h))
                    } else if !region.isEmpty {
                        tailscode_layer_blit(interior, $0.baseAddress, Int32(w), Int32(h), Int32(region.minX), Int32(region.minY), Int32(region.width), Int32(region.height))
                    }
                }
                if !region.isEmpty {
                    surfaces.front.bytes.withUnsafeBufferPointer {
                        tailscode_layer_blit(front, $0.baseAddress, Int32(w), Int32(h), Int32(region.minX), Int32(region.minY), Int32(region.width), Int32(region.height))
                    }
                }
                deltaNanoseconds += DispatchTime.now().uptimeNanoseconds - begun
                deltaFrames += 1
                if deltaFrames == 60 {
                    Trace.mark(
                        "brain delta frame \(Int(timings.delta)) us, full frame \(Int(timings.full)) us at \(surfaceSize.width)x\(surfaceSize.height)")
                }
            }
            pair = surfaces
            lastFrame = frame
            lastDive = state.dive
        }
        tailscode_layer_zoom(
            interior, state.dive.center.x, state.dive.center.y, state.scale)
        buildScene(time, scale: state.scale, reduce: reduce, zone: state.zone)
        gtk_widget_queue_draw(nodes)
        let wantsCard = scene.card != nil
        if wantsCard || cardDrawn {
            gtk_widget_queue_draw(cards)
            cardDrawn = wantsCard
        }
        frameNanoseconds += DispatchTime.now().uptimeNanoseconds - started
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
        next.hasSelection = model.hasSelection
        next.usedZones = Set(model.steps.map(\.zone))
        next.card = model.card
        next.cardNode = model.selected
        next.zoom = scale
        let center = (zone ?? .think).center
        next.zoomCenter = zone == nil ? NeuralPoint(320, 210) : center
        next.orbit = owner.model.frame(time: time, reduceMotion: reduce).orbit
        next.crowded = model.nodeCount > 60
        next.hotZone = model.selectedZone
        next.focused = gtk_widget_has_focus(overlay) != 0
        scene = next
    }

    fileprivate func drawNodes(_ cr: OpaquePointer, width: Int32, height: Int32) {
        BrainPainter.paint(cr, width: width, height: height, scene: scene, inks: inks)
    }

    fileprivate func drawCard(_ cr: OpaquePointer, width: Int32, height: Int32) {
        BrainPainter.paintCard(cr, width: width, height: height, scene: scene, inks: inks)
    }

    /// Whether the compositor has drawn at least one frame, for the harness.
    var hasPicture: Bool { lastFrame != nil }

    private func design(_ x: Double, _ y: Double) -> NeuralPoint {
        let factor = motionScale()
        guard factor > 0 else { return NeuralPoint(0, 0) }
        let zoom = max(0.05, scene.zoom)
        let center = scene.zoomCenter
        return NeuralPoint(center.x + (x / factor - center.x) / zoom, center.y + (y / factor - center.y) / zoom)
    }

    private func pointer(x: Double, y: Double) {
        guard !isDiving else { return }
        let found = owner.model.hit(at: design(x, y), slop: 4)
        guard found != owner.model.hovered else { return }
        owner.hover(found)
    }

    private func pointerLeft() {
        guard owner.model.hovered != nil else { return }
        owner.hover(nil)
    }

    private func clicked(x: Double, y: Double, presses: Int, button: Int) {
        guard button == 1, !isDiving else { return }
        gtk_widget_grab_focus(overlay)
        let point = design(x, y)
        if let found = owner.model.hit(at: point, slop: 4) {
            if presses >= 2 {
                owner.openSubagent(of: found)
            } else {
                owner.pin(found)
            }
            return
        }
        if let zone = zoneLabel(at: point) {
            dive(into: zone)
            return
        }
        if owner.model.hasSelection { owner.clearSelection() }
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

    func handleKey(_ keyval: UInt32, state: UInt32) -> Bool {
        let modifiers = state & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue)
        guard modifiers == 0 else { return false }
        switch Int32(keyval) {
        case GDK_KEY_Left, GDK_KEY_Up: return walk(-1)
        case GDK_KEY_Right, GDK_KEY_Down: return walk(1)
        case GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_space:
            guard let selected = owner.model.hovered ?? owner.model.pinned else { return false }
            owner.pin(selected)
            return true
        case GDK_KEY_Escape:
            if diveZone != nil {
                dive(into: nil)
                return true
            }
            if owner.model.hasSelection || owner.model.provenanceToken != nil {
                owner.clearSelection()
                return true
            }
            return false
        default:
            return false
        }
    }

    func walkFromHarness(_ direction: Int) { _ = walk(direction) }

    func driveChip(_ index: Int?) {
        guard let index else {
            owner.point(at: nil)
            return
        }
        let tokens = owner.model.answerTokens(in: owner.row.answer).map(\.text)
        var seen = Set<String>()
        let unique = tokens.filter { seen.insert($0).inserted }
        guard index >= 1, index <= unique.count else { return }
        owner.point(at: unique[index - 1])
    }

    private func walk(_ direction: Int) -> Bool {
        let ids = scene.draws.map(\.id)
        guard !ids.isEmpty else { return false }
        let current = (owner.model.hovered ?? owner.model.pinned).flatMap { ids.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = min(ids.count - 1, max(0, current + direction))
        } else {
            next = direction > 0 ? 0 : ids.count - 1
        }
        owner.walk(to: ids[next])
        return true
    }

    private func syncTicker(_ time: Double) {
        let model = owner.model
        let line = model.ticker(now: time)
        let text = line.map { Localized.text("%1$@ · %2$@", $0.counter, $0.text) } ?? ""
        guard text != tickerText else { return }
        tickerText = text
        gtk_label_set_text(op(ticker), text)
        gtk_widget_set_visible(ticker, text.isEmpty ? 0 : 1)
    }

    func syncScrubber(_ time: Double) {
        let model = owner.model
        let settled = model.turn.outcome != .running
        if (gtk_widget_get_visible(scrubRow) != 0) != settled {
            gtk_widget_set_visible(scrubRow, settled ? 1 : 0)
        }
        guard settled else { return }
        let fraction = model.replayFraction(now: time) ?? 1
        suppressScale = true
        gtk_range_set_value(ptr(scale), fraction * 1000)
        suppressScale = false
    }

    private func scaleMoved() {
        guard !suppressScale, !torndown else { return }
        let fraction = gtk_range_get_value(ptr(scale)) / 1000
        owner.scrub(to: fraction)
        scrubTicket += 1
        let ticket = scrubTicket
        Gtk.after(320) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.scrubTicket == ticket else { return }
                self.owner.endScrub()
            }
        }
    }

    func rebuildChips() {
        let tokens = owner.row.answer.isEmpty ? [] : owner.model.answerTokens(in: owner.row.answer)
        var seen = Set<String>()
        let unique = tokens.map(\.text).filter { seen.insert($0).inserted }.prefix(12)
        let signature = unique.joined(separator: "\u{1}")
        guard signature != chipSignature else { return }
        chipSignature = signature
        Gtk.removeChildren(of: chipRow)
        guard !unique.isEmpty else {
            gtk_widget_set_visible(chipRow, 0)
            return
        }
        var chips: [UnsafeMutablePointer<GtkWidget>] = []
        let lead = Gtk.label(Localized.text("In the answer"), css: "brain-chip-lead", selectable: false)
        for text in unique {
            let shown = text.count > 44 ? "…" + text.suffix(43) : text
            let chip = gtk_button_new_with_label(shown)!
            Gtk.addClass(chip, "brain-chip")
            tailscode_set_accessible_label(chip, text)
            gtk_widget_set_tooltip_text(chip, text)
            let box = Unmanaged.passRetained(ChipBox(text: text, stage: self)).toOpaque()
            _ = Gtk.releaseInstalled
            tailscode_on_hover_focus(
                chip,
                { raw in
                    guard let raw else { return }
                    let chip = Unmanaged<ChipBox>.fromOpaque(raw).takeUnretainedValue()
                    chip.stage?.owner.point(at: chip.text)
                },
                { raw in
                    guard let raw else { return }
                    Unmanaged<ChipBox>.fromOpaque(raw).takeUnretainedValue().stage?.owner.point(at: nil)
                }, box)
            chips.append(chip)
        }
        let row = Gtk.wrapRow([lead] + chips, spacing: 6)
        gtk_box_append(ptr(chipRow), row)
        gtk_widget_set_visible(chipRow, 1)
    }

    private final class ChipBox: @unchecked Sendable {
        let text: String
        weak var stage: BrainStage?
        init(text: String, stage: BrainStage) {
            self.text = text
            self.stage = stage
        }
    }

    private func clearList() {
        listedZone = nil
        Gtk.removeChildren(of: diveBox)
        gtk_widget_set_visible(diveBox, 0)
    }

    private func showList(for zone: NeuralZone) {
        listedZone = zone
        Gtk.removeChildren(of: diveBox)
        let steps = owner.model.steps.filter { $0.zone == zone }
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let back = Gtk.button("‹ " + zone.label, css: ["brain-pill"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.dive(into: nil) }
        }
        gtk_box_append(ptr(header), back)
        let count = Gtk.label(
            steps.count == 1 ? Localized.text("1 step") : Localized.text("%lld steps", steps.count),
            css: "tool-detail", selectable: false)
        gtk_box_append(ptr(header), count)
        gtk_box_append(ptr(diveBox), header)
        let rows = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let scroller = Gtk.boundedScroller(rows, minimum: 0, maximum: 224)
        gtk_box_append(ptr(diveBox), scroller)
        for step in steps.prefix(60) {
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            Gtk.addClass(line, "brain-dive-row")
            gtk_box_append(ptr(line), Gtk.label(String(step.index + 1), css: "brain-dive-number", selectable: false))
            gtk_box_append(ptr(line), Gtk.label(NeuralReading.title(of: step), css: "tool-name", selectable: false))
            let said = NeuralReading.isThought(step) || NeuralReading.isNote(step) ? step.text : step.detail
            let detail = Gtk.label(String(said.prefix(160)), css: "tool-detail", selectable: false)
            gtk_widget_set_hexpand(detail, 1)
            gtk_box_append(ptr(line), detail)
            gtk_box_append(ptr(line), Gtk.label(NeuralReading.statusWord(step.status), css: "tool-detail", selectable: false))
            let id = step.id
            Gtk.onRelease(line) { [weak self] in
                Gtk.onMain { [weak self] in self?.owner.pin(id) }
            }
            gtk_box_append(ptr(rows), line)
        }
        gtk_widget_set_visible(diveBox, 1)
    }

    /// The model changed under an open stage: a step arrived, a status moved, a node was chosen.
    func modelChanged() {
        rebuildChips()
        if let zone = diveZone, dive == nil,
            listedZone != nil, owner.model.steps.filter({ $0.zone == zone }).count != 0
        {
            if gtk_widget_get_visible(diveBox) == 0 { showList(for: zone) }
        }
        tailscode_set_accessible_label(overlay, owner.accessibleLabel)
        tailscode_set_accessible_description(overlay, cardWords)
        ensureRenderer()
    }

    func invalidate() {
        needsFull = true
    }
}
