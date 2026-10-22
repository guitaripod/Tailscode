import AppKit
import TailscodeCore

/// The mark a feature wears while it is in beta, as a control: resting the pointer on the capsule
/// opens the card behind it, the card stays while the pointer is on the capsule or on the card and
/// leaves when it is on neither, and a click, Space or Return opens it too for a trackpad and for a
/// screen reader. Every word is the catalog's.
///
/// A mark nobody has opened, or whose card has something newer than the version it was last opened
/// at, is announced once by a single pass of light across the capsule and then holds perfectly
/// still. The pass is read from absolute time off the display's own clock, at most once per process
/// per feature, and the clock comes off the moment the pass ends; a settled mark runs none.
@MainActor
final class BetaBadge: NSControl, NSPopoverDelegate {
    private static var announced: Set<BetaFeature> = []
    private static let sheenShare: CGFloat = 0.7
    private static let lingerBeforeClosing: TimeInterval = 0.35

    let feature: BetaFeature
    var preferredEdge: NSRectEdge = .minY
    private let reportLines: () -> [String]
    private let interactive: Bool
    private let label = NSTextField(labelWithString: "")
    private let symbol = NSImageView()
    private let sheen = CAGradientLayer()
    private var link: CADisplayLink?
    private var passStart: CFTimeInterval = 0
    private var hasCheckedFreshness = false
    private var popover: NSPopover?
    private var closing: DispatchWorkItem?
    private var pressed = false {
        didSet { alphaValue = pressed ? 0.55 : 1 }
    }

    init(feature: BetaFeature, reportLines: @escaping () -> [String], interactive: Bool = true) {
        self.feature = feature
        self.reportLines = reportLines
        self.interactive = interactive
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        symbol.imageScaling = .scaleNone
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [symbol, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
        ])
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.zPosition = 10
        sheen.isHidden = true
        layer?.addSublayer(sheen)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(interactive)
        setAccessibilityRole(.button)
        setAccessibilityLabel(feature.card.spoken)
        if interactive {
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                    owner: self))
        }
        paint()
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settle), name: BetaSeenStore.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(settle),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        link?.invalidate()
        closing?.cancel()
    }

    override var acceptsFirstResponder: Bool { interactive }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { interactive }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactive else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        if interactive { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        sheen.bounds = CGRect(x: 0, y: 0, width: bounds.width * Self.sheenShare, height: bounds.height)
        if !hasCheckedFreshness, isOnScreen { announceIfFresh() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hasCheckedFreshness = false
        guard window != nil else {
            endPass()
            close()
            return
        }
        needsLayout = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        endPass()
        close()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        hasCheckedFreshness = false
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func mouseEntered(with event: NSEvent) {
        closing?.cancel()
        show()
    }

    override func mouseExited(with event: NSEvent) {
        scheduleClose()
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive else { return super.mouseDragged(with: event) }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard interactive else { return super.mouseUp(with: event) }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { toggle() }
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else { return super.keyDown(with: event) }
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": toggle()
        case "\u{1b}" where popover != nil: close()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard interactive else { return false }
        toggle()
        return true
    }

    /// The card, opened the way a press opens it — the road `--open delegate-beta` takes so the
    /// popover can be dumped and checked without a pointer.
    func reveal() { _ = accessibilityPerformPress() }

    /// Whether a mark is announced by light: only a fresh one, only the first time this process
    /// draws it, and never where the reader asked for less motion.
    static func announces(_ freshness: BetaFreshness, already: Bool, reducedMotion: Bool) -> Bool {
        freshness.isFresh && !already && !reducedMotion
    }

    private static var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The footnote weight of the ramp, set bold and rounded: a badge is read in one glance.
    private static var font: NSFont {
        let base = MacTheme.Ramp.font(.panelFootnote)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let rounded = bold.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: bold.pointSize) }
        return rounded ?? bold
    }

    /// A mark worn by something that is not drawn yet — a strip waiting for a call — is not on
    /// screen, and light played for nobody would use up the one announcement it gets.
    private var isOnScreen: Bool {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, !bounds.isEmpty else {
            return false
        }
        return alphaValue > 0
    }

    @objc private func repaint() { paint() }

    private func paint() {
        let tint = MacTheme.Color.mark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.45).cgColor
            sheen.colors = [
                tint.withAlphaComponent(0).cgColor, tint.withAlphaComponent(0.4).cgColor,
                tint.withAlphaComponent(0).cgColor,
            ]
        }
        label.attributedStringValue = NSAttributedString(
            string: BetaWords.badge, attributes: [.font: Self.font, .kern: 1.1, .foregroundColor: tint])
        symbol.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        symbol.contentTintColor = tint
    }

    private func announceIfFresh() {
        hasCheckedFreshness = true
        guard interactive else { return }
        let freshness = BetaSeenStore.freshness(feature, current: BetaEnvironment.appVersion)
        guard
            Self.announces(
                freshness, already: Self.announced.contains(feature), reducedMotion: Self.reducedMotion)
        else { return }
        Self.announced.insert(feature)
        startPass()
    }

    private func startPass() {
        guard link == nil else { return }
        passStart = CACurrentMediaTime()
        sheen.isHidden = false
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.runAtActivityTempo()
        link.add(to: .main, forMode: .common)
        self.link = link
        place(progress: 0)
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = max(0, link.timestamp - passStart)
        guard let progress = BetaSheen.progress(elapsed: elapsed, reducedMotion: Self.reducedMotion) else {
            endPass()
            return
        }
        place(progress: progress)
    }

    private func place(progress: Double) {
        let width = sheen.bounds.width
        let travel = bounds.width + width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheen.position = CGPoint(x: -width / 2 + travel * CGFloat(progress), y: bounds.midY)
        CATransaction.commit()
    }

    private func endPass() {
        link?.invalidate()
        link = nil
        sheen.isHidden = true
    }

    @objc private func settle() {
        guard link != nil else { return }
        endPass()
    }

    private func toggle() {
        endPass()
        if popover == nil { show() } else { close() }
    }

    /// Opens the card for the feature, leading with what changed when the person last looked at an
    /// older version, and marks the card seen at this version so the mark settles.
    private func show() {
        guard interactive, popover == nil, window != nil else { return }
        endPass()
        let freshness = BetaSeenStore.freshness(feature, current: BetaEnvironment.appVersion)
        let card = BetaCardViewController(feature: feature, freshness: freshness, reportLines: reportLines)
        card.onHover = { [weak self] inside in
            if inside { self?.closing?.cancel() } else { self?.scheduleClose() }
        }
        card.onDone = { [weak self] in self?.close() }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self
        popover.ground(card)
        popover.show(relativeTo: bounds, of: self, preferredEdge: preferredEdge)
        self.popover = popover
        BetaSeenStore.markSeen(feature, at: BetaEnvironment.appVersion)
        AppLogger.ui.info("beta card opened feature=\(feature.rawValue) freshness=\(String(describing: freshness))")
    }

    private func scheduleClose() {
        closing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainThread.call { self?.close() }
        }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerBeforeClosing, execute: work)
    }

    private func close() {
        closing?.cancel()
        closing = nil
        popover?.close()
        popover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}
