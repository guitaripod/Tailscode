import AppKit
import ImageIO
import TailscodeCore

/// The verbs a finished picture offers, in a capsule of glass floating over its foot. Regular glass
/// plus the scrim token, because this is the one piece that sits on picture content and must be read
/// at a glance whatever the picture is. It holds its room invisibly while a render is out, so the
/// stage never changes shape, and it drops its words for icons when the stage is too narrow to hold
/// them — every button keeps its label for a screen reader and its words for a tooltip.
@MainActor
final class StudioVerbsCapsule: NSView {
    var onVerb: ((StudioStageVerb) -> Void)?
    var primaryID = ""
    private var verbs: [StudioStageVerb] = []
    private var buttons: [StudioVerbButton] = []
    private let glass = NSGlassEffectView()
    private let scrim = NSView()
    private var iconsOnly = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glass.cornerRadius = StudioTheme.capsuleHeight / 2
        scrim.wantsLayer = true
        scrim.layer?.cornerRadius = StudioTheme.capsuleHeight / 2
        scrim.layer?.cornerCurve = .continuous
        glass.contentView = scrim
        addSubview(glass)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(Localized.text("Picture actions"))
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            scrim.layer?.backgroundColor = StudioTheme.scrim.cgColor
        }
    }

    func show(_ next: [StudioStageVerb], holdsRoom: Bool) {
        guard next != verbs || !holdsRoom else { return }
        guard !next.isEmpty else { return }
        verbs = next
        for button in buttons { button.removeFromSuperview() }
        buttons = next.map { verb in
            let button = StudioVerbButton(verb: verb)
            button.onPress = { [weak self] in self?.onVerb?(verb) }
            scrim.addSubview(button)
            return button
        }
        needsLayout = true
        superview?.needsLayout = true
    }

    func fitting(maxWidth: CGFloat) -> NSSize {
        guard !buttons.isEmpty else { return NSSize(width: 0, height: StudioTheme.capsuleHeight) }
        let full = buttons.reduce(CGFloat(16)) { $0 + $1.width(iconsOnly: false) + 2 }
        iconsOnly = full > maxWidth
        let width = iconsOnly ? buttons.reduce(CGFloat(16)) { $0 + $1.width(iconsOnly: true) + 2 } : full
        return NSSize(width: min(maxWidth, width), height: StudioTheme.capsuleHeight)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        var x: CGFloat = 8
        for button in buttons {
            let width = button.width(iconsOnly: iconsOnly)
            button.iconsOnly = iconsOnly
            button.isPrimary = button.verb.id == primaryID
            button.frame = NSRect(x: x, y: 3, width: width, height: bounds.height - 6)
            x += width + 2
        }
    }
}

/// One verb in the capsule: its symbol and its word, ink on the glass, the primary one on the accent.
@MainActor
final class StudioVerbButton: NSView {
    let verb: StudioStageVerb
    var onPress: (() -> Void)?
    var iconsOnly = false {
        didSet { if iconsOnly != oldValue { needsDisplay = true } }
    }
    var isPrimary = false {
        didSet { if isPrimary != oldValue { needsDisplay = true } }
    }
    private let plate = PointerPlate()
    private var tracking: NSTrackingArea?
    private var pressing = false

    init(verb: StudioStageVerb) {
        self.verb = verb
        super.init(frame: .zero)
        plate.radius = 14
        addSubview(plate)
        toolTip = verb.hint
        setAccessibilityRole(.button)
        setAccessibilityLabel(verb.title)
        setAccessibilityHelp(verb.hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var title: String { verb.title.replacingOccurrences(of: "…", with: "") }

    func width(iconsOnly: Bool) -> CGFloat {
        iconsOnly ? 32 : 14 + 16 + 6 + StudioTheme.width(of: title, role: .control) + 14
    }

    override func layout() {
        super.layout()
        plate.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPrimary {
            MacTheme.Color.accent.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let ink = isPrimary ? MacTheme.Color.onAccent : (verb.isDestructive ? MacTheme.Color.danger : MacTheme.Color.onGlass)
        if let symbol = StudioTheme.symbol(verb.symbol, size: 12, weight: .medium)?.tinted(ink) {
            let side: CGFloat = 16
            let originX = iconsOnly ? (bounds.width - side) / 2 : 14
            symbol.draw(in: NSRect(x: originX, y: (bounds.height - side) / 2, width: side, height: side))
        }
        guard !iconsOnly else { return }
        let attributes = MacTheme.Ramp.attributes(.control, color: ink)
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: 14 + 16 + 6, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { if !isPrimary { plate.show(.hover) } }

    override func mouseExited(with event: NSEvent) {
        pressing = false
        plate.show(.rest)
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        if !isPrimary { plate.show(.press) }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        plate.show(.rest)
        if pressing, inside { onPress?() }
        pressing = false
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

extension NSImage {
    /// The symbol drawn in one ink, for a view that draws itself — a template image takes the
    /// colour of whatever fills it.
    fileprivate func tinted(_ color: NSColor) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }
}
