import TailscodeCore
import UIKit

/// The node, wire and tie layers of one open brain, drawn between the head's interior and its
/// glass in the design's own 640 by 420 units and scaled onto the picture by one transform.
///
/// Everything a painter decides is here and nothing a model decides: which shape, how lit, which
/// colour and whether it is faded, hot or pinned all come from `NeuralNodes`, so the three clients
/// cannot disagree about a turn. Layers are built when the model's layout changes and only their
/// properties move afterwards; a running node's breath and a waiting node's heartbeat are
/// animations the render server runs at the activity tempo, so a live brain costs the app no work
/// between its events. Past `NeuralNodes.instancingThreshold` nodes the plain ones are drawn as
/// compound paths in a few shared layers, and only the nodes that carry news (running, waiting,
/// failed, pinned, a ganglion) keep a layer of their own.
@MainActor
final class BrainNodeField {
    private struct BatchKey: Hashable {
        let zone: NeuralZone
        let lit: Bool
        let faded: Bool
        let hot: Bool
    }

    let root = CALayer()
    private(set) var zoneLabelRects: [NeuralZone: CGRect] = [:]

    /// The steps the list's filters hide: the head draws their nodes at 28 percent.
    var dimmed: Set<String> = []

    private let ringLayer = CAShapeLayer()
    private let calloutLayer = CALayer()
    private let calloutText = CATextLayer()
    private var ringNode: String?

    private let wellLayer = CALayer()
    private let tieLayer = CALayer()
    private let wireLayer = CALayer()
    private let pulseLayer = CALayer()
    private let viaLayer = CALayer()
    private let batchLayer = CALayer()
    private let nodeLayer = CALayer()
    private let labelLayer = CALayer()

    private var ink: BrainInk
    private var scale: CGFloat = 1
    private var contentsScale: CGFloat = 2
    private var structure = -1
    private var wires: [CAShapeLayer] = []
    private var pulses: [Int: CAShapeLayer] = [:]
    private var vias: [CAShapeLayer] = []
    private var ties: [CAShapeLayer] = []
    private var wells: [NeuralZone: CAShapeLayer] = [:]
    private var labels: [NeuralZone: CATextLayer] = [:]
    private var nodes: [String: BrainNodeLayers] = [:]
    private var batches: [BatchKey: CAShapeLayer] = [:]
    private var lastFired = 0

    init(ink: BrainInk) {
        self.ink = ink
        root.bounds = CGRect(x: 0, y: 0, width: NeuralDesign.width, height: NeuralDesign.height)
        root.anchorPoint = .zero
        root.position = .zero
        for layer in [wellLayer, labelLayer, tieLayer, wireLayer, pulseLayer, viaLayer, batchLayer, nodeLayer] {
            root.addSublayer(layer)
        }
        buildWells()
        buildRing()
    }

    /// Applies a move's reveal to the field: each node pops in on its own beat, the wires and the ties
    /// draw along their length, and nothing is built or rebuilt while it runs.
    func setReveal(model: NeuralBrainModel?, frame: NeuralTransitionFrame) {
        guard let model else { return }
        revealing = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let reveal = frame.nodes
        for (index, step) in model.steps.enumerated() {
            guard let node = nodes[step.id] else { continue }
            let scale = CGFloat(reveal.scale(index))
            node.container.transform = CATransform3DMakeScale(scale, scale, 1)
            node.container.opacity = Float(reveal.alpha(index)) * node.restOpacity
        }
        var batchAlpha = 1.0
        if model.nodeCount > 0 {
            batchAlpha = Double(reveal.revealed) / Double(model.nodeCount)
        }
        batchLayer.opacity = Float(min(1, batchAlpha * 1.4))
        for layer in wires { layer.strokeEnd = CGFloat(frame.wireDraw) }
        for layer in ties { layer.strokeEnd = CGFloat(frame.tieDraw) }
        for layer in vias { layer.opacity = Float(frame.wireDraw) }
        pulseLayer.opacity = Float(frame.wireDraw)
        ringLayer.opacity = Float(frame.wireDraw)
        calloutLayer.opacity = Float(frame.wireDraw)
        labelLayer.opacity = Float(frame.progress)
        wellLayer.opacity = Float(frame.progress)
    }

    func clearReveal() {
        guard revealing else { return }
        revealing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for node in nodes.values {
            node.container.transform = CATransform3DIdentity
            node.container.opacity = node.restOpacity
        }
        batchLayer.opacity = 1
        for layer in wires { layer.strokeEnd = 1 }
        for layer in ties { layer.strokeEnd = 1 }
        pulseLayer.opacity = 1
        ringLayer.opacity = 1
        calloutLayer.opacity = 1
        labelLayer.opacity = 1
        wellLayer.opacity = 1
        CATransaction.commit()
    }

    private var revealing = false

    private func buildRing() {
        ringLayer.fillColor = nil
        ringLayer.isHidden = true
        ringLayer.shadowOpacity = 0.9
        ringLayer.shadowOffset = .zero
        calloutLayer.isHidden = true
        calloutLayer.cornerCurve = .continuous
        calloutText.alignmentMode = .center
        calloutText.truncationMode = .none
        calloutText.isWrapped = false
        calloutLayer.addSublayer(calloutText)
        root.addSublayer(ringLayer)
        root.addSublayer(calloutLayer)
    }

    /// Rings the step under the cursor: a ring a little off the node, with its number beside it,
    /// because at the head's size the numbers inside the nodes do not read.
    func setRing(_ ring: BrainRing?, model: NeuralBrainModel) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let ring, let point = model.point(of: ring.nodeID) else {
            ringLayer.isHidden = true
            calloutLayer.isHidden = true
            ringNode = nil
            return
        }
        ringNode = ring.nodeID
        let scale = max(scale, 0.01)
        let node = CGFloat(NeuralDesign.nodeRadius)
        let radius = node + 7
        ringLayer.path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ringLayer.position = CGPoint(x: point.x, y: point.y)
        ringLayer.lineWidth = 2.2 / scale
        ringLayer.strokeColor = ink.live.cgColor
        ringLayer.shadowColor = ink.live.cgColor
        ringLayer.shadowRadius = 5 / scale
        ringLayer.isHidden = false
        let font = UIFont.monospacedSystemFont(ofSize: 10 / scale * scale, weight: .bold)
        let text = NSAttributedString(
            string: String(ring.calloutNumber),
            attributes: [.font: font, .foregroundColor: UIColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 1)])
        let size = text.size()
        let padX = 6 / scale
        let height = 15 / scale
        let width = max(height, size.width / scale + padX * 2)
        calloutLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        calloutLayer.cornerRadius = height / 2
        calloutLayer.backgroundColor = ink.live.cgColor
        let ux = CGFloat(point.x) + radius * 0.72 + width / 2
        let uy = CGFloat(point.y) - radius * 0.72 - height / 2
        calloutLayer.position = CGPoint(x: min(ux, CGFloat(NeuralDesign.width) - width / 2 - 2), y: max(uy, height / 2 + 2))
        calloutText.contentsScale = contentsScale
        calloutText.string = NSAttributedString(
            string: String(ring.calloutNumber),
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 10 / scale, weight: .bold),
                .foregroundColor: UIColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 1),
            ])
        let line = 10 / scale * 1.2
        calloutText.frame = CGRect(x: 0, y: (height - line) / 2, width: width, height: line)
        calloutLayer.isHidden = false
    }

    /// How many design units a point of the screen is, which sets the sizes of text and hit
    /// slops that are chosen in points rather than in design.
    var designScale: CGFloat { scale }

    /// Sets the scale of the design onto the screen and the resolution text is rasterised at.
    func layout(scale newScale: CGFloat, contentsScale newContents: CGFloat) {
        guard newScale > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scale = newScale
        root.transform = CATransform3DMakeScale(newScale, newScale, 1)
        setContentsScale(newContents)
        layoutLabels()
        for node in nodes.values { node.sizeText(designScale: scale, contentsScale: contentsScale) }
        CATransaction.commit()
    }

    /// The resolution every text layer is rasterised at: the screen's, times how far the head is
    /// zoomed in, so a numeral stays sharp in a dive.
    func setContentsScale(_ value: CGFloat) {
        contentsScale = max(1, value)
        for layer in labels.values { layer.contentsScale = contentsScale }
        for node in nodes.values { node.text.contentsScale = contentsScale }
    }

    /// Recolours for a new palette. The layers are kept; `refresh` repaints them.
    func recolor(_ newInk: BrainInk) {
        ink = newInk
        for well in wells.values { well.strokeColor = ink.rule.cgColor }
        layoutLabels()
        ringLayer.strokeColor = ink.live.cgColor
        ringLayer.shadowColor = ink.live.cgColor
        calloutLayer.backgroundColor = ink.live.cgColor
    }

    /// Builds the layers for a model's layout. Nodes are made on demand by `refresh`.
    func rebuild(model: NeuralBrainModel) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        structure = model.revision
        for layer in wires { layer.removeFromSuperlayer() }
        for layer in pulses.values { layer.removeFromSuperlayer() }
        for layer in vias { layer.removeFromSuperlayer() }
        for layer in ties { layer.removeFromSuperlayer() }
        for node in nodes.values { node.container.removeFromSuperlayer() }
        for layer in batches.values { layer.removeFromSuperlayer() }
        pulses = [:]
        nodes = [:]
        batches = [:]
        wires = model.layout.routes.map { route in
            let layer = CAShapeLayer()
            layer.path = BrainShapes.polyline(route.points)
            layer.fillColor = nil
            layer.lineWidth = 1.2
            layer.lineCap = .round
            layer.lineJoin = .round
            wireLayer.addSublayer(layer)
            return layer
        }
        vias = model.layout.vias.map { via in
            let layer = CAShapeLayer()
            let radius: CGFloat = 3.4
            layer.path = CGPath(
                ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius),
                transform: nil)
            layer.position = CGPoint(x: via.point.x, y: via.point.y)
            viaLayer.addSublayer(layer)
            return layer
        }
        ties = model.layout.ties.map { tie in
            let layer = CAShapeLayer()
            layer.path = BrainShapes.arcs(tie.arcs)
            layer.fillColor = nil
            layer.lineWidth = 1.3
            layer.lineDashPattern = [3, 4]
            layer.lineCap = .round
            tieLayer.addSublayer(layer)
            return layer
        }
    }

    /// The design-space centre of a step's node, for anchoring a card to it.
    func centre(of id: String, in model: NeuralBrainModel) -> CGPoint? {
        model.point(of: id).map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// Paints the model as it is at `time`: lit nodes and wires, the selection's emphasis, the
    /// answer word's dimming, the wells of the zones that did work. `time` is the clock replay is
    /// read against; a live brain reads it for nothing.
    func refresh(model: NeuralBrainModel, time: Double, reduceMotion: Bool) {
        if model.revision != structure { rebuild(model: model) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let draws = NeuralNodes.draws(model: model, time: time, reduceMotion: reduceMotion)
        let drawn = NeuralNodes.wires(model: model, time: time, reduceMotion: reduceMotion)
        let selecting = model.hasSelection
        let pointing = model.isProvenanceActive
        let many = model.useInstancedNodes
        applyWires(drawn, selecting: selecting, pointing: pointing, many: many)
        applyVias(drawn.vias, selecting: selecting, pointing: pointing)
        applyTies(drawn.ties, selecting: selecting, pointing: pointing)
        applyNodes(draws, many: many, selecting: false, reduceMotion: reduceMotion)
        applyWells(model)
    }

    /// How many nodes have lit since the last call, for the haptic that says a node fired.
    func newlyLit(in model: NeuralBrainModel, time: Double) -> Int {
        guard model.mode != .live else {
            lastFired = model.steps.count
            return 0
        }
        guard let replay = model.replayTime(now: time) else { return 0 }
        let count = model.timeline.litCount(at: replay)
        defer { lastFired = count }
        return max(0, count - lastFired)
    }

    func resetFired() { lastFired = 0 }

    /// The design-space rectangle of a zone's label, grown so a finger can find it: never less
    /// than a finger's width and height on the screen, however small the head is drawn.
    func labelHit(at point: CGPoint) -> NeuralZone? {
        let finger = BrainCanvas.hit / max(scale, 0.01)
        for (zone, rect) in zoneLabelRects {
            let grown = rect.insetBy(
                dx: -max(0, (finger - rect.width) / 2), dy: -max(0, (finger - rect.height) / 2))
            if grown.contains(point) { return zone }
        }
        return nil
    }

    private func buildWells() {
        for zone in NeuralZone.allCases {
            let well = CAShapeLayer()
            let size = zone.well
            well.path = CGPath(
                ellipseIn: CGRect(x: -size.rx, y: -size.ry, width: 2 * size.rx, height: 2 * size.ry),
                transform: nil)
            well.position = CGPoint(x: zone.center.x, y: zone.center.y)
            well.fillColor = nil
            well.lineWidth = 1
            well.lineDashPattern = [3, 4]
            well.strokeColor = ink.rule.cgColor
            wellLayer.addSublayer(well)
            wells[zone] = well
            let text = CATextLayer()
            text.alignmentMode = .center
            text.truncationMode = .none
            text.isWrapped = false
            labelLayer.addSublayer(text)
            labels[zone] = text
        }
        layoutLabels()
    }

    private func layoutLabels() {
        let size = labelFontSize
        for zone in NeuralZone.allCases {
            guard let text = labels[zone] else { continue }
            let font = UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            let used = zonesInUse.contains(zone)
            text.string = NSAttributedString(
                string: zone.displayLabel,
                attributes: [
                    .font: font, .kern: size * 0.18,
                    .foregroundColor: used ? ink.zone(zone) : ink.rule.withAlphaComponent(0.9),
                ])
            text.contentsScale = contentsScale
            let width = size * 0.62 * CGFloat(zone.displayLabel.count) * 1.35 + 8
            let height = size * 1.3
            let well = zone.well
            let origin = CGPoint(
                x: zone.center.x - width / 2, y: zone.center.y - well.ry - 8 - height * 0.8)
            text.frame = CGRect(x: origin.x, y: origin.y, width: width, height: height)
            zoneLabelRects[zone] = text.frame.insetBy(dx: -8, dy: -10)
        }
    }

    private var zonesInUse: Set<NeuralZone> = []

    /// Labels read at six or seven points on a phone, however small the head is drawn, but never
    /// larger than the well under them can carry: a head of 208 points draws them smaller.
    private var labelFontSize: CGFloat { max(9, min(7 / max(scale, 0.01), 15)) }

    private func applyWells(_ model: NeuralBrainModel) {
        var used = Set<NeuralZone>()
        for step in model.steps { used.insert(step.zone) }
        let changed = used != zonesInUse
        zonesInUse = used
        for (zone, well) in wells {
            well.strokeColor =
                used.contains(zone) ? ink.zone(zone).mixed(with: ink.rule, 0.55).cgColor : ink.rule.cgColor
        }
        if changed { layoutLabels() }
    }

    private func applyWires(
        _ drawn: NeuralWires, selecting: Bool, pointing: Bool, many: Bool
    ) {
        for wire in drawn.routes where wire.id < wires.count {
            let layer = wires[wire.id]
            let tone = ink.zone(wire.zone)
            if wire.hot {
                layer.strokeColor = tone.cgColor
                layer.lineWidth = 2.4
                layer.opacity = 1
            } else {
                layer.strokeColor = (wire.lit >= 1 ? tone : ink.rule).cgColor
                layer.lineWidth = 1.2
                let rest: Float = wire.lit >= 1 ? (many ? 0.22 : 0.36) : (many ? 0.16 : 0.28)
                layer.opacity = (selecting || wire.dimmed) ? 0.1 : rest
            }
            applyPulse(wire, tone: tone)
        }
    }

    private func applyPulse(_ wire: NeuralWireDraw, tone: UIColor) {
        guard wire.isPulsing else {
            if let layer = pulses.removeValue(forKey: wire.id) { layer.removeFromSuperlayer() }
            return
        }
        let layer: CAShapeLayer
        if let held = pulses[wire.id] {
            layer = held
        } else {
            layer = CAShapeLayer()
            layer.path = BrainShapes.polyline(wire.points)
            layer.fillColor = nil
            layer.lineWidth = 3.2
            layer.lineCap = .round
            layer.lineJoin = .round
            pulseLayer.addSublayer(layer)
            pulses[wire.id] = layer
        }
        layer.strokeColor = tone.cgColor
        let head = min(max(CGFloat(wire.lit) * 1.1, 0), 1)
        layer.strokeEnd = head
        layer.strokeStart = max(0, head - 0.1)
    }

    private func applyVias(_ drawn: [NeuralViaDraw], selecting: Bool, pointing: Bool) {
        for (index, via) in drawn.enumerated() where index < vias.count {
            let layer = vias[index]
            layer.fillColor = (via.lit >= 1 ? ink.zone(via.zone) : ink.rule).cgColor
            layer.opacity = via.hot ? 1 : ((selecting || via.dimmed) ? 0.1 : 0.9)
        }
    }

    private func applyTies(_ drawn: [NeuralTieDraw], selecting: Bool, pointing: Bool) {
        for (index, tie) in drawn.enumerated() where index < ties.count {
            let layer = ties[index]
            layer.strokeColor = ink.special.cgColor
            layer.lineWidth = tie.hot ? 1.8 : 1.3
            if tie.hot {
                layer.opacity = 1
            } else {
                layer.opacity = (selecting || tie.dimmed) ? 0.15 : 0.55 * tie.lit
            }
        }
    }

    private func needsOwnLayer(_ draw: NeuralNodeDraw, many: Bool) -> Bool {
        !many || draw.isGanglion || draw.status != .ok || draw.pinned || draw.mark != nil
    }

    private func applyNodes(
        _ draws: [NeuralNodeDraw], many: Bool, selecting: Bool, reduceMotion: Bool
    ) {
        var alive = Set<String>()
        var groups: [BatchKey: CGMutablePath] = [:]
        for draw in draws {
            if needsOwnLayer(draw, many: many) {
                alive.insert(draw.id)
                let node = nodes[draw.id] ?? makeNode(draw.id)
                node.apply(
                    draw, ink: ink, selecting: selecting, reduceMotion: reduceMotion,
                    designScale: scale, filtered: dimmed.contains(draw.id))
            } else {
                let key = BatchKey(
                    zone: draw.zone, lit: draw.lit >= 0.5,
                    faded: (selecting && !draw.hot) || draw.dimmed || dimmed.contains(draw.id),
                    hot: draw.hot)
                let path = groups[key] ?? CGMutablePath()
                path.addPath(
                    BrainShapes.path(draw.shape, radius: CGFloat(draw.radius)),
                    transform: CGAffineTransform(translationX: draw.point.x, y: draw.point.y))
                groups[key] = path
            }
        }
        for (id, node) in nodes where !alive.contains(id) {
            node.container.removeFromSuperlayer()
            nodes[id] = nil
        }
        applyBatches(groups)
    }

    private func makeNode(_ id: String) -> BrainNodeLayers {
        let node = BrainNodeLayers()
        node.sizeText(designScale: scale, contentsScale: contentsScale)
        nodeLayer.addSublayer(node.container)
        nodes[id] = node
        return node
    }

    private func applyBatches(_ groups: [BatchKey: CGMutablePath]) {
        for (key, layer) in batches where groups[key] == nil {
            layer.removeFromSuperlayer()
            batches[key] = nil
        }
        for (key, path) in groups {
            let layer: CAShapeLayer
            if let held = batches[key] {
                layer = held
            } else {
                layer = CAShapeLayer()
                batchLayer.addSublayer(layer)
                batches[key] = layer
            }
            let tone = ink.zone(key.zone)
            layer.path = path
            layer.lineWidth = key.hot ? 2.4 : 1.7
            layer.lineJoin = .round
            layer.strokeColor = (key.lit ? tone : ink.rule).cgColor
            layer.fillColor =
                (key.lit ? ink.dome.mixed(with: tone, 0.17) : ink.dome).cgColor
            layer.opacity = key.faded ? 0.28 : 1
        }
    }
}

/// The layers of one node: its plate, the halo a thought wears, the ring inside a delegate, the
/// mark of a failure, the ring of a pin and the number.
@MainActor
final class BrainNodeLayers {
    let container = CALayer()
    let pin = CAShapeLayer()
    let halo = CAShapeLayer()
    let shape = CAShapeLayer()
    let inner = CAShapeLayer()
    let mark = CAShapeLayer()
    let text = CATextLayer()
    private var shapeKey: String?
    private var laidMotion: NeuralMotion = .still
    /// The opacity the node rests at, which a move's reveal multiplies and gives back.
    private(set) var restOpacity: Float = 1

    init() {
        for layer in [pin, halo, inner, mark] {
            layer.fillColor = nil
            layer.isHidden = true
        }
        pin.lineWidth = 1.6
        halo.lineWidth = 1
        halo.lineDashPattern = [2, 3]
        inner.lineWidth = 1
        inner.lineDashPattern = [2, 2]
        mark.lineWidth = 2
        mark.lineCap = .round
        shape.lineJoin = .round
        text.alignmentMode = .center
        text.truncationMode = .none
        text.isWrapped = false
        [pin, halo, shape, inner, mark, text].forEach { container.addSublayer($0) }
    }

    func sizeText(designScale: CGFloat, contentsScale: CGFloat) {
        text.contentsScale = contentsScale
        fontSize = max(9, 6.5 / max(designScale, 0.01))
        lastLabel = nil
    }

    private var fontSize: CGFloat = 9
    private var lastLabel: String?

    func apply(
        _ draw: NeuralNodeDraw, ink: BrainInk, selecting: Bool, reduceMotion: Bool,
        designScale: CGFloat, filtered: Bool = false
    ) {
        container.position = CGPoint(x: draw.point.x, y: draw.point.y)
        let radius = CGFloat(draw.radius)
        let key = "\(draw.shape)-\(radius)-\(draw.isGanglion)"
        if key != shapeKey {
            shapeKey = key
            let plate = BrainShapes.path(draw.isGanglion ? .circle : draw.shape, radius: radius)
            shape.path = plate
            shape.shadowPath = plate
            let base = CGFloat(NeuralDesign.nodeRadius)
            halo.path = BrainShapes.path(.circle, radius: base + 4)
            inner.path = BrainShapes.path(.circle, radius: base * 0.84)
            pin.path = BrainShapes.path(.circle, radius: radius + 6)
            let r = base
            let cross = CGMutablePath()
            cross.move(to: CGPoint(x: r * 0.55, y: -r * 1.15))
            cross.addLine(to: CGPoint(x: r * 1.25, y: -r * 1.85))
            cross.move(to: CGPoint(x: r * 1.25, y: -r * 1.15))
            cross.addLine(to: CGPoint(x: r * 0.55, y: -r * 1.85))
            mark.path = cross
            container.bounds = CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)
        }
        let tone = ink.color(for: draw.tone, zone: draw.zone)
        let lit = CGFloat(draw.lit)
        let onFill = ink.dome.mixed(with: tone, 0.17)
        let stroke = ink.rule.mixed(with: tone, lit)
        shape.fillColor = ink.dome.mixed(with: onFill, lit).cgColor
        shape.strokeColor = stroke.cgColor
        shape.lineWidth = draw.hot || draw.pinned ? 2.4 : (draw.isGanglion ? 2 : 1.7)
        switch draw.status {
        case .stopped: shape.lineDashPattern = [3, 3]
        case .stalled: shape.lineDashPattern = [5, 3]
        default: shape.lineDashPattern = draw.isGanglion ? [4, 3] : nil
        }
        let glow = Float(min(1, 0.5 * lit + CGFloat(draw.flash)))
        shape.shadowColor = tone.cgColor
        shape.shadowOpacity = draw.hot ? 0 : glow
        shape.shadowRadius = 3 + 9 * CGFloat(draw.flash)
        shape.shadowOffset = .zero
        halo.isHidden = draw.zone != .think || draw.isGanglion
        halo.strokeColor = tone.cgColor
        halo.opacity = lit < 0.5 ? 0.25 : 0.7
        inner.isHidden = draw.zone != .delegate || draw.isGanglion
        inner.strokeColor = tone.cgColor
        inner.opacity = lit < 0.5 ? 0.25 : 0.8
        mark.isHidden = draw.status != .failed
        mark.strokeColor = ink.danger.cgColor
        pin.isHidden = true
        pin.strokeColor = ink.live.cgColor
        let faded = (selecting && !draw.hot) || draw.dimmed
        restOpacity = filtered ? 0.28 : (faded ? 0.42 : (draw.isRecovered ? 0.7 : 1))
        container.opacity = restOpacity
        setLabel(draw.label, tone: ink.rule.mixed(with: tone, lit), ganglion: draw.isGanglion)
        lay(draw.motion, reduceMotion: reduceMotion)
    }

    private func setLabel(_ label: String, tone: UIColor, ganglion: Bool) {
        let size = ganglion ? fontSize * 1.33 : fontSize
        let id = "\(label)|\(size)|\(tone.hexString)"
        guard id != lastLabel else { return }
        lastLabel = id
        text.string = NSAttributedString(
            string: label,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: size, weight: .bold),
                .foregroundColor: tone,
            ])
        let height = size * 1.25
        let width = size * 0.66 * CGFloat(max(label.count, 2)) + 4
        text.frame = CGRect(x: -width / 2, y: -height / 2 - size * 0.04, width: width, height: height)
    }

    private func lay(_ motion: NeuralMotion, reduceMotion: Bool) {
        guard motion != laidMotion || (motion != .still && shape.animation(forKey: "motion") == nil)
        else { return }
        laidMotion = motion
        guard !reduceMotion, let animation = BrainNodeMotion.animation(for: motion) else {
            shape.removeAnimation(forKey: "motion")
            return
        }
        animation.beginTime = shape.convertTime(0, from: nil)
        shape.setRepeatingMotion(
            animation, forKey: "motion",
            meaning: motion == .heartbeat ? .attention : .working)
    }
}

/// The two swells a node knows, as keyframes the render server runs: the running node's breath and
/// the waiting node's two knocks. They are sampled from `NeuralMotion`, which reads the same
/// periods and floors as every badge in the app, and they begin at media time zero so every node
/// on screen, and every badge beside it, is at the same point in its cycle.
@MainActor
enum BrainNodeMotion {
    private static let segments = 96
    private static var cache: [String: CAAnimationGroup] = [:]

    static func animation(for motion: NeuralMotion) -> CAAnimationGroup? {
        let name: String
        let period: TimeInterval
        let floor: Double
        switch motion {
        case .breath:
            name = "breath"
            period = ActivityTuning.breathPeriod
            floor = ActivityTuning.breathFloor
        case .heartbeat:
            name = "heartbeat"
            period = ActivityTuning.heartbeatPeriod
            floor = ActivityTuning.heartbeatFloor
        case .sweep, .still:
            return nil
        }
        if let held = cache[name], let copy = held.copy() as? CAAnimationGroup { return copy }
        let level: (TimeInterval) -> Double = { motion.level(at: $0) }
        var opacity: [NSNumber] = []
        var scale: [NSNumber] = []
        for index in 0..<segments {
            let value = level(Double(index) / Double(segments) * period)
            opacity.append(NSNumber(value: value))
            let swell = (value - floor) / max(0.0001, 1 - floor)
            let low = motion == .breath ? 0.94 : 0.96
            let high = motion == .breath ? 1.08 : 1.12
            scale.append(NSNumber(value: low + (high - low) * swell))
        }
        opacity.append(opacity[0])
        scale.append(scale[0])
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = opacity
        fade.calculationMode = .linear
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = scale
        grow.calculationMode = .linear
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = period
        group.repeatCount = .infinity
        cache[name] = group
        return group.copy() as? CAAnimationGroup
    }
}
