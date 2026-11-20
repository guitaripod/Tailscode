import AppKit
import TailscodeCore

/// An expert's mark: its two letters on its hue, a rounded square lit from the top-left the way the
/// design draws it. One drawing for every size — the chat list's run of marks, a sidebar row, the
/// page's head — so the mark is recognised before the name is read.
@MainActor
final class ExpertMarkView: NSView {
    var glyph: String { didSet { needsDisplay = true } }
    var hue: ExpertHue { didSet { needsDisplay = true } }
    private let side: CGFloat

    init(glyph: String, hue: ExpertHue, side: CGFloat) {
        self.glyph = glyph
        self.hue = hue
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side),
        ])
        setAccessibilityElement(false)
    }

    convenience init(row: ExpertRow, side: CGFloat) {
        self.init(glyph: row.expert.glyph, hue: row.hue, side: side)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    func show(_ row: ExpertRow) {
        glyph = row.expert.glyph
        hue = row.hue
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ExpertMarkView.paint(glyph: glyph, hue: hue, in: bounds)
    }

    /// The mark painted into `rect` in the current appearance.
    static func paint(glyph: String, hue: ExpertHue, in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let radius = side * 0.28
        let square = NSRect(
            x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let path = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)
        let base = ExpertInk.hue(hue).usingColorSpace(.sRGB) ?? .systemBlue
        let deep = base.blended(withFraction: 0.32, of: .black) ?? base
        NSGradient(starting: base, ending: deep)?.draw(in: path, angle: -60)
        let ink: NSColor = hue.wantsDarkGlyph ? NSColor(white: 0.12, alpha: 1) : .white
        let font = NSFont.systemFont(ofSize: max(7, side * 0.40), weight: .bold)
        let text = NSAttributedString(
            string: String(glyph.prefix(2)), attributes: [.font: font, .foregroundColor: ink, .kern: -0.2])
        let size = text.size()
        text.draw(
            at: NSPoint(x: square.midX - size.width / 2, y: square.midY - size.height / 2 + side * 0.01))
    }

    /// The mark as an image, drawn when it is displayed so it follows the appearance it lands in —
    /// for menus and the runs of marks text carries.
    static func image(glyph: String, hue: ExpertHue, side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            paint(glyph: glyph, hue: hue, in: rect)
            return true
        }
        image.accessibilityDescription = glyph
        return image
    }

    static func image(_ row: ExpertRow, side: CGFloat) -> NSImage {
        image(glyph: row.expert.glyph, hue: row.hue, side: side)
    }
}

/// A count in a capsule: the notes an expert waits on the person for.
@MainActor
final class ExpertBadgeView: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = MacTheme.Ramp.font(.badge)
        textColor = MacTheme.Color.onAccent
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 16).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let natural = super.intrinsicContentSize
        return NSSize(width: max(16, natural.width + 10), height: 16)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.accent.cgColor
        }
    }

    func show(_ count: Int?) {
        isHidden = count == nil
        stringValue = count.map(String.init) ?? ""
        invalidateIntrinsicContentSize()
    }
}
