import AppKit
import TailscodeCore

extension NSView {
    /// What the theme in force draws besides its colours, in the face this view is wearing.
    /// Nothing under "System" and nothing for a theme that is only a palette.
    var scenery: Scenery? { sceneryPalette?.scenery }

    var sceneryPalette: Palette? {
        ThemePalette.palette(themeID: ThemeSelection.themeID, dark: effectiveAppearance.isDark)
    }
}

/// The sky behind a conversation: the canvas, and on it the stars or the dunes of the theme the
/// window is wearing.
///
/// It is the transcript's own ground rather than a picture over it, so it sits under the scroll
/// view, is opaque, holds perfectly still and is drawn once for a size. The sky it draws is the
/// window's, seen through this pane, so two panes side by side show one sky rather than the same
/// stars twice. Under a theme with no scenery it is hidden and the pane keeps the ground it
/// always had.
@MainActor
final class SkyView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: MacTheme.Chrome.didRepaint, object: nil)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        needsDisplay = true
    }

    @objc private func refresh() {
        isHidden = scenery == nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let palette = sceneryPalette, let scenery = palette.scenery,
            let context = NSGraphicsContext.current?.cgContext
        else { return }
        let sky = window?.contentView.map { convert($0.bounds, from: $0) } ?? bounds
        SceneryPainter.drawSky(scenery, canvas: palette.canvas, in: context, sky: sky)
    }

    /// Lays the sky under everything a pane holds.
    func install(under host: NSView) {
        host.addSubview(self, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }
}

/// The two suns of a theme whose day has them, standing on the lower edge of the toolbar.
///
/// The toolbar is glass and takes no paint, so they are drawn in the content beneath it, in the
/// band the toolbar covers, over whatever scrolls through that band: a sun there is whole whatever
/// the transcript is doing, where one behind the rows would be seen in slivers. The title holds
/// the bar's leading end and the buttons its trailing one, so the pair stands between them,
/// counted in from the trailing side.
@MainActor
final class HorizonSunsView: NSView {
    /// How far in from the bar's trailing edge the pair's own leading edge stands, which clears
    /// the buttons packed there.
    private static let trailingClearance: CGFloat = 470
    /// The least the pair keeps to its leading side, so a narrow window's title still has its
    /// first words to itself.
    private static let leadingClearance: CGFloat = 150

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: MacTheme.Chrome.didRepaint, object: nil)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private var suns: TwinSuns? {
        guard case .suns(let suns) = scenery?.sky else { return nil }
        return suns
    }

    @objc private func refresh() {
        isHidden = suns == nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let suns, let context = NSGraphicsContext.current?.cgContext else { return }
        let leading = max(
            bounds.maxX - Self.trailingClearance, bounds.minX + Self.leadingClearance)
        SceneryPainter.drawSuns(
            suns, in: context, horizon: bounds.maxY, leading: leading, width: bounds.width)
    }

    /// Stands the suns in the band of `host` the toolbar covers.
    func install(over host: NSView) {
        host.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }
}

/// The scan lines over what the agent delegated: its card is work happening somewhere else,
/// projected here, in the colour the card's own edge wears. Drawn only under a theme that asks
/// for them, and never in daylight.
@MainActor
final class ScanLinesView: NSView {
    private let slot: KeyPath<Palette, String> & Sendable

    init(slot: KeyPath<Palette, String> & Sendable, cornerRadius: CGFloat) {
        self.slot = slot
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        isHidden = (scenery?.scanLines ?? 0) <= 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        isHidden = (scenery?.scanLines ?? 0) <= 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let palette = sceneryPalette, let scenery = palette.scenery,
            let context = NSGraphicsContext.current?.cgContext
        else { return }
        SceneryPainter.drawScanLines(
            tone: SceneryPainter.color(palette[keyPath: slot]), share: scenery.scanLines,
            in: context, rect: bounds)
    }

    /// Lays the lines over a card's ground and under everything it says.
    static func install(
        in card: NSView, slot: KeyPath<Palette, String> & Sendable, cornerRadius: CGFloat
    ) {
        let lines = ScanLinesView(slot: slot, cornerRadius: cornerRadius)
        card.addSubview(lines, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            lines.topAnchor.constraint(equalTo: card.topAnchor),
            lines.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            lines.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            lines.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
    }
}

/// The edge of the box being typed in, which strikes across from the leading side when the box
/// takes the keyboard in the window that has it, and withdraws when either lets go. It is the
/// one motion scenery has, and it is a transition, never a loop.
@MainActor
final class StrikeLineView: NSView {
    private let line = CAGradientLayer()
    private var focused = false
    private var struck = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        line.startPoint = CGPoint(x: 0, y: 0.5)
        line.endPoint = CGPoint(x: 1, y: 0.5)
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.shadowOffset = .zero
        line.transform = CATransform3DMakeScale(0.0001, 1, 1)
        layer?.addSublayer(line)
        NotificationCenter.default.addObserver(
            self, selector: #selector(wear), name: MacTheme.Chrome.didRepaint, object: nil)
        wear()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        wear()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        center.addObserver(
            self, selector: #selector(keyChanged), name: NSWindow.didBecomeKeyNotification,
            object: window)
        center.addObserver(
            self, selector: #selector(keyChanged), name: NSWindow.didResignKeyNotification,
            object: window)
        settle(animated: false)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.bounds = CGRect(origin: .zero, size: bounds.size)
        line.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
    }

    @objc private func wear() {
        guard let scenery else {
            line.isHidden = true
            return
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = MacTheme.Color.accent.usingColorSpace(.sRGB) ?? MacTheme.Color.accent
            let lit = scenery.bladeGlow > 0
            let core = lit ? accent.blended(withFraction: 0.55, of: .white) ?? accent : accent
            line.colors = [core.cgColor, accent.cgColor]
            line.shadowColor = accent.cgColor
            line.shadowRadius = CGFloat(scenery.bladeGlow) * 0.7
            line.shadowOpacity = lit ? 0.9 : 0
        }
        line.isHidden = false
    }

    @objc private func keyChanged() {
        settle(animated: true)
    }

    /// Told when the box takes or gives up the keyboard.
    func set(focused: Bool) {
        self.focused = focused
        settle(animated: true)
    }

    private func settle(animated: Bool) {
        let wanted = focused && window?.isKeyWindow == true
        guard wanted != struck else { return }
        struck = wanted
        let moves = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(moves ? 0.42 : 0)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1))
        CATransaction.setDisableActions(!moves)
        line.transform = CATransform3DMakeScale(wanted ? 1 : 0.0001, 1, 1)
        CATransaction.commit()
    }

    /// Lays the line along the top edge of the box's card, inside its corners.
    func install(on card: NSView, inset: CGFloat) {
        card.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: card.topAnchor),
            heightAnchor.constraint(equalToConstant: 1.5),
            leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
        ])
    }
}
