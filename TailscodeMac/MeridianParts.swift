import AppKit
import TailscodeCore

/// A flat ground that answers a change of light: a fill, an optional hairline and a radius, all
/// asked for again whenever the appearance or the theme changes, because a `CGColor` kept in a layer
/// is the light it was resolved under and would sit in the old theme for ever. The glance's rules, tiles,
/// dots and cards, and the sheet's insight card, are all this view with different numbers.
@MainActor
final class TintView: NSView {
    var fill: (() -> NSColor)? {
        didSet { needsDisplay = true }
    }
    var stroke: (() -> NSColor)? {
        didSet { needsDisplay = true }
    }
    var radius: CGFloat? {
        didSet { needsLayout = true }
    }

    override var wantsUpdateLayer: Bool { true }

    init(fill: (() -> NSColor)? = nil, stroke: (() -> NSColor)? = nil, radius: CGFloat? = nil) {
        self.fill = fill
        self.stroke = stroke
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = radius ?? bounds.height / 2
    }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fill?().cgColor
            layer.borderColor = stroke?().cgColor
            layer.borderWidth = stroke == nil ? 0 : 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func repaint() { needsDisplay = true }
}

/// How a strip of daylight is coloured, in one place so the glance's strips and the sheet's lanes
/// cannot drift apart: night is the theme's canvas turned down, day is the info colour a little way
/// into the canvas, and a stop's light says how far between them. A gradient layer holds colours
/// resolved under one appearance, so these are computed under the view's own.
@MainActor
enum DaylightPalette {
    static var night: NSColor {
        MacTheme.Color.canvas.blended(withFraction: 0.45, of: .black) ?? MacTheme.Color.canvas
    }

    static var day: NSColor {
        MacTheme.Color.canvas.blended(withFraction: 0.45, of: MacTheme.Color.info)
            ?? MacTheme.Color.canvas
    }

    static var sun: NSColor { MacTheme.Color.warning }

    static var moon: NSColor { MacTheme.Color.secondaryLabel }

    static var paleDot: NSColor { MacTheme.Color.label }

    static func gradient(for bar: DaylightBar, appearance: NSAppearance)
        -> (colors: [CGColor], locations: [NSNumber])
    {
        var colors: [CGColor] = []
        appearance.performAsCurrentDrawingAppearance {
            let night = Self.night
            let day = Self.day
            colors = bar.stops.map {
                (night.blended(withFraction: CGFloat($0.light), of: day) ?? night).cgColor
            }
        }
        return (colors, bar.stops.map { NSNumber(value: $0.position) })
    }
}

/// One place's day as a strip eight points tall with a dot at the moment it is: the glance's row.
/// The gradient is Core's `DaylightBar`; the dot is the sun's colour while the sun is up, a pale ink
/// while it is not and when the place has no sun to speak of.
@MainActor
final class DaylightStripView: NSView {
    static let stripHeight: CGFloat = 8
    static let dotSize: CGFloat = 14

    private let gradient = CAGradientLayer()
    private let dot = CALayer()
    private var marker = 0.0
    private(set) var bar = DaylightBar.flat
    private(set) var isUp: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.cornerRadius = Self.stripHeight / 2
        gradient.cornerCurve = .continuous
        dot.cornerRadius = Self.dotSize / 2
        dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        dot.shadowOffset = .zero
        dot.shadowRadius = 5
        layer?.addSublayer(gradient)
        layer?.addSublayer(dot)
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.dotSize)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(bar: DaylightBar, marker: Double, isUp: Bool?) {
        self.bar = bar
        self.marker = min(max(marker, 0), 1)
        self.isUp = isUp
        paint()
        needsLayout = true
    }

    var gradientLayer: CAGradientLayer { gradient }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = CGRect(
            x: 0, y: (bounds.height - Self.stripHeight) / 2, width: bounds.width,
            height: Self.stripHeight)
        dot.position = CGPoint(x: bounds.width * marker, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    @objc private func repaint() { paint() }

    private func paint() {
        let paint = DaylightPalette.gradient(for: bar, appearance: effectiveAppearance)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = paint.colors
        gradient.locations = paint.locations
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = (isUp == true ? DaylightPalette.sun : DaylightPalette.paleDot).cgColor
            dot.backgroundColor = color
            dot.shadowColor = color
            dot.shadowOpacity = isUp == true ? 0.85 : 0.35
        }
        CATransaction.commit()
    }
}

/// The sky at this desk, drawn at sixteen points: a horizon, the arc a body travels over it, and the
/// body where it stands. A sun is the warning colour with a glow, a moon is a crescent in a dim ink,
/// and at the edge of the day the sun is half set in a warmer tone. Everything is a shape layer and
/// the glyph is drawn once per reading: it runs no clock of its own.
@MainActor
final class SkyGlyphView: NSView {
    static let side: CGFloat = 16
    private static let centre = CGPoint(x: 8, y: 5)
    private static let radius: CGFloat = 5.5

    private let horizon = CAShapeLayer()
    private let track = CAShapeLayer()
    private let sky = CALayer()
    private let body = CAShapeLayer()
    private let clip = CAShapeLayer()
    private(set) var glyph: SkyGlyph?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)
        horizon.lineWidth = 1.5
        horizon.lineCap = .round
        horizon.fillColor = nil
        track.lineWidth = 1
        track.lineCap = .round
        track.fillColor = nil
        clip.fillColor = NSColor.black.cgColor
        sky.addSublayer(body)
        layer?.addSublayer(track)
        layer?.addSublayer(horizon)
        layer?.addSublayer(sky)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        shapeStatic()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ glyph: SkyGlyph) {
        self.glyph = glyph
        draw(glyph)
    }

    /// Where the body stands on its arc: progress 0 is the left horizon, 1 the right.
    static func position(progress: Double) -> CGPoint {
        let angle = Double.pi * (1 - min(max(progress, 0), 1))
        return CGPoint(
            x: centre.x + radius * CGFloat(cos(angle)), y: centre.y + radius * CGFloat(sin(angle)))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let glyph { draw(glyph) }
    }

    @objc private func repaint() {
        if let glyph { draw(glyph) }
    }

    private func shapeStatic() {
        let frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        for shape in [horizon, track, body] { shape.frame = frame }
        sky.frame = frame
        clip.frame = frame
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 1, y: Self.centre.y))
        line.addLine(to: CGPoint(x: Self.side - 1, y: Self.centre.y))
        horizon.path = line
        let arc = CGMutablePath()
        arc.addArc(
            center: Self.centre, radius: Self.radius, startAngle: .pi, endAngle: 0, clockwise: true)
        track.path = arc
        clip.path = CGPath(
            rect: CGRect(x: -2, y: Self.centre.y - 0.75, width: Self.side + 4, height: Self.side),
            transform: nil)
    }

    private func draw(_ glyph: SkyGlyph) {
        let point = Self.position(progress: glyph.progress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            horizon.strokeColor = MacTheme.Color.secondaryLabel.cgColor
            track.strokeColor = MacTheme.Color.secondaryLabel.withAlphaComponent(0.4).cgColor
            body.mask = nil
            body.shadowOpacity = 0
            sky.mask = glyph.phase == .twilight ? clip : nil
            switch glyph.phase {
            case .day:
                body.path = disc(at: point, radius: 2.6)
                body.fillColor = DaylightPalette.sun.cgColor
                glow(DaylightPalette.sun, opacity: 0.9, radius: 2.5)
            case .twilight:
                let warm =
                    DaylightPalette.sun.blended(withFraction: 0.35, of: MacTheme.Color.danger)
                    ?? DaylightPalette.sun
                body.path = disc(at: point, radius: 2.8)
                body.fillColor = warm.cgColor
                glow(warm, opacity: 0.7, radius: 2)
            case .night:
                body.path = disc(at: point, radius: 3.2)
                body.fillColor = DaylightPalette.moon.cgColor
                body.mask = crescentCut(at: point)
            }
        }
        CATransaction.commit()
    }

    private func glow(_ color: NSColor, opacity: Float, radius: CGFloat) {
        body.shadowColor = color.cgColor
        body.shadowOpacity = opacity
        body.shadowRadius = radius
        body.shadowOffset = .zero
    }

    private func disc(at point: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(
            ellipseIn: CGRect(
                x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2),
            transform: nil)
    }

    /// A mask that is everything but a disc stood a little off the moon's own, so what shows of
    /// the moon is the crescent the other side of it leaves.
    private func crescentCut(at point: CGPoint) -> CAShapeLayer {
        let everything = CGMutablePath()
        everything.addRect(CGRect(x: -4, y: -4, width: Self.side + 8, height: Self.side + 8))
        everything.addPath(disc(at: CGPoint(x: point.x + 1.9, y: point.y + 0.9), radius: 2.7))
        let cut = CAShapeLayer()
        cut.path = everything
        cut.fillRule = .evenOdd
        cut.fillColor = NSColor.black.cgColor
        cut.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        return cut
    }
}
