import AppKit
import TailscodeCore

/// The head as a mark on a line: 28 points wide at the window's type size, the silhouette, a dot
/// in each zone the turn used (larger and brighter for more steps), a ring where the work is now or
/// where a failure was never recovered, and an eye that wears the state's tone. It is drawn from
/// Core's `NeuralGlyph` in layers, once, and only the live turn's dot and eye breathe, on the render
/// server, so a settled history of glyphs costs nothing after it is drawn.
@MainActor
final class BrainGlyphView: NSView {
    private let outline = CAShapeLayer()
    private let eyeHalo = CAShapeLayer()
    private let eye = CAShapeLayer()
    private var dots: [CAShapeLayer] = []
    private var rings: [CAShapeLayer] = []
    private var glyph: NeuralGlyph?
    private var face = NeuralFace.unknown
    private var motion = NeuralMotion.still
    private var laidOut: NSSize = .zero

    private static let baseWidth: CGFloat = 28

    var width: CGFloat { (Self.baseWidth * MacTheme.UIScale.factor).rounded() }
    var height: CGFloat { CGFloat(NeuralGlyph.height(forWidth: Double(width))) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
        for layer in [outline, eyeHalo, eye] { self.layer?.addSublayer(layer) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: width, height: height) }

    func show(_ glyph: NeuralGlyph, face: NeuralFace, motion: NeuralMotion) {
        guard glyph != self.glyph || face != self.face || motion != self.motion else { return }
        self.glyph = glyph
        self.face = face
        self.motion = motion
        invalidateIntrinsicContentSize()
        paint()
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { applyMotion() }
    }

    @objc private func motionPreferenceChanged() { applyMotion() }

    /// Design space to this view: the head's silhouette crop fills the view, y down.
    private func map(_ point: NeuralPoint) -> CGPoint {
        let box = NeuralGlyph.viewBox
        let scale = bounds.width / CGFloat(box.width)
        return CGPoint(
            x: (CGFloat(point.x) - CGFloat(box.x)) * scale,
            y: (CGFloat(point.y) - CGFloat(box.y)) * scale)
    }

    private var scale: CGFloat { bounds.width / CGFloat(NeuralGlyph.viewBox.width) }

    private func path(_ points: [NeuralPoint]) -> CGPath {
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            if index == 0 { path.move(to: map(point)) } else { path.addLine(to: map(point)) }
        }
        path.closeSubpath()
        return path
    }

    private func circle(at center: NeuralPoint, radius: Double) -> CGPath {
        let c = map(center)
        let r = CGFloat(radius) * scale
        return CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }

    private func paint() {
        guard let glyph, bounds.width > 0 else { return }
        let inks = BrainInks.current(for: effectiveAppearance)
        let tone = inks.page(glyph.eyeTone, face: face)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.path = path(NeuralGlyph.outline)
            outline.fillColor = inks.raised.cgColor
            outline.strokeColor = inks.textDim.withAlphaComponent(0.8).cgColor
            outline.lineWidth = max(1, scale * 14)
            outline.lineJoin = .round
            eyeHalo.path = circle(
                at: NeuralGlyph.eyeHalo.center, radius: NeuralGlyph.eyeHalo.radius)
            eyeHalo.fillColor = tone.withAlphaComponent(CGFloat(NeuralGlyph.eyeHalo.opacity)).cgColor
            eye.path = path(NeuralGlyph.eyeBar)
            eye.fillColor = tone.cgColor
            rebuildDots(glyph, inks: inks, tone: tone)
        }
        applyMotion()
    }

    private func rebuildDots(_ glyph: NeuralGlyph, inks: BrainInks, tone: NSColor) {
        for layer in dots + rings { layer.removeFromSuperlayer() }
        dots = []
        rings = []
        for dot in glyph.dots {
            let layer = CAShapeLayer()
            layer.path = circle(at: dot.center, radius: dot.radius)
            layer.fillColor = inks.page(dot.zone).withAlphaComponent(CGFloat(dot.opacity)).cgColor
            self.layer?.insertSublayer(layer, below: eyeHalo)
            dots.append(layer)
            if let ring = dot.activeRing {
                rings.append(ringLayer(dot, ring, color: tone, inks: inks))
            }
            if let ring = dot.failureRing {
                rings.append(
                    ringLayer(dot, ring, color: NSColor(hex: inks.palette.danger) ?? tone, inks: inks))
            }
        }
    }

    private func ringLayer(
        _ dot: NeuralGlyph.Dot, _ ring: NeuralGlyph.Ring, color: NSColor, inks: BrainInks
    ) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = circle(at: dot.center, radius: ring.radius)
        layer.fillColor = nil
        layer.strokeColor = color.cgColor
        layer.lineWidth = max(1, CGFloat(ring.strokeWidth) * scale)
        self.layer?.addSublayer(layer)
        return layer
    }

    /// The live turn's lit dot and its eye breathe on the render server; everything settled holds
    /// perfectly still, and so does everything when the desk asks for less movement.
    private func applyMotion() {
        guard let glyph else { return }
        for (index, dot) in glyph.dots.enumerated() where index < dots.count {
            BrainMotion.breathe(dots[index], dot.isLive ? motion : .still)
        }
        BrainMotion.breathe(eye, motion)
        BrainMotion.breathe(eyeHalo, motion)
        for ring in rings { BrainMotion.breathe(ring, motion) }
    }

    /// Whether anything on the glyph is moving, for the harness that proves a settled one is not.
    var isMoving: Bool {
        ([eye, eyeHalo] + dots + rings).contains { BrainMotion.isBreathing($0) }
    }
}
