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

    /// Whether the plate itself takes a press, so a child it holds — a search field, a row — can be
    /// reached. A ground whose children only draw leaves it false and is transparent to the pointer.
    var takesPresses = false

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        takesPresses ? super.hitTest(point) : nil
    }

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
/// cannot drift apart: night is the theme's canvas turned down, day is the info colour blended into
/// the canvas, and a stop's light says how far between them. The two faces need two weights of the
/// same recipe — the light canvas can carry a soft cool grey and a clear wash of the day colour,
/// while the dark one needs its night turned right down for the day to show at all. A gradient layer
/// holds colours resolved under one appearance, so these are computed under the view's own.
@MainActor
enum DaylightPalette {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func night(dark: Bool) -> NSColor {
        let canvas = MacTheme.Color.canvas
        guard !dark else {
            return canvas.blended(withFraction: 0.45, of: .black) ?? canvas
        }
        let cool = canvas.blended(withFraction: 0.07, of: MacTheme.Color.info) ?? canvas
        return cool.blended(withFraction: 0.09, of: .black) ?? cool
    }

    static func day(dark: Bool) -> NSColor {
        let canvas = MacTheme.Color.canvas
        return canvas.blended(withFraction: dark ? 0.45 : 0.34, of: MacTheme.Color.info)
            ?? canvas
    }

    static var sun: NSColor { MacTheme.Color.warning }

    static var moon: NSColor { MacTheme.Color.secondaryLabel }

    static var paleDot: NSColor { MacTheme.Color.label }

    static func gradient(for bar: DaylightBar, appearance: NSAppearance)
        -> (colors: [CGColor], locations: [NSNumber])
    {
        var colors: [CGColor] = []
        appearance.performAsCurrentDrawingAppearance {
            let night = Self.night(dark: Self.isDark(appearance))
            let day = Self.day(dark: Self.isDark(appearance))
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

/// The labels Meridian is made of. None of them ellipsizes: a one-line label is as wide as its own
/// words measure at the type size in force and says so to Auto Layout, and a label that may need
/// more room wraps. Which is why a larger type scale makes a larger sheet rather than a shortened
/// one.
@MainActor
enum MeridianLabel {
    static func make(
        _ text: String, role: TypeRole, color: NSColor = MacTheme.Color.label,
        alignment: NSTextAlignment = .natural
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = MacTheme.Ramp.font(role)
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    static func framed(
        _ role: TypeRole, color: NSColor = MacTheme.Color.label, alignment: NSTextAlignment = .natural
    ) -> NSTextField {
        let field = make("", role: role, color: color, alignment: alignment)
        field.translatesAutoresizingMaskIntoConstraints = true
        return field
    }

    static func wrapping(_ text: String, role: TypeRole, color: NSColor = MacTheme.Color.label)
        -> MeridianWrapLabel
    {
        let field = MeridianWrapLabel(wrappingLabelWithString: text)
        field.font = MacTheme.Ramp.font(role)
        field.textColor = color
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func width(of text: String, role: TypeRole) -> CGFloat {
        let size = NSAttributedString(
            string: text, attributes: [.font: MacTheme.Ramp.font(role)]
        ).size()
        return ceil(size.width) + 4
    }

    static func height(of role: TypeRole) -> CGFloat {
        let font = MacTheme.Ramp.font(role)
        return ceil(font.ascender - font.descender + font.leading) + 2
    }

    static func height(wrapping text: String, role: TypeRole, width: CGFloat) -> CGFloat {
        guard width > 0 else { return height(of: role) }
        let box = NSAttributedString(
            string: text, attributes: [.font: MacTheme.Ramp.font(role)]
        ).boundingRect(
            with: NSSize(width: max(0, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(box.height) + 2
    }
}

/// A wrapping label that tells Auto Layout how tall its words are once it knows how wide it is, which
/// a bare text field only learns on a second pass the sheet's stack does not give it.
@MainActor
final class MeridianWrapLabel: NSTextField {
    override func layout() {
        super.layout()
        guard preferredMaxLayoutWidth != bounds.width else { return }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

/// Views laid out left to right and wrapped onto further rows when the width runs out, with a
/// trailing group pushed to the right edge of the last row (or onto a row of its own when it does not
/// fit beside the rest). It is how the sheet's footer, the machines and the alarms stay whole at any
/// type size and any window width: what does not fit goes down a row, never into an ellipsis.
@MainActor
final class MeridianFlowView: NSView {
    var spacing: CGFloat = MacTheme.Spacing.s
    var rowSpacing: CGFloat = MacTheme.Spacing.s

    private(set) var leading: [NSView] = []
    private(set) var trailing: [NSView] = []
    private var measuredHeight: CGFloat = 0
    private var laidOutWidth: CGFloat = -1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(leading: [NSView], trailing: [NSView] = []) {
        (self.leading + self.trailing).forEach { $0.removeFromSuperview() }
        self.leading = leading
        self.trailing = trailing
        for view in leading + trailing {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        laidOutWidth = -1
        measuredHeight = plan(width: .greatestFiniteMagnitude).height
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    var widestItem: CGFloat {
        (leading + trailing).filter { !$0.isHidden }.map { size(of: $0).width }.max() ?? 0
    }

    private func size(of view: NSView) -> CGSize {
        let natural = view.intrinsicContentSize
        if natural.width >= 0, natural.height >= 0 { return CGSize(width: ceil(natural.width), height: ceil(natural.height)) }
        let fitting = view.fittingSize
        return CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
    }

    private func plan(width: CGFloat) -> (frames: [(NSView, CGRect)], height: CGFloat) {
        var rows: [[(NSView, CGSize, Bool)]] = []
        var used: [CGFloat] = []
        for view in leading where !view.isHidden {
            let size = size(of: view)
            if var last = rows.last, let lastUsed = used.last,
                lastUsed + (last.isEmpty ? 0 : spacing) + size.width <= width
            {
                last.append((view, size, false))
                rows[rows.count - 1] = last
                used[used.count - 1] = lastUsed + (last.count > 1 ? spacing : 0) + size.width
            } else {
                rows.append([(view, size, false)])
                used.append(size.width)
            }
        }
        let tail = trailing.filter { !$0.isHidden }.map { ($0, size(of: $0), true) }
        if !tail.isEmpty {
            let block = tail.map(\.1.width).reduce(0, +) + spacing * CGFloat(tail.count - 1)
            if let lastUsed = used.last, lastUsed + spacing + block <= width {
                rows[rows.count - 1] += tail
            } else {
                rows.append(tail)
                used.append(block)
            }
        }
        var frames: [(NSView, CGRect)] = []
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let height = row.map(\.1.height).max() ?? 0
            let head = row.filter { !$0.2 }
            let tailItems = row.filter { $0.2 }
            var x: CGFloat = 0
            for (view, size, _) in head {
                frames.append((view, CGRect(x: x, y: y + (height - size.height) / 2, width: size.width, height: size.height)))
                x += size.width + spacing
            }
            let block = tailItems.map(\.1.width).reduce(0, +) + spacing * CGFloat(max(0, tailItems.count - 1))
            var tx = (width.isFinite && width < 100_000 ? width : x + block) - block
            for (view, size, _) in tailItems {
                frames.append((view, CGRect(x: tx, y: y + (height - size.height) / 2, width: size.width, height: size.height)))
                tx += size.width + spacing
            }
            y += height + (index == rows.count - 1 ? 0 : rowSpacing)
        }
        return (frames, y)
    }

    override func layout() {
        super.layout()
        let result = plan(width: bounds.width)
        for (view, frame) in result.frames { view.frame = frame }
        laidOutWidth = bounds.width
        if abs(result.height - measuredHeight) > 0.5 {
            measuredHeight = result.height
            invalidateIntrinsicContentSize()
        }
    }
}

/// A small borderless symbol button that can be reached by Tab and says when it has focus, so the
/// controls on a lane that appear for a resting pointer appear for the keyboard too.
@MainActor
final class MeridianIconButton: NSButton {
    var onFocusChange: ((Bool) -> Void)?
    private var handler: () -> Void
    static let side: CGFloat = 22

    init(symbol: String, label: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        contentTintColor = MacTheme.Color.secondaryLabel
        target = self
        self.action = #selector(fire)
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
        translatesAutoresizingMaskIntoConstraints = true
        HoverPlate.attach(to: self, placement: .over, radius: 6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override var acceptsFirstResponder: Bool { isEnabled && alphaValue > 0 }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0 ? super.hitTest(point) : nil
    }

    func relabel(_ label: String) {
        toolTip = label
        setAccessibilityLabel(label)
    }

    @objc private func fire() { handler() }
}

/// A small capsule that says one thing and does one thing when pressed: a city the glance offers to
/// pin. Its words are as wide as they measure, so no name is ever cut.
@MainActor
final class MeridianTextChip: NSControl {
    private let ground = TintView(
        fill: { MacTheme.Color.canvasRaised }, stroke: { MacTheme.Color.separator })
    private let label: NSTextField
    private var handler: () -> Void

    init(text: String, action: @escaping () -> Void) {
        handler = action
        label = MeridianLabel.framed(.chip)
        super.init(frame: .zero)
        label.stringValue = text
        ground.translatesAutoresizingMaskIntoConstraints = true
        addSubview(ground)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Localized.text("Add %@", text))
        HoverPlate.attach(to: self, placement: .over, radius: intrinsicContentSize.height / 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let size = MeridianMetrics.fit(label)
        return NSSize(width: size.width + 20, height: max(24, size.height + 8))
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let size = MeridianMetrics.fit(label)
        label.frame = CGRect(x: 10, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { handler() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": handler()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        handler()
        return true
    }
}
