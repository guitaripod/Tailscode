import AppKit
import TailscodeCore

/// One button, chip or surface of the card the pointer can land on.
struct CardTarget: Equatable {
    enum Kind: Equatable {
        case open
        case replay
        case rows
        case zone(NeuralZone)
    }

    let kind: Kind
    var rect: CGRect
}

/// What the card says at one instant, laid out: where each piece goes, so a draw is a walk down a
/// list and the pointer's hit test reads the same rectangles.
struct CardLayout {
    var headline: [(text: NSAttributedString, origin: CGPoint)] = []
    var targets: [CardTarget] = []
    var chipRects: [(chip: NeuralBrainCard.ZoneChip, rect: CGRect)] = []
    var thirdLine: CGRect = .zero
    var textLeft: CGFloat = 0
    var textRight: CGFloat = 0
    var thirdBaselineY: CGFloat = 0
    var headlineCenterY: CGFloat = 0
    var clauseCenterY: CGFloat = 0
    var headlineRight: CGFloat = 0
    var showsThird = true
    var chipsTop: CGFloat = 0
    var wordmark = NSAttributedString()
    var wordmarkSize = CGSize.zero
    var signature = ""
}

@MainActor
final class BrainCardView: NSView {
    struct Content {
        var card: NeuralBrainCard
        var showsRows: Bool
        var isReplaying: Bool
        var canReplay: Bool
        var inks: BrainInks
        var density: ChatDensity
        var width: Double
        var geometry: NeuralStageMetrics.Card
        var face: NeuralFace
        var reduceMotion: Bool
    }

    /// What a move does to the card while it opens: the surface and the words fade, the words slide.
    struct Presentation: Equatable {
        var surfaceAlpha = 1.0
        var textAlpha = 1.0
        var textOffsetX = 0.0
        var edgeX: Double?
        var edgeAlpha = 1.0
        static let rest = Presentation()
    }

    private(set) var content: Content?
    var layout = CardLayout()
    var hovered = false
    private(set) var focused = false
    var wordmarkDrawn = false
    var hoverTarget: CardTarget.Kind?
    var pressed: CardTarget.Kind?
    private var pressesCard = false
    var presentation = Presentation.rest {
        didSet { if presentation != oldValue { applyPresentation() } }
    }
    private let edgeLayer = CALayer()

    var onOpen: (() -> Void)?
    var onReplay: (() -> Void)?
    var onRows: (() -> Void)?
    var onZone: ((NeuralZone) -> Void)?
    var onHover: ((Bool) -> Void)?

    var liveCard: NeuralLiveCard?
    var retainedLive: NeuralLiveCard?
    var settleClock = NeuralCardSettleClock()
    private var settleTimerClock: BrainClock?
    private var slideClock: BrainClock?
    private var lastOutput = ""
    var outputArrivedAt: Double = -10
    var quoteArrivals: [String: Date] = [:]
    var lastActivity = Date()
    private var lastModelRevision = -1
    private var tracking: NSTrackingArea?
    var elements: [NSAccessibilityElement] = []

    static let edgeWidth: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        edgeLayer.anchorPoint = .zero
        layer?.addSublayer(edgeLayer)
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let content else { return nil }
        let local = convert(point, from: superview)
        let card = NSRect(x: 0, y: 0, width: bounds.width, height: content.geometry.height)
        return card.contains(local) && presentation.surfaceAlpha > 0.05 ? self : nil
    }


    /// Brings the card to what the row says now. Cheap when nothing it draws has changed.
    func show(_ next: Content, revision: Int) {
        let words = signature(of: next)
        let changed = content == nil || words != layout.signature || revision != lastModelRevision
        let wasRunning = liveCard != nil
        content = next
        lastModelRevision = revision
        let running = next.card.live != nil
        liveCard = next.card.live
        if let held = next.card.live { retainedLive = held }
        let now = CACurrentMediaTime()
        if settleClock.observe(running: running, now: now), !next.reduceMotion {
            startSettle()
        }
        if running {
            noteActivity(next.card.live)
            BrainLiveTick.shared.register(self)
        } else {
            BrainLiveTick.shared.unregister(self)
        }
        if wasRunning != running { slideClock?.stop() }
        if changed || layout.signature != words { layout = buildLayout(next) }
        updateEdge()
        needsDisplay = true
        invalidateAccessibility()
    }

    func signature(of content: Content) -> String {
        let card = content.card
        let live = card.live.map { "\($0.stepCount)|\($0.saidCount)|\($0.flight?.stepID ?? "")|\($0.verdict)" } ?? ""
        return "\(content.width)|\(content.density)|\(content.showsRows)|\(content.isReplaying)|\(content.canReplay)|"
            + card.headline.pieces.map(\.text).joined(separator: "|")
            + "#" + card.chips.map { "\($0.zone)\($0.count)\($0.tone)" }.joined(separator: ",")
            + "#" + card.digest + "#" + (card.quote.map { $0.speaker + $0.words } ?? "") + "#" + live
            + "#\(content.inks.palette.name)\(content.inks.isDark)"
    }

    private func noteActivity(_ live: NeuralLiveCard?) {
        guard let live else { return }
        if let quote = live.quote, quoteArrivals[quote.stepID] == nil {
            quoteArrivals[quote.stepID] = Date()
        }
        let marker = "\(live.stepCount)|\(live.flight?.stepID ?? "")|\(live.flight?.lastLine?.text ?? "")"
        if marker != lastActivityMarker {
            lastActivityMarker = marker
            lastActivity = Date()
        }
        let output = live.flight?.lastLine?.text ?? ""
        if output != lastOutput {
            lastOutput = output
            if !output.isEmpty, !(content?.reduceMotion ?? true) {
                outputArrivedAt = CACurrentMediaTime()
                startSlide()
            }
        }
    }

    private var lastActivityMarker = ""


    /// Whether anybody can see this card: its window is on screen and it is not scrolled away.
    var isSeen: Bool { DisplayGate.allows(self) && !visibleRect.isEmpty }

    /// One second of a live card: the counts and the silence move without anything arriving.
    func liveSecondPassed() {
        guard liveCard != nil, isSeen else { return }
        needsDisplay = true
    }

    private func startSettle() {
        settleTimerClock?.stop()
        let clock = BrainClock(view: self) { [weak self] _ in
            guard let self else { return }
            self.needsDisplay = true
            if !self.settleClock.isSettling(now: CACurrentMediaTime()) {
                self.settleTimerClock?.stop()
                self.needsDisplay = true
                self.updateEdge()
            }
        }
        settleTimerClock = clock
        clock.run()
    }

    private func startSlide() {
        if slideClock == nil {
            slideClock = BrainClock(view: self) { [weak self] _ in
                guard let self else { return }
                self.needsDisplay = true
                if CACurrentMediaTime() - self.outputArrivedAt > NeuralLiveCard.outputSlide {
                    self.slideClock?.stop()
                }
            }
        }
        slideClock?.run()
    }

    var isSettling: Bool { settleClock.isSettling(now: CACurrentMediaTime()) }
    var settleProgress: Double? {
        settleClock.isSettling(now: CACurrentMediaTime())
            ? settleClock.settle(now: CACurrentMediaTime(), reduceMotion: content?.reduceMotion ?? false).progress
            : nil
    }

    /// Runs the settle at once, for the harness.
    func forceSettleStart() {
        settleClock.observe(running: true, now: CACurrentMediaTime())
        settleClock.observe(running: false, now: CACurrentMediaTime())
        startSettle()
    }

    @objc private func motionChanged() { updateEdge() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            settleTimerClock?.stop()
            slideClock?.stop()
            BrainLiveTick.shared.unregister(self)
        } else if liveCard != nil {
            BrainLiveTick.shared.register(self)
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layout.signature = ""
        needsDisplay = true
        updateEdge()
    }


    private func edgeColor() -> NSColor {
        guard let content else { return .clear }
        return content.inks.page(content.card.edgeTone, face: content.face)
    }

    private func updateEdge() {
        guard let content else { return }
        let height = CGFloat(content.geometry.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            edgeLayer.backgroundColor = edgeColor().cgColor
        }
        edgeLayer.bounds = CGRect(x: 0, y: 0, width: Self.edgeWidth, height: height)
        edgeLayer.cornerRadius = 0
        applyPresentation()
        let pulses =
            liveCard?.isAnimated(reduceMotion: content.reduceMotion || !ActivityPulse.motionAllowed)
            == true && !isSettling
        if pulses, let motion = liveCard?.motion {
            BrainMotion.breathe(edgeLayer, motion)
        } else {
            BrainMotion.breathe(edgeLayer, .still)
        }
    }

    private func applyPresentation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let x = presentation.edgeX ?? 0
        edgeLayer.position = CGPoint(x: x, y: 0)
        edgeLayer.isHidden = presentation.edgeAlpha <= 0.01
        if edgeLayer.animation(forKey: "brain.breath") == nil {
            edgeLayer.opacity = Float(presentation.edgeAlpha)
        }
    }

    /// Everything the card draws that is not already in its words, for the picture of it at rest:
    /// the pointer, the focus, the size, the scale of type and the face the window wears.
    private var restKey: Int? {
        guard let content, presentation == .rest, content.card.live == nil, !isSettling else { return nil }
        var hasher = Hasher()
        hasher.combine(layout.signature)
        hasher.combine(bounds.size.width)
        hasher.combine(bounds.size.height)
        hasher.combine(hovered)
        hasher.combine(focused)
        hasher.combine(hoverTarget.map { "\($0)" })
        hasher.combine(pressed.map { "\($0)" })
        hasher.combine(pressesCard)
        hasher.combine(window?.backingScaleFactor ?? 2)
        hasher.combine(effectiveAppearance.name.rawValue)
        hasher.combine("\(content.card.edge)\(content.card.edgeTone)\(content.face)")
        for area in TypeArea.allCases { hasher.combine(MacTheme.UIScale.factor(for: area)) }
        return hasher.finalize()
    }

    /// A card at rest is drawn once for the state it is in and then put down from that picture.
    /// AppKit asks every view in the page to draw again whenever one row's frame changes, which a
    /// Megatron opening or closing does, and a card's words are most of what the page draws.
    override func draw(_ dirtyRect: NSRect) {
        guard let content, let cg = NSGraphicsContext.current?.cgContext else { return }
        if layout.signature != signature(of: content) { layout = buildLayout(content) }
        guard let key = restKey else {
            paint(dirtyRect)
            return
        }
        let id = ObjectIdentifier(self)
        let image = BrainCardPictures.shared.picture(for: id, key: key) ?? makeRestPicture(key: key, id: id)
        guard let image else {
            paint(dirtyRect)
            return
        }
        cg.saveGState()
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: bounds)
        cg.restoreGState()
    }

    private func makeRestPicture(key: Int, id: ObjectIdentifier) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let size = bounds.size
        guard size.width > 1, size.height > 1,
            let context = CGContext(
                data: nil, width: Int((size.width * scale).rounded(.up)),
                height: Int((size.height * scale).rounded(.up)), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance { paint(NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.current = previous
        guard let image = context.makeImage() else { return nil }
        BrainCardPictures.shared.keep(image, for: id, key: key)
        return image
    }

    isolated deinit {
        BrainCardPictures.shared.forget(ObjectIdentifier(self))
    }

    private func paint(_ dirtyRect: NSRect) {
        guard let content else { return }
        let inks = content.inks
        let metrics = content.geometry
        let card = content.card
        let surface = presentation.surfaceAlpha
        let textAlpha = presentation.textAlpha
        let offset = CGFloat(presentation.textOffsetX)
        let height = CGFloat(metrics.height)
        let width = bounds.width
        let rect = NSRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1)
        guard let cg = NSGraphicsContext.current?.cgContext else { return }

        let edgeTone = edgeColor()
        if surface > 0.003 {
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            inks.raised.withAlphaComponent(surface).setFill()
            path.fill()
            let hoverLine = hovered || focused
            let line = hoverLine ? edgeTone.blended(withFraction: 0.1, of: inks.rule) ?? edgeTone : inks.rule
            line.withAlphaComponent((hoverLine ? 1 : 0.9) * surface).setStroke()
            path.lineWidth = focused ? 2 : 1
            path.stroke()
            if card.edge == .stopped {
                cg.saveGState()
                path.addClip()
                edgeTone.withAlphaComponent(surface).setFill()
                var y: CGFloat = 0
                while y < height {
                    NSRect(x: 0, y: y, width: Self.edgeWidth, height: min(6, height - y)).fill()
                    y += 10
                }
                cg.restoreGState()
            }
        }
        guard textAlpha > 0.003 else { return }
        cg.saveGState()
        cg.setAlpha(CGFloat(textAlpha))
        cg.translateBy(x: offset, y: 0)
        drawText(content, cg: cg)
        cg.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true, event: event) }

    override func mouseExited(with event: NSEvent) {
        hoverTarget = nil
        setHovered(false, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(true, event: event)
    }

    var onLightsHover: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if let hit = target(at: point) {
            pressed = hit.kind
            pressesCard = false
        } else {
            pressed = nil
            pressesCard = true
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = target(at: point)
        let started = pressed
        let card = pressesCard
        pressed = nil
        pressesCard = false
        needsDisplay = true
        if let started, hit?.kind == started {
            switch started {
            case .replay: onReplay?()
            case .rows: onRows?()
            case .open: onOpen?()
            case .zone(let zone): onZone?(zone)
            }
        } else if card, hit == nil, bounds.contains(point) {
            onOpen?()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        focused = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76, 49: onOpen?()
        default: super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat(content?.geometry.height ?? 0)),
            xRadius: 12, yRadius: 12
        ).fill()
    }

    override var focusRingMaskBounds: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat(content?.geometry.height ?? 0))
    }

    override func accessibilityChildren() -> [Any]? { elements }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}

/// An accessibility button that presses what it stands for.
final class BrainPressElement: NSAccessibilityElement {
    nonisolated(unsafe) var onPress: (@MainActor () -> Void)?

    override func accessibilityPerformPress() -> Bool {
        let handler = onPress
        MainThread.call { handler?() }
        return true
    }
}
