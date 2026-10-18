import AppKit
import TailscodeCore

/// One node of a step list read by VoiceOver: a button that says what the step is and presses to
/// put the cursor on it.
private final class BrainStepElement: NSAccessibilityElement {
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?

    override func accessibilityPerformPress() -> Bool {
        let handler = onPress
        MainActor.assumeIsolated { handler?() }
        return true
    }
}

/// A ring round a node, with the step's number in a small tag: the cursor's is solid with a glow,
/// the previewed step's is dashed. At the head's size the numbers inside the nodes cannot be
/// read, so the tag carries it.
@MainActor
private final class BrainRingMark {
    let layer = CALayer()
    private let glow = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let tag = CALayer()
    private let text = CATextLayer()

    init() {
        layer.isHidden = true
        for sub in [glow, ring] {
            sub.fillColor = nil
            layer.addSublayer(sub)
        }
        tag.cornerRadius = 4
        tag.borderWidth = 1
        text.alignmentMode = .center
        text.isWrapped = false
        tag.addSublayer(text)
        layer.addSublayer(tag)
    }

    func hide() { layer.isHidden = true }

    func show(
        at center: CGPoint, nodeRadius: CGFloat, number: Int, solid: Bool, inks: BrainInks,
        scale: CGFloat, alpha: Float, backing: CGFloat
    ) {
        let accent = inks.domeAccent
        let radius = nodeRadius + 7 * scale
        layer.isHidden = false
        layer.opacity = alpha
        layer.position = center
        layer.bounds = .zero
        ring.path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.strokeColor = accent.withAlphaComponent(0.95).cgColor
        ring.lineWidth = 2.2
        ring.lineDashPattern = solid ? nil : [3, 2.4]
        glow.isHidden = !solid
        glow.path = CGPath(
            ellipseIn: CGRect(x: -radius * 1.5, y: -radius * 1.5, width: radius * 3, height: radius * 3), transform: nil)
        glow.fillColor = accent.withAlphaComponent(0.16).cgColor
        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold)
        text.contentsScale = backing
        text.font = font
        text.fontSize = 9.5
        text.foregroundColor = accent.cgColor
        text.string = "\(number)"
        let width = max(15, CGFloat("\(number)".count) * 6 + 8)
        let offset = radius * 0.72 + 2
        tag.frame = CGRect(x: offset, y: -offset - 14, width: width, height: 14)
        tag.backgroundColor = inks.panel.withAlphaComponent(0.92).cgColor
        tag.borderColor = accent.withAlphaComponent(0.95).cgColor
        text.frame = CGRect(x: 0, y: 0.5, width: width, height: 13)
    }
}

/// The nodes, wires and ties a move is part way through drawing: how many nodes have come in, how
/// big and how visible, and how much of every wire is drawn.
struct BrainReveal {
    var nodes: NeuralNodeReveal
    var wireDraw: Double
    var tieDraw: Double
}

/// The open brain's head, a map of the turn: the head drawn by Metal with the nodes, the wires and
/// the zone names laid between its interior and its glass, the ring of the cursor and of the
/// step being previewed, and what a person can do with it.
///
/// The stage is content, drawn straight on the transcript's canvas (the head's own background is
/// the canvas), never glass. It holds no model: the pane's `BrainStore` does, and every change
/// is made through the row (`BrainSurfaceHost`) and read back, so the head, the nodes, the list,
/// the account and the footer all draw from one value. A hover previews the step and rings its
/// node, a click puts the cursor on it, a zone's name dives into the zone, double-clicking a Task
/// node opens its agent, a right-click opens the step's menu.
///
/// Nothing here runs a clock of its own. The head's display link ticks the stage only while the
/// brain has something that moves, and a settled brain is drawn once and costs nothing after.
@MainActor
final class BrainStageView: NSView, BrainKeyTaker {
    let turnID: String
    private weak var host: BrainSurfaceHost?
    let head = NeuralHeadView()

    private let overlay = CALayer()
    private let tieGroup = CALayer()
    private let wireGroup = CALayer()
    private let viaGroup = CALayer()
    private let labelGroup = CALayer()
    private let nodeGroup = CALayer()
    private let batchGroup = CALayer()
    private let ringGroup = CALayer()
    private let cursorRing = BrainRingMark()
    private let previewRing = BrainRingMark()

    private var nodes: [String: BrainNode] = [:]
    private var batches: [String: CAShapeLayer] = [:]
    private var routeLayers: [CAShapeLayer] = []
    private var tieLayers: [CAShapeLayer] = []
    private var viaLayers: [CAShapeLayer] = []
    private var zoneLabels: [NeuralZone: CATextLayer] = [:]
    private var nodeIDs: [String] = []
    private var steps: [BrainStepElement] = []

    private var laidOut = NSSize.zero
    private var a11yRevision = -1
    private var lastRevision = -1
    private var lastScale: CGFloat = -1
    private var lastInks = 0
    private var lastDynamic = 0
    private var parked = false
    private var motionObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var gate: DisplayGate?
    private(set) var isFocused = false

    var reveal: BrainReveal? {
        didSet { if reveal != nil || oldValue != nil { refresh(force: true) } }
    }

    private struct Dive {
        var zone: NeuralZone
        var start: CFTimeInterval
        var surfacing: Bool
    }

    private var diving: Dive?
    private(set) var divedZone: NeuralZone?
    private var currentDive = NeuralDive.none
    private var diveProgress: Double = 0

    /// A model to draw instead of the host's, for a picture that must not show a hover, a cursor
    /// or a replay: the poster of a turn.
    var fixedModel: NeuralBrainModel?

    private func currentModel() -> NeuralBrainModel? { fixedModel ?? host?.model }

    /// Told after a tick that moved the head, a change the person made, or a dive's end, so the
    /// row's other parts follow without a clock of their own.
    var onActivity: (() -> Void)?
    var onDive: ((NeuralZone?) -> Void)?

    static let diveDuration: CFTimeInterval = 0.52

    init(turnID: String, host: BrainSurfaceHost?) {
        self.turnID = turnID
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        head.frame = bounds
        addSubview(head)
        head.nodeLayer.addSublayer(overlay)
        for group in [tieGroup, wireGroup, viaGroup, labelGroup, batchGroup, nodeGroup, ringGroup] {
            overlay.addSublayer(group)
        }
        ringGroup.addSublayer(previewRing.layer)
        ringGroup.addSublayer(cursorRing.layer)
        head.onTick = { [weak self] time in self?.tick(time) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
        themeObserver = NotificationCenter.default.addObserver(
            forName: MacTheme.Chrome.didRepaint, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
        gate = DisplayGate(self) { [weak self] in self?.noteVisibility() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        noteFocus()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        noteFocus()
        return true
    }

    private func noteFocus() {
        host?.stageFocusChanged(isFocused)
    }

    /// The head is drawn at the design's own aspect, 576 by 420 of it: its 640-unit frame is wider
    /// by the 64 units the chassis does not use, which hang off the stage's left edge.
    override func layout() {
        super.layout()
        let scale = bounds.width / CGFloat(NeuralStageMetrics.designWidth)
        let crop = NeuralStageMetrics.designCrop
        head.frame = CGRect(
            x: -CGFloat(crop.x) * scale, y: 0, width: CGFloat(NeuralDesign.width) * scale,
            height: bounds.height)
        noteVisibility()
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        refresh(force: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        gate?.attach()
        noteVisibility()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(force: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    /// A stage scrolled out of the pane's view, in a window nobody can see or under an app in the
    /// background draws nothing and ticks nothing.
    func visibilityChanged() { noteVisibility() }

    private func noteVisibility() {
        let visible = !visibleRect.isEmpty && (gate?.isOpen ?? true)
        head.isSuspended = parked || !visible
    }

    func park() {
        guard !parked else { return }
        parked = true
        head.isSuspended = true
        head.removeFromSuperview()
    }

    func unpark() {
        guard parked else { return }
        parked = false
        addSubview(head, positioned: .below, relativeTo: nil)
        needsLayout = true
        head.isSuspended = false
        refresh(force: true)
        noteVisibility()
    }

    var isParked: Bool { parked }

    /// Whether the head holds a display link or a texture right now, for the harness.
    var holdsHead: Bool { head.superview != nil && head.window != nil }

    private var reduceMotion: Bool { host?.reduceMotion ?? !ActivityPulse.motionAllowed }

    private func budget() -> AnimationBudget {
        TileGovernor.animation(
            level: MotionBudget.level,
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func inks() -> BrainInks {
        paletteOverride.map { BrainInks(palette: $0) }
            ?? host?.inks ?? BrainInks.current(for: effectiveAppearance)
    }

    /// A palette to draw in instead of the window's, for the poster's own look.
    var paletteOverride: Palette?

    private func inkKey(_ inks: BrainInks) -> Int {
        var hasher = Hasher()
        hasher.combine(inks.palette.name)
        hasher.combine(inks.palette.isDark)
        hasher.combine(inks.palette.accent)
        hasher.combine(inks.palette.text)
        return hasher.finalize()
    }

    /// Brings the whole stage to the model: the head, the nodes and wires, the rings and the
    /// accessibility tree. Cheap when nothing changed.
    func refresh(force: Bool = false) {
        guard let model = currentModel() else { return }
        let inks = inks()
        head.apply(
            model: model, palette: inks.palette, reduceMotion: reduceMotion, dive: currentDive,
            animationBudget: budget())
        let scale = head.designScale
        guard scale > 0 else { return }
        let key = inkKey(inks)
        let structural = model.revision != lastRevision || scale != lastScale || key != lastInks
        if structural {
            rebuild(model: model, inks: inks, scale: scale)
            lastRevision = model.revision
            lastScale = scale
            lastInks = key
        }
        updateDynamic(
            model: model, inks: inks, scale: scale, time: CACurrentMediaTime(),
            force: structural || force)
        updateAccessibility(model: model)
    }

    /// The clock: moves the dive, and during a replay the nodes and wires, in the frame the head
    /// draws. A live brain whose only motion is a ring on the render server asks nothing of it.
    private func tick(_ time: Double) {
        guard let model = currentModel() else { return }
        if diving != nil {
            stepDive(time: time)
            return
        }
        guard model.mode != .live else { return }
        if model.replayDone(now: time) {
            host?.updateModel { $0.stopReplay() }
            refresh(force: true)
            onActivity?()
            return
        }
        updateDynamic(
            model: model, inks: inks(), scale: head.designScale, time: time, force: false)
        onActivity?()
    }

    private func rebuild(model: NeuralBrainModel, inks: BrainInks, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let backing = window?.backingScaleFactor ?? 2
        if diving == nil, divedZone == nil {
            overlay.frame = CGRect(origin: .zero, size: head.contentRect.size)
        }
        overlay.contentsScale = backing
        for group in [tieGroup, wireGroup, viaGroup, labelGroup, batchGroup, nodeGroup, ringGroup] {
            group.frame = overlay.bounds
        }
        for layer in routeLayers + tieLayers + viaLayers { layer.removeFromSuperlayer() }
        for layer in zoneLabels.values { layer.removeFromSuperlayer() }
        routeLayers = []
        tieLayers = []
        viaLayers = []
        zoneLabels = [:]

        let wires = NeuralNodes.wires(model: model, time: 0, reduceMotion: true)
        for route in wires.routes {
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            let path = CGMutablePath()
            for (index, point) in route.points.enumerated() {
                let at = head.layerPoint(forDesign: point)
                if index == 0 { path.move(to: at) } else { path.addLine(to: at) }
            }
            layer.path = path
            wireGroup.addSublayer(layer)
            routeLayers.append(layer)
        }
        for tie in wires.ties {
            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.lineCap = .round
            let path = CGMutablePath()
            for arc in tie.arcs {
                path.move(to: head.layerPoint(forDesign: arc.from))
                path.addQuadCurve(
                    to: head.layerPoint(forDesign: arc.to),
                    control: head.layerPoint(forDesign: arc.control))
            }
            layer.path = path
            layer.lineDashPattern = [3.5, 3]
            tieGroup.addSublayer(layer)
            tieLayers.append(layer)
        }
        for _ in wires.vias {
            let layer = CAShapeLayer()
            viaGroup.addSublayer(layer)
            viaLayers.append(layer)
        }
        var counts = [Int](repeating: 0, count: NeuralZone.allCases.count)
        for step in model.turn.steps { counts[step.zone.rawValue] += 1 }
        for zone in NeuralZone.allCases where counts[zone.rawValue] > 0 {
            let label = CATextLayer()
            label.alignmentMode = .center
            label.contentsScale = backing
            label.isWrapped = false
            let size = max(8, 9.2 * scale * 1.15)
            label.fontSize = size
            label.font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            label.string = NSAttributedString(
                string: zone.displayLabel,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
                    .kern: 1.8 * scale,
                    .foregroundColor: inks.dome(zone),
                ])
            label.bounds = CGRect(x: 0, y: 0, width: 96 * scale, height: size * 1.4)
            let rect = zone.labelRect
            label.position = head.layerPoint(
                forDesign: NeuralPoint(rect.x + rect.width / 2, rect.y + rect.height / 2))
            labelGroup.addSublayer(label)
            zoneLabels[zone] = label
        }
        lastDynamic = 0
    }

    /// The nodes the filters hide, which draw at 28 percent: a node dims when its step and every
    /// step it stands for are hidden.
    private func dimmedNodes(_ model: NeuralBrainModel) -> Set<String> {
        let list = model.browseState.list
        guard list.isFiltered else { return [] }
        let hidden = list.hiddenIDs
        var out = Set<String>()
        for id in hidden {
            let node = list.nodeID(of: id)
            guard hidden.contains(node) else { continue }
            let members = list.ganglionMembers(of: node)
            if members.allSatisfy({ hidden.contains($0) }) { out.insert(node) }
        }
        return out
    }

    private func updateDynamic(
        model: NeuralBrainModel, inks: BrainInks, scale: CGFloat, time: Double, force: Bool
    ) {
        var hasher = Hasher()
        hasher.combine(model.revision)
        hasher.combine(model.selected)
        hasher.combine(model.provenanceToken)
        hasher.combine(model.pinned)
        hasher.combine(model.browseState.hovered)
        hasher.combine(model.pinnedStep)
        let filter = model.browseState.list.filter
        hasher.combine(filter.zones.map(\.rawValue).sorted())
        hasher.combine(filter.failedOnly)
        hasher.combine(filter.search)
        hasher.combine(reduceMotion)
        hasher.combine(diveProgress)
        hasher.combine(divedZone)
        hasher.combine(isFocused)
        let key = hasher.finalize()
        if !force, model.mode == .live, reveal == nil, key == lastDynamic { return }
        lastDynamic = key
        let reduce = reduceMotion
        let backing = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let wires = NeuralNodes.wires(model: model, time: time, reduceMotion: reduce)
        let wireScale = Float(reveal?.wireDraw ?? 1)
        let tieScale = Float(reveal?.tieDraw ?? 1)
        for (index, route) in wires.routes.enumerated() where index < routeLayers.count {
            let layer = routeLayers[index]
            let tone = inks.dome(route.zone)
            layer.strokeColor = tone.cgColor
            layer.lineWidth = route.hot ? 2.1 : 1.15
            layer.strokeEnd = CGFloat(route.lit * wireScale)
            var alpha: Float = route.hot ? 1 : 0.5
            if route.dimmed && !route.hot { alpha = 0.1 }
            if dimsOutside { alpha *= 0.15 }
            layer.opacity = alpha
        }
        for (index, via) in wires.vias.enumerated() where index < viaLayers.count {
            let layer = viaLayers[index]
            let center = head.layerPoint(forDesign: via.point)
            let radius = max(2, 3.2 * scale)
            layer.path = CGPath(
                ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius, width: radius * 2,
                    height: radius * 2), transform: nil)
            layer.fillColor = inks.dome(via.zone).cgColor
            var alpha: Float = via.hot ? 1 : 0.6
            if via.dimmed && !via.hot { alpha = 0.1 }
            layer.opacity = alpha * Float(via.lit) * wireScale
        }
        for (index, tie) in wires.ties.enumerated() where index < tieLayers.count {
            let layer = tieLayers[index]
            let tone = inks.dome(tie.isCommand ? .shell : .sense)
            layer.strokeColor = tone.cgColor
            layer.lineWidth = tie.hot ? 1.8 : 1.1
            layer.strokeEnd = CGFloat(tie.lit * tieScale)
            var alpha: Float = tie.hot ? 1 : 0.55
            if tie.dimmed && !tie.hot { alpha = 0.12 }
            if dimsOutside { alpha *= 0.15 }
            layer.opacity = alpha
        }

        let draws = NeuralNodes.draws(model: model, time: time, reduceMotion: reduce)
        nodeIDs = draws.map(\.id)
        let dim = dimmedNodes(model)
        if model.useInstancedNodes, reveal == nil {
            applyBatched(draws, inks: inks, scale: scale, backing: backing, reduce: reduce, dim: dim)
        } else {
            applyNodes(draws, inks: inks, scale: scale, backing: backing, reduce: reduce, dim: dim)
        }
        let list = model.browseState.list
        for (zone, label) in zoneLabels {
            let lit = model.selectedZone == nil || model.selectedZone == zone
            let hidden = list.isFiltered && list.filter.zones.isEmpty == false && !list.filter.zones.contains(zone)
            let base: Float = (lit ? 0.85 : 0.3) * (hidden ? 0.4 : 1)
            label.opacity = base * (divedZone == nil || divedZone == zone ? 1 : 0.2) * Float(reveal?.nodes.alpha(0) ?? 1)
        }
        updateRings(model: model, inks: inks, scale: scale, draws: draws, dim: dim, backing: backing)
    }

    private func updateRings(
        model: NeuralBrainModel, inks: BrainInks, scale: CGFloat, draws: [NeuralNodeDraw],
        dim: Set<String>, backing: CGFloat
    ) {
        guard fixedModel == nil, divedZone == nil || diveProgress >= 0.5, reveal == nil else {
            cursorRing.hide()
            previewRing.hide()
            return
        }
        let list = model.browseState.list
        func place(_ id: String?, mark: BrainRingMark, solid: Bool) {
            guard let id, let row = list.row(id: id) else {
                mark.hide()
                return
            }
            let node = list.nodeID(of: id)
            guard let draw = draws.first(where: { $0.id == node }) else {
                mark.hide()
                return
            }
            mark.show(
                at: head.layerPoint(forDesign: draw.point), nodeRadius: CGFloat(draw.radius) * scale,
                number: row.number, solid: solid, inks: inks, scale: scale,
                alpha: dim.contains(node) ? 0.5 : 1, backing: backing)
        }
        place(model.pinnedStep, mark: cursorRing, solid: true)
        let preview = model.browseState.hovered
        place(preview == model.pinnedStep ? nil : preview, mark: previewRing, solid: false)
    }

    /// Whether the dive has taken everything but its own zone out of the picture.
    private var dimsOutside: Bool { diveProgress > 0.5 }

    private func applyNodes(
        _ draws: [NeuralNodeDraw], inks: BrainInks, scale: CGFloat, backing: CGFloat, reduce: Bool,
        dim: Set<String>
    ) {
        for layer in batches.values { layer.isHidden = true }
        var seen = Set<String>()
        for (index, draw) in draws.enumerated() {
            seen.insert(draw.id)
            let node: BrainNode
            if let held = nodes[draw.id] {
                node = held
            } else {
                node = BrainNode()
                nodes[draw.id] = node
                nodeGroup.addSublayer(node.layer)
            }
            var fade = fade(for: draw)
            if dim.contains(draw.id) { fade *= 0.28 }
            var pop: CGFloat = 1
            if let reveal {
                fade *= Float(reveal.nodes.alpha(index))
                pop = CGFloat(reveal.nodes.scale(index))
            }
            node.apply(
                draw, center: head.layerPoint(forDesign: draw.point), scale: scale, inks: inks,
                backing: backing, reduceMotion: reduce, fade: fade, pop: pop)
        }
        for id in nodes.keys where !seen.contains(id) {
            nodes[id]?.layer.removeFromSuperlayer()
            nodes[id] = nil
        }
    }

    /// How much of a node is left while a dive is under way: the zone being dived into keeps all of
    /// it and every other zone goes nearly dark.
    private func fade(for draw: NeuralNodeDraw) -> Float {
        guard let zone = diving?.zone ?? divedZone, diveProgress > 0 else { return 1 }
        return draw.zone == zone ? 1 : Float(1 - 0.85 * diveProgress)
    }

    /// Past `NeuralNodes.instancingThreshold` nodes a layer each would be a layer tree the size of
    /// the turn, so the nodes at rest are drawn as one path per zone and tone, and only the node
    /// the pointer is on, the one the cursor is on and the ones an answer word points at keep a
    /// layer.
    private func applyBatched(
        _ draws: [NeuralNodeDraw], inks: BrainInks, scale: CGFloat, backing: CGFloat, reduce: Bool,
        dim: Set<String>
    ) {
        var groups: [String: (color: NSColor, dashed: Bool, alpha: Float, path: CGMutablePath)] = [:]
        var singles: [NeuralNodeDraw] = []
        for draw in draws where draw.lit > 0 {
            if draw.hot || draw.pinned || draw.motion != .still {
                singles.append(draw)
                continue
            }
            let dimmed = dim.contains(draw.id)
            let name = "\(draw.zone.rawValue)-\(draw.tone)-\(draw.dimmed || dimmed)-\(draw.shape)"
            if groups[name] == nil {
                groups[name] = (
                    inks.dome(draw.tone, zone: draw.zone),
                    draw.status == .stopped || draw.status == .stalled,
                    draw.dimmed || dimmed ? 0.22 : Float(draw.lit), CGMutablePath()
                )
            }
            let radius = max(3, CGFloat(draw.radius) * scale)
            let at = head.layerPoint(forDesign: draw.point)
            groups[name]?.path.addPath(
                BrainShapes.path(draw.shape, radius: radius),
                transform: CGAffineTransform(translationX: at.x - radius, y: at.y - radius))
        }
        for layer in batches.values { layer.isHidden = true }
        for (name, group) in groups {
            let layer: CAShapeLayer
            if let held = batches[name] {
                layer = held
            } else {
                layer = CAShapeLayer()
                layer.lineJoin = .round
                batches[name] = layer
                batchGroup.addSublayer(layer)
            }
            layer.frame = batchGroup.bounds
            layer.isHidden = false
            layer.path = group.path
            layer.fillColor = NSColor.black.withAlphaComponent(0.66).cgColor
            layer.strokeColor = group.color.cgColor
            layer.lineWidth = 1.3
            layer.lineDashPattern = group.dashed ? [3, 2.4] : nil
            layer.opacity = group.alpha
        }
        var seen = Set<String>()
        for draw in singles {
            seen.insert(draw.id)
            let node: BrainNode
            if let held = nodes[draw.id] {
                node = held
            } else {
                node = BrainNode()
                nodes[draw.id] = node
                nodeGroup.addSublayer(node.layer)
            }
            node.apply(
                draw, center: head.layerPoint(forDesign: draw.point), scale: scale, inks: inks,
                backing: backing, reduceMotion: reduce, fade: dim.contains(draw.id) ? 0.28 : 1)
        }
        for id in nodes.keys where !seen.contains(id) {
            nodes[id]?.layer.removeFromSuperlayer()
            nodes[id] = nil
        }
    }

    /// A design point in this view's own coordinates; the head fills the stage and both run up.
    private func stagePoint(_ design: NeuralPoint) -> CGPoint {
        let rect = head.contentRect
        let scale = head.designScale
        let origin = head.frame.origin
        return CGPoint(
            x: origin.x + rect.minX + CGFloat(design.x) * scale,
            y: origin.y + rect.maxY - CGFloat(design.y) * scale)
    }

    /// Where a node is, in the stage's coordinates (y up), for the harness and the accessibility
    /// frames.
    func center(ofStep id: String) -> CGPoint? {
        guard let point = currentModel()?.point(of: id) else { return nil }
        return stagePoint(point)
    }

    /// The nodes' centres in the head's design space: the obstacles a leader line goes around.
    var nodeCentres: [NeuralPoint] {
        guard let model = currentModel() else { return [] }
        return model.steps.compactMap { model.point(of: $0.id) }
    }

    private func zone(atLabel point: CGPoint) -> NeuralZone? {
        guard let model = currentModel() else { return nil }
        let used = Set(model.steps.map(\.zone))
        let design = head.designPoint(forViewPoint: convert(point, to: head))
        for zone in NeuralZone.allCases where used.contains(zone) {
            let rect = zone.labelRect
            if design.x >= rect.x - 4, design.x <= rect.maxX + 4, design.y >= rect.y - 4,
                design.y <= rect.maxY + 4
            {
                return zone
            }
        }
        return nil
    }

    private func hit(at point: CGPoint) -> String? {
        guard let model = currentModel(), divedZone == nil, diving == nil else { return nil }
        let scale = max(head.designScale, 0.05)
        let local = convert(point, to: head)
        return model.hit(at: head.designPoint(forViewPoint: local), slop: 4 / Double(scale))
    }

    func setProvenance(_ token: String?) {
        guard currentModel()?.provenanceToken != token else { return }
        host?.updateModel { $0.setProvenance(token: token) }
        head.setNeedsRender()
        refresh(force: true)
        onActivity?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard divedZone == nil else { return }
        host?.hoverStep(hit(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        host?.hoverStep(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        host?.stagePressed()
        if divedZone != nil || diving != nil {
            surface()
            return
        }
        if let id = hit(at: point) {
            if event.clickCount >= 2, let step = currentModel()?.step(id: id), step.isCard,
                step.zone == .delegate
            {
                host?.openSubagent(id)
                return
            }
            host?.browse(.clickNode(id, double: event.clickCount >= 2), grabFocus: false)
            return
        }
        if let zone = zone(atLabel: point) {
            dive(into: zone)
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        guard let id = hit(at: point) else { return }
        host?.presentMenu(forStep: id, event: event, in: self)
    }

    override func keyDown(with event: NSEvent) {
        if host?.handleBrainKey(event, from: self) == true { return }
        nextResponder?.keyDown(with: event)
    }

    func takesBrainKey(_ event: NSEvent) -> Bool { host?.brainKeyApplies(event) ?? false }

    func announce(_ text: String) {
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// Dives into a zone: the chassis and the glass fly past about the zone's centre while the other
    /// zones go dim. Escape, a press on the stage or the Surface verb comes out the same way. Under
    /// reduced motion the dive lands at once.
    func dive(into zone: NeuralZone) {
        guard let model = currentModel(), divedZone == nil, diving == nil,
            model.turn.steps.contains(where: { $0.zone == zone })
        else { return }
        host?.updateModel {
            $0.setDiving(true)
            $0.setDive(zone: zone)
        }
        diving = Dive(zone: zone, start: CACurrentMediaTime(), surfacing: false)
        onDive?(zone)
        if reduceMotion {
            finishDive(zone: zone, surfacing: false)
            return
        }
        refresh()
    }

    /// Lands a dive that is under way, at once, for a harness that does not wait for the display
    /// link and for the reader who asked for less movement.
    func completeDive() {
        guard let current = diving else { return }
        finishDive(zone: current.zone, surfacing: current.surfacing)
    }

    func surface() {
        guard let zone = divedZone ?? diving?.zone else { return }
        host?.updateModel { $0.setDiving(true) }
        divedZone = nil
        diving = Dive(zone: zone, start: CACurrentMediaTime(), surfacing: true)
        onDive?(nil)
        if reduceMotion {
            finishDive(zone: zone, surfacing: true)
            return
        }
        refresh()
    }

    private func stepDive(time: CFTimeInterval) {
        guard let current = diving else { return }
        let raw = min(1, max(0, (time - current.start) / Self.diveDuration))
        let eased = NeuralTransition.easeInOutCubic(raw)
        let progress = current.surfacing ? 1 - eased : eased
        apply(dive: progress, zone: current.zone)
        if raw >= 1 { finishDive(zone: current.zone, surfacing: current.surfacing) }
    }

    private func apply(dive progress: Double, zone: NeuralZone) {
        diveProgress = progress
        let center = NeuralPoint(
            zone.center.x / NeuralDesign.width, zone.center.y / NeuralDesign.height)
        let chassis = Float(1 + 3.4 * progress)
        let fade = Float(1 - max(0, min(1, (Double(chassis) - 1.5) / 1.1)))
        currentDive = progress <= 0
            ? .none
            : NeuralDive(
                center: center, chassisScale: chassis, glassScale: Float(1 + 1.5 * progress),
                fade: fade)
        let at = head.layerPoint(forDesign: zone.center)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = overlay.bounds.size
        overlay.anchorPoint = CGPoint(
            x: size.width > 0 ? at.x / size.width : 0.5, y: size.height > 0 ? at.y / size.height : 0.5)
        overlay.position = at
        overlay.setAffineTransform(
            CGAffineTransform(scaleX: 1 + 0.9 * progress, y: 1 + 0.9 * progress))
        CATransaction.commit()
        guard let model = currentModel() else { return }
        head.apply(
            model: model, palette: inks().palette, reduceMotion: reduceMotion, dive: currentDive,
            animationBudget: budget())
        updateDynamic(
            model: model, inks: inks(), scale: head.designScale, time: CACurrentMediaTime(),
            force: true)
    }

    private func finishDive(zone: NeuralZone, surfacing: Bool) {
        diving = nil
        host?.updateModel { $0.setDiving(false) }
        if surfacing {
            divedZone = nil
            diveProgress = 0
            host?.updateModel { $0.setDive(zone: nil) }
            apply(dive: 0, zone: zone)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            overlay.frame = CGRect(origin: .zero, size: head.contentRect.size)
            overlay.setAffineTransform(.identity)
            CATransaction.commit()
        } else {
            divedZone = zone
            apply(dive: 1, zone: zone)
        }
        head.setNeedsRender()
        refresh(force: true)
        onActivity?()
    }

    private func updateAccessibility(model: NeuralBrainModel) {
        setAccessibilityLabel(host?.accessibleLabel ?? model.spoken)
        guard a11yRevision != model.revision || steps.count != nodeIDs.count else {
            refreshElementFrames(model: model)
            return
        }
        a11yRevision = model.revision
        steps = []
        for (position, id) in nodeIDs.enumerated() {
            guard let step = model.step(id: id) else { continue }
            let element = BrainStepElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(
                NeuralReading.announcement(for: step, of: model.turn.steps.count))
            element.onPress = { [weak self] in self?.host?.browse(.clickNode(id, double: false), grabFocus: false) }
            element.setAccessibilityIdentifier("brain.step.\(position)")
            steps.append(element)
        }
        refreshElementFrames(model: model)
    }

    private func refreshElementFrames(model: NeuralBrainModel) {
        let radius = NeuralDesign.nodeRadius * Double(head.designScale)
        for (position, id) in nodeIDs.enumerated() where position < steps.count {
            guard let point = model.point(of: id) else { continue }
            let center = stagePoint(point)
            steps[position].setAccessibilityFrameInParentSpace(
                CGRect(
                    x: center.x - radius, y: center.y - radius, width: radius * 2,
                    height: radius * 2))
        }
    }

    override func accessibilityChildren() -> [Any]? { steps }

    /// The nodes, wires and zone names as they stand, drawn into a context at the stage's own
    /// size: the poster lays them between the head's interior and its glass.
    func drawOverlay(in context: CGContext) {
        overlay.render(in: context)
    }

    /// What the stage holds, for the selftest: layers drawn, nodes lit, whether anything moves.
    var drawnNodeCount: Int { nodes.count + batches.values.filter { !$0.isHidden }.count }
    var nodeLayers: [BrainNode] { Array(nodes.values) }
    var wireLayerCount: Int { routeLayers.count }
    var isDiving: Bool { diving != nil }
    var accessibilitySteps: Int { steps.count }
    var hasCursorRing: Bool { !cursorRing.layer.isHidden }
    var hasPreviewRing: Bool { !previewRing.layer.isHidden }
    var revealActive: Bool { reveal != nil }
}
