import AppKit
import TailscodeCore

/// One node of a step list read by VoiceOver: a button that says what the step is and presses to
/// pin it.
private final class BrainStepElement: NSAccessibilityElement {
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?

    override func accessibilityPerformPress() -> Bool {
        let handler = onPress
        MainActor.assumeIsolated { handler?() }
        return true
    }
}

/// The open brain: the head drawn by Metal with the nodes, the wires and the zone names laid
/// between its interior and its glass, and everything a person can do with it.
///
/// The stage is content, an opaque canvas with a hairline, never glass. It holds no model: the
/// pane's `BrainStore` does, and every change the person makes (a hover, a pin, a replay, an
/// answer word pointed at) is made there and read back, so the head, the nodes, the ticker and the
/// scrubber all draw from one value. A hover lights the node's wires and raises its card; a click
/// pins it; a zone's name dives into the zone; double-clicking a Task node goes to its agent's card;
/// the arrows walk the steps and Escape comes back out.
///
/// Nothing here runs a clock of its own. The head's display link ticks the stage only while the
/// brain has something that moves, and a settled brain is drawn once and costs nothing after.
@MainActor
final class BrainStageView: NSView {
    static let maximumWidth: CGFloat = 760

    let turnID: String
    private weak var store: BrainStore?
    private weak var context: TranscriptContext?
    let head = NeuralHeadView()

    private let overlay = CALayer()
    private let tieGroup = CALayer()
    private let wireGroup = CALayer()
    private let viaGroup = CALayer()
    private let labelGroup = CALayer()
    private let nodeGroup = CALayer()
    private let batchGroup = CALayer()
    private let card = BrainCardView()
    private let diveList = BrainDiveList()

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
    private var visibleObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    private struct Dive {
        var zone: NeuralZone
        var start: CFTimeInterval
        var surfacing: Bool
    }

    private var diving: Dive?
    private(set) var divedZone: NeuralZone?
    private var currentDive = NeuralDive.none
    private var diveProgress: Double = 0

    /// A model to draw instead of the store's, for a picture that must not show a hover, a pin or a
    /// replay: the poster of a turn.
    var fixedModel: NeuralBrainModel?

    private func currentModel() -> NeuralBrainModel? { fixedModel ?? store?.model(turnID) }

    /// Told after a tick that moved the head, a change the person made, or a dive's end, so the
    /// row's ticker and scrubber follow without a clock of their own.
    var onActivity: (() -> Void)?

    static let diveDuration: CFTimeInterval = 0.7

    init(turnID: String, store: BrainStore, context: TranscriptContext) {
        self.turnID = turnID
        self.store = store
        self.context = context
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        head.frame = bounds
        head.autoresizingMask = [.width, .height]
        addSubview(head)
        head.nodeLayer.addSublayer(overlay)
        for group in [tieGroup, wireGroup, viaGroup, labelGroup, batchGroup, nodeGroup] {
            overlay.addSublayer(group)
        }
        card.frame = NSRect(x: 0, y: 0, width: BrainCardView.width, height: 10)
        addSubview(card)
        diveList.onPick = { [weak self] id in self?.pinFromList(id) }
        diveList.onBack = { [weak self] in self?.surface() }
        addSubview(diveList)
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
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let visibleObserver { NotificationCenter.default.removeObserver(visibleObserver) }
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    /// The head's design space is 640 by 420 and the stage is exactly that shape, so the head fills
    /// it and the node layers are measured by the head's own scale.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: MacTheme.Radius.card, yRadius: MacTheme.Radius.card
        ).fill()
    }

    override func layout() {
        super.layout()
        head.frame = bounds
        diveList.frame = bounds.insetBy(dx: 10, dy: 10)
        noteVisibility()
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        refresh(force: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibleObserver { NotificationCenter.default.removeObserver(visibleObserver) }
        visibleObserver = nil
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        visibleObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteVisibility() }
        }
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

    /// A stage scrolled out of the pane's view draws nothing and ticks nothing.
    private func noteVisibility() {
        let visible = !visibleRect.isEmpty
        head.isSuspended = parked || !visible
    }

    /// Gives up the head, which is what holds the process's textures, while the pane is parked, the
    /// window is closed or the app has been away; taking it back puts the head in again and draws.
    func park() {
        guard !parked else { return }
        parked = true
        head.isSuspended = true
        head.removeFromSuperview()
    }

    func unpark() {
        guard parked else { return }
        parked = false
        head.frame = bounds
        addSubview(head, positioned: .below, relativeTo: card)
        head.isSuspended = false
        refresh(force: true)
        noteVisibility()
    }

    var isParked: Bool { parked }

    /// Whether the head holds a display link or a texture right now, for the harness.
    var holdsHead: Bool { head.superview != nil && head.window != nil }

    private var reduceMotion: Bool { !ActivityPulse.motionAllowed }

    private func budget() -> AnimationBudget {
        TileGovernor.animation(
            level: MotionBudget.level,
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func inks() -> BrainInks {
        paletteOverride.map { BrainInks(palette: $0) } ?? BrainInks.current(for: effectiveAppearance)
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

    /// Brings the whole stage to the store's model: the head, the nodes and wires, the card, the
    /// list a dive ended in and the accessibility tree. Cheap when nothing changed.
    func refresh(force: Bool = false) {
        guard let model = currentModel() else { return }
        let inks = inks()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = inks.rule.cgColor
        }
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
        updateCard(model: model, inks: inks)
        updateList(model: model, inks: inks)
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
            store?.withModel(turnID) { $0.stopReplay() }
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
        for group in [tieGroup, wireGroup, viaGroup, labelGroup, batchGroup, nodeGroup] {
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
        for zone in NeuralZone.allCases where zone != .say && counts[zone.rawValue] > 0 {
            let label = CATextLayer()
            label.alignmentMode = .center
            label.contentsScale = backing
            label.isWrapped = false
            let size = max(8, 9.2 * scale * 1.15)
            label.fontSize = size
            label.font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            label.string = NSAttributedString(
                string: zone.label,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
                    .kern: 1.8 * scale,
                    .foregroundColor: inks.dome(zone),
                ])
            label.bounds = CGRect(x: 0, y: 0, width: 96 * scale, height: size * 1.4)
            let at = head.layerPoint(
                forDesign: NeuralPoint(zone.center.x, zone.center.y - zone.well.ry - 11))
            label.position = at
            labelGroup.addSublayer(label)
            zoneLabels[zone] = label
        }
        lastDynamic = 0
    }

    private func updateDynamic(
        model: NeuralBrainModel, inks: BrainInks, scale: CGFloat, time: Double, force: Bool
    ) {
        var hasher = Hasher()
        hasher.combine(model.revision)
        hasher.combine(model.selected)
        hasher.combine(model.provenanceToken)
        hasher.combine(model.pinned)
        hasher.combine(reduceMotion)
        hasher.combine(diveProgress)
        hasher.combine(divedZone)
        let key = hasher.finalize()
        if !force, model.mode == .live, key == lastDynamic { return }
        lastDynamic = key
        let reduce = reduceMotion
        let backing = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let wires = NeuralNodes.wires(model: model, time: time, reduceMotion: reduce)
        for (index, route) in wires.routes.enumerated() where index < routeLayers.count {
            let layer = routeLayers[index]
            let tone = inks.dome(route.zone)
            layer.strokeColor = tone.cgColor
            layer.lineWidth = route.hot ? 2.1 : 1.15
            layer.strokeEnd = CGFloat(route.lit)
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
            layer.opacity = alpha * Float(via.lit)
        }
        for (index, tie) in wires.ties.enumerated() where index < tieLayers.count {
            let layer = tieLayers[index]
            let tone = inks.dome(tie.isCommand ? .shell : .sense)
            layer.strokeColor = tone.cgColor
            layer.lineWidth = tie.hot ? 1.8 : 1.1
            layer.strokeEnd = CGFloat(tie.lit)
            var alpha: Float = tie.hot ? 1 : 0.55
            if tie.dimmed && !tie.hot { alpha = 0.12 }
            if dimsOutside { alpha *= 0.15 }
            layer.opacity = alpha
        }

        let draws = NeuralNodes.draws(model: model, time: time, reduceMotion: reduce)
        nodeIDs = draws.map(\.id)
        if model.useInstancedNodes {
            applyBatched(draws, inks: inks, scale: scale, backing: backing, reduce: reduce)
        } else {
            applyNodes(draws, inks: inks, scale: scale, backing: backing, reduce: reduce)
        }
        for (zone, label) in zoneLabels {
            let lit = model.selectedZone == nil || model.selectedZone == zone
            label.opacity = (lit ? 0.85 : 0.3) * (divedZone == nil || divedZone == zone ? 1 : 0.2)
        }
    }

    /// Whether the dive has taken everything but its own zone out of the picture.
    private var dimsOutside: Bool { diveProgress > 0.5 }

    private func applyNodes(
        _ draws: [NeuralNodeDraw], inks: BrainInks, scale: CGFloat, backing: CGFloat, reduce: Bool
    ) {
        for layer in batches.values { layer.isHidden = true }
        var seen = Set<String>()
        for draw in draws {
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
                backing: backing, reduceMotion: reduce, fade: fade(for: draw))
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
    /// the pointer is on, the one pinned and the ones an answer word points at keep a layer.
    private func applyBatched(
        _ draws: [NeuralNodeDraw], inks: BrainInks, scale: CGFloat, backing: CGFloat, reduce: Bool
    ) {
        var groups: [String: (color: NSColor, dashed: Bool, alpha: Float, path: CGMutablePath)] = [:]
        var singles: [NeuralNodeDraw] = []
        for draw in draws where draw.lit > 0 {
            if draw.hot || draw.pinned || draw.motion != .still {
                singles.append(draw)
                continue
            }
            let name = "\(draw.zone.rawValue)-\(draw.tone)-\(draw.dimmed)-\(draw.shape)"
            if groups[name] == nil {
                groups[name] = (
                    inks.dome(draw.tone, zone: draw.zone),
                    draw.status == .stopped || draw.status == .stalled,
                    draw.dimmed ? 0.22 : Float(draw.lit), CGMutablePath()
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
                backing: backing, reduceMotion: reduce)
        }
        for id in nodes.keys where !seen.contains(id) {
            nodes[id]?.layer.removeFromSuperlayer()
            nodes[id] = nil
        }
    }

    private func updateCard(model: NeuralBrainModel, inks: BrainInks) {
        guard divedZone == nil, diving == nil, let reading = model.card, let id = model.selected,
            let point = model.point(of: id)
        else {
            card.hide()
            return
        }
        let height = card.show(reading, inks: inks)
        let anchor = stagePoint(point)
        let gap: CGFloat = 16
        var x = anchor.x + gap
        if x + BrainCardView.width > bounds.width - 6 { x = anchor.x - gap - BrainCardView.width }
        x = min(max(6, x), max(6, bounds.width - BrainCardView.width - 6))
        var y = anchor.y - height - 4
        if y < 6 { y = anchor.y + gap }
        y = min(max(6, y), max(6, bounds.height - height - 6))
        card.setFrameOrigin(NSPoint(x: x, y: y))
        card.isHidden = false
    }

    private func updateList(model: NeuralBrainModel, inks: BrainInks) {
        guard let zone = divedZone else {
            diveList.hide()
            return
        }
        let inZone = model.turn.steps.filter { $0.zone == zone }
        diveList.show(zone: zone, steps: inZone, inks: inks, pinned: model.pinned)
    }

    private func pinFromList(_ id: String) {
        mutate { $0.togglePin(id) }
    }

    /// A design point in this view's own coordinates; the head fills the stage and both run up.
    private func stagePoint(_ design: NeuralPoint) -> CGPoint {
        let rect = head.contentRect
        let scale = head.designScale
        return CGPoint(
            x: rect.minX + CGFloat(design.x) * scale, y: rect.maxY - CGFloat(design.y) * scale)
    }

    /// Where a node is, in the stage's coordinates, for the selftest and the accessibility frames.
    func center(ofStep id: String) -> CGPoint? {
        guard let point = currentModel()?.point(of: id) else { return nil }
        return stagePoint(point)
    }

    /// The zone name under a point, for the dive.
    private func zone(atLabel point: CGPoint) -> NeuralZone? {
        let scale = head.designScale
        for (zone, _) in zoneLabels {
            let center = stagePoint(
                NeuralPoint(zone.center.x, zone.center.y - zone.well.ry - 11))
            let rect = CGRect(
                x: center.x - 36 * scale, y: center.y - 9 * scale, width: 72 * scale,
                height: 18 * scale)
            if rect.contains(point) { return zone }
        }
        return nil
    }

    private func hit(at point: CGPoint) -> String? {
        guard let model = currentModel(), divedZone == nil, diving == nil else { return nil }
        let scale = max(head.designScale, 0.05)
        return model.hit(at: head.designPoint(forViewPoint: point), slop: 5 / Double(scale))
    }

    /// Makes one change to the model in the store and brings everything to it.
    private func mutate(_ change: (inout NeuralBrainModel) -> Void) {
        store?.withModel(turnID, change)
        head.setNeedsRender()
        refresh()
        onActivity?()
    }

    func setHover(_ id: String?) {
        guard currentModel()?.hovered != id else { return }
        mutate { $0.setHover(id) }
    }

    func togglePin(_ id: String) { mutate { $0.togglePin(id) } }

    func clearSelection() {
        guard currentModel()?.hasSelection == true else { return }
        mutate { $0.clearSelection() }
    }

    /// The answer word being pointed at, or nil to let go of it.
    func setProvenance(_ token: String?) {
        guard currentModel()?.provenanceToken != token else { return }
        mutate { $0.setProvenance(token: token) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !diveList.isHidden, diveList.frame.contains(local) {
            return super.hitTest(point)
        }
        return self
    }

    override func mouseMoved(with event: NSEvent) {
        guard divedZone == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        setHover(hit(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        guard currentModel()?.hovered != nil else { return }
        mutate { $0.setHover(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if divedZone != nil || diving != nil {
            if !diveList.frame.contains(point) { surface() }
            return
        }
        if let zone = zone(atLabel: point) {
            dive(into: zone)
            return
        }
        guard let id = hit(at: point) else {
            clearSelection()
            return
        }
        if event.clickCount >= 2, currentModel()?.step(id: id)?.zone == .delegate {
            context?.revealSubagent?(id)
            return
        }
        togglePin(id)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: walk(by: -1)
        case 124: walk(by: 1)
        case 36, 76: pinHovered()
        case 53: escape()
        default: nextResponder?.keyDown(with: event)
        }
    }

    /// Walks the steps in order, lighting each as the pointer would: the node's wires, its card, and
    /// what a screen reader says on arriving.
    func walk(by delta: Int) {
        guard let model = currentModel(), !nodeIDs.isEmpty, divedZone == nil else { return }
        let current = model.selected.flatMap { nodeIDs.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), nodeIDs.count - 1)
        } else {
            next = delta < 0 ? nodeIDs.count - 1 : 0
        }
        let id = nodeIDs[next]
        mutate { $0.setHover(id) }
        guard let model = currentModel(), let step = model.step(id: id) else { return }
        announce(NeuralReading.announcement(for: step, of: model.turn.steps.count))
    }

    private func pinHovered() {
        guard let model = currentModel(), let id = model.hovered ?? model.pinned else { return }
        togglePin(id)
    }

    /// Escape lets go of what was lit, comes out of a dive, and with nothing left to let go of gives
    /// the keyboard back to the composer.
    func escape() {
        if divedZone != nil || diving != nil {
            surface()
            return
        }
        if currentModel()?.hasSelection == true || currentModel()?.isProvenanceActive == true {
            mutate {
                $0.clearSelection()
                $0.setProvenance(token: nil)
            }
            return
        }
        context?.returnFocus?()
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// Dives into a zone: the chassis and the glass fly past about the zone's centre while the other
    /// zones go dim, and the zone's steps are listed when it ends. Escape, a press outside the list
    /// or its back line comes out the same way. Under reduced motion the dive lands at once.
    func dive(into zone: NeuralZone) {
        guard let model = currentModel(), divedZone == nil, diving == nil,
            model.turn.steps.contains(where: { $0.zone == zone })
        else { return }
        store?.withModel(turnID) {
            $0.clearSelection()
            $0.setDiving(true)
        }
        card.hide()
        diving = Dive(zone: zone, start: CACurrentMediaTime(), surfacing: false)
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
        store?.withModel(turnID) { $0.setDiving(true) }
        divedZone = nil
        diveList.hide()
        diving = Dive(zone: zone, start: CACurrentMediaTime(), surfacing: true)
        if reduceMotion {
            finishDive(zone: zone, surfacing: true)
            return
        }
        refresh()
    }

    private func stepDive(time: CFTimeInterval) {
        guard let current = diving else { return }
        let raw = min(1, max(0, (time - current.start) / Self.diveDuration))
        let eased = StreamCascade.ease(raw)
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
        store?.withModel(turnID) { $0.setDiving(false) }
        if surfacing {
            divedZone = nil
            diveProgress = 0
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
        setAccessibilityLabel(model.spoken)
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
            element.onPress = { [weak self] in self?.togglePin(id) }
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

    /// The nodes, wires and zone names as they stand, drawn into a context at the stage's own size:
    /// the poster lays them between the head's interior and its glass.
    func drawOverlay(in context: CGContext) {
        overlay.render(in: context)
    }

    /// What the stage holds, for the selftest: layers drawn, nodes lit, whether anything moves.
    var drawnNodeCount: Int { nodes.count + batches.values.filter { !$0.isHidden }.count }
    var nodeLayers: [BrainNode] { Array(nodes.values) }
    var wireLayerCount: Int { routeLayers.count }
    var cardIsShown: Bool { !card.isHidden }
    var cardReading: NeuralReading.Card? { card.reading }
    var diveListRows: Int { diveList.isHidden ? 0 : diveList.rowCount }
    var isDiving: Bool { diving != nil }
    var accessibilitySteps: Int { steps.count }
}
