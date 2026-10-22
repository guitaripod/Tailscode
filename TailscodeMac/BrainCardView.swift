import AppKit
import TailscodeCore

/// One button, chip or surface of the card the pointer can land on.
private struct CardTarget: Equatable {
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
private struct CardLayout {
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

/// The collapsed turn: a card whose picture is the head lit where the turn worked and whose words
/// are what the turn came to, drawn in one view.
///
/// Everything but the picture is drawn here, in one pass over a handful of strings, because a
/// conversation of three hundred turns must cost the few cards in view and not three hundred
/// stacks of labels; AppKit asks a view for its pixels only while it is on screen. The picture is a
/// layer tree of the row's (it is the one thing that travels when the card opens), the tone edge is
/// a layer of its own so the render server can pulse it, and the pointer's two small buttons and
/// zone chips are rectangles this view hit-tests itself.
///
/// A running turn's card keeps the settled card's size and says what is happening in the reader's
/// words: the verdict, the counts, and a NOW line. When the turn ends the card settles in one 400 ms
/// move that Core times (`NeuralCardSettle`); the view only reads it.
/// The pictures of cards at rest: the few that were drawn last, so that a page asking every card
/// to draw again finds them done. A picture is a card's width by its height at the screen's
/// scale, a megabyte or two, so what is held is bounded in bytes, and let go of when the app has
/// been away.
@MainActor
final class BrainCardPictures {
    static let shared = BrainCardPictures()
    static let budget = 48 * 1_048_576

    private var bytes = 0

    private var held: [ObjectIdentifier: (key: Int, image: CGImage)] = [:]
    private var order: [ObjectIdentifier] = []

    func picture(for id: ObjectIdentifier, key: Int) -> CGImage? {
        guard let entry = held[id], entry.key == key else { return nil }
        touch(id)
        return entry.image
    }

    func keep(_ image: CGImage, for id: ObjectIdentifier, key: Int) {
        if let old = held[id] { bytes -= Self.size(of: old.image) }
        held[id] = (key, image)
        bytes += Self.size(of: image)
        touch(id)
        while bytes > Self.budget, order.count > 1 {
            let oldest = order.removeFirst()
            if let gone = held.removeValue(forKey: oldest) { bytes -= Self.size(of: gone.image) }
        }
    }

    func forget(_ id: ObjectIdentifier) {
        if let gone = held.removeValue(forKey: id) { bytes -= Self.size(of: gone.image) }
        order.removeAll { $0 == id }
    }

    func dropAll() {
        held = [:]
        order = []
        bytes = 0
    }

    private static func size(of image: CGImage) -> Int { image.bytesPerRow * image.height }

    var count: Int { held.count }

    private func touch(_ id: ObjectIdentifier) {
        order.removeAll { $0 == id }
        order.append(id)
    }
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
    private var layout = CardLayout()
    private(set) var hovered = false
    private(set) var focused = false
    private(set) var wordmarkDrawn = false
    private var hoverTarget: CardTarget.Kind?
    private var pressed: CardTarget.Kind?
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

    private var liveCard: NeuralLiveCard?
    private var retainedLive: NeuralLiveCard?
    private var settleClock = NeuralCardSettleClock()
    private var settleTimerClock: BrainClock?
    private var slideClock: BrainClock?
    private var lastOutput = ""
    private var outputArrivedAt: Double = -10
    private var quoteArrivals: [String: Date] = [:]
    private var lastActivity = Date()
    private var lastModelRevision = -1
    private var tracking: NSTrackingArea?
    private var elements: [NSAccessibilityElement] = []

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

    private func signature(of content: Content) -> String {
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


    private func buildLayout(_ content: Content) -> CardLayout {
        var out = CardLayout()
        out.signature = signature(of: content)
        let metrics = content.geometry
        let narrow = metrics.layout == .narrow
        let compact = content.density == .compact
        let width = CGFloat(content.width)
        let textLeft = CGFloat(metrics.text.x)
        let textRight = width - 12
        out.textLeft = textLeft
        out.textRight = textRight
        let height = CGFloat(metrics.height)
        let buttonHeight: CGFloat = 24
        let inks = content.inks

        let replayTitle = content.isReplaying ? Localized.text("Stop") : NeuralReading.replayLabel
        let rowsTitle = NeuralReading.rowsLabel
        let controlFont = MacTheme.Ramp.font(.control)
        func buttonWidth(_ title: String, icon: Bool) -> CGFloat {
            let text = (title as NSString).size(withAttributes: [.font: controlFont]).width
            return ceil(text) + 20 + (icon ? 16 : 0)
        }
        let replayWidth = buttonWidth(replayTitle, icon: true)
        let isLive = content.card.live != nil
        let rowsWidth = buttonWidth(isLive ? Localized.text("Open") : rowsTitle, icon: false)
        let top: CGFloat = compact ? 6 : 8
        var buttonsLeft = textRight
        if !narrow {
            let rows = CGRect(x: textRight - rowsWidth, y: top, width: rowsWidth, height: buttonHeight)
            let replay = CGRect(x: rows.minX - 6 - replayWidth, y: top, width: replayWidth, height: buttonHeight)
            out.targets.append(CardTarget(kind: isLive ? .open : .rows, rect: rows))
            let showsReplay = content.canReplay || isLive
            if showsReplay { out.targets.append(CardTarget(kind: .replay, rect: replay)) }
            buttonsLeft = showsReplay ? replay.minX : rows.minX
        }
        out.headlineRight = narrow ? textRight : buttonsLeft - 10
        out.wordmark = NSAttributedString(
            string: NeuralReading.wordmark,
            attributes: MacTheme.Ramp.attributes(.sectionLabel, color: inks.textDim))
        let wordmarkSize = out.wordmark.size()
        out.wordmarkSize = CGSize(width: ceil(wordmarkSize.width), height: ceil(wordmarkSize.height))

        let centerY: CGFloat = compact ? 20 : 29
        out.headlineCenterY = centerY
        var chipsTop: CGFloat = compact ? 38 : 52
        let chipHeight: CGFloat = compact ? 22 : 24
        if narrow {
            let rows = compact ? (headline: 15.0, clause: 33.0, third: 0.0, buttons: 48.0)
                : (headline: 22.0, clause: 44.0, third: 66.0, buttons: 78.0)
            out.headlineCenterY = CGFloat(rows.headline)
            out.clauseCenterY = CGFloat(rows.clause)
            out.showsThird = !compact
            let buttonsTop = CGFloat(rows.buttons)
            let showsReplay = content.canReplay || isLive
            let rowsButton = CGRect(x: textLeft + replayWidth + 6, y: buttonsTop, width: rowsWidth, height: buttonHeight)
            let replay = CGRect(x: textLeft, y: buttonsTop, width: replayWidth, height: buttonHeight)
            out.targets.append(CardTarget(kind: isLive ? .open : .rows, rect: showsReplay ? rowsButton : replay))
            if showsReplay { out.targets.append(CardTarget(kind: .replay, rect: replay)) }
            chipsTop = CGFloat(rows.third) - 9
        }
        out.chipsTop = chipsTop

        let parts = content.card.fit(width: width)
        if !narrow, parts.contains(.zoneStrip) {
            let badge = MacTheme.Ramp.font(.badge)
            var cursor = textLeft
            for chip in content.card.chips {
                let label = chip.label.uppercased()
                let labelWidth = (label as NSString).size(withAttributes: [
                    .font: badge, .kern: 0.6,
                ]).width
                let countWidth = ("\(chip.count)" as NSString).size(withAttributes: [.font: badge]).width
                let chipWidth = ceil(10 + 14 + labelWidth + 6 + countWidth + 10)
                guard cursor + chipWidth <= textRight else { break }
                let rect = CGRect(x: cursor, y: chipsTop, width: chipWidth, height: chipHeight)
                out.chipRects.append((chip, rect))
                out.targets.append(CardTarget(kind: .zone(chip.zone), rect: rect))
                cursor += chipWidth + 4
            }
        }
        let thirdTop = narrow ? (compact ? out.clauseCenterY - 9 : chipsTop) : chipsTop + chipHeight + (compact ? 4 : 9)
        out.thirdBaselineY = thirdTop
        out.thirdLine = CGRect(
            x: textLeft, y: thirdTop, width: max(0, textRight - textLeft), height: 18)
        return out
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

    private func drawText(_ content: Content, cg: CGContext) {
        wordmarkDrawn = false
        let inks = content.inks
        let card = content.card
        let narrow = content.geometry.layout == .narrow
        let compact = content.density == .compact
        let now = Date()
        let clock = CACurrentMediaTime()
        let settle = settleClock.settle(now: clock, reduceMotion: content.reduceMotion)
        let settling = settleClock.isSettling(now: clock)
        let live = card.live
        let textLeft = layout.textLeft
        let textRight = layout.textRight

        let showLive = live != nil || settling
        if showLive, let live = live ?? retainedLive {
            let alpha = settling ? settle.liveHeadlineAlpha : 1
            let lift = settling ? CGFloat(settle.liveHeadlineOffsetY) : 0
            if alpha > 0.003 {
                cg.saveGState()
                cg.setAlpha(CGFloat(alpha))
                drawLiveHeadline(live, content: content, lift: lift, now: now)
                cg.restoreGState()
            }
        }
        if !showLive || settling {
            let alpha = settling ? settle.settledHeadlineAlpha : 1
            let rise = settling ? CGFloat(settle.settledHeadlineOffsetY) : 0
            if alpha > 0.003 {
                cg.saveGState()
                cg.setAlpha(CGFloat(alpha))
                drawSettledHeadline(content, rise: rise)
                cg.restoreGState()
            }
        }
        for target in layout.targets {
            switch target.kind {
            case .replay:
                drawButton(
                    target, title: content.isReplaying ? Localized.text("Stop") : NeuralReading.replayLabel,
                    icon: content.isReplaying ? "stop.fill" : "play.fill", on: false, inks: inks,
                    enabled: content.canReplay)
            case .rows:
                drawButton(target, title: NeuralReading.rowsLabel, icon: nil, on: content.showsRows, inks: inks)
            case .open:
                drawButton(target, title: Localized.text("Open"), icon: nil, on: false, inks: inks)
            case .zone: break
            }
        }
        for entry in layout.chipRects {
            drawChip(entry.chip, rect: entry.rect, inks: inks, hot: hoverTarget == .zone(entry.chip.zone), face: content.face)
        }
        let parts = card.fit(width: CGFloat(content.width))
        if narrow, !parts.contains(.digest) { return }
        let third = layout.thirdLine
        guard third.width > 20 else { return }
        if narrow, compact, live == nil, !settling { return }
        if let live = live ?? (settling ? retainedLive : nil) {
            let nowAlpha = settling ? settle.nowLineAlpha : 1
            if nowAlpha > 0.003 {
                cg.saveGState()
                cg.setAlpha(CGFloat(nowAlpha))
                drawNowLine(live, content: content, rect: third, now: now, clock: clock)
                cg.restoreGState()
            }
            if settling, settle.firstWordsAlpha > 0.003 {
                cg.saveGState()
                cg.setAlpha(CGFloat(settle.firstWordsAlpha))
                drawFirstWords(card, content: content, rect: third)
                cg.restoreGState()
            }
        } else if !(narrow && compact) {
            drawFirstWords(card, content: content, rect: third)
        }
    }

    private func headlineFonts(_ content: Content) -> (number: NSFont, unit: NSFont, duration: NSFont) {
        (
            MacTheme.Ramp.font(.metricLarge), MacTheme.Ramp.font(.panelLabel),
            MacTheme.Ramp.font(.rowStamp)
        )
    }

    private func drawSettledHeadline(_ content: Content, rise: CGFloat) {
        let card = content.card
        let inks = content.inks
        let fonts = headlineFonts(content)
        let numberText = String(card.headline.number)
        let countText = card.headline.count
        let unitText =
            countText.hasPrefix(numberText)
            ? countText.dropFirst(numberText.count).trimmingCharacters(in: .whitespaces) : ""
        var x = layout.textLeft
        var baseline = layout.headlineCenterY + rise
        func draw(_ text: String, font: NSFont, color: NSColor, kern: CGFloat = 0, gap: CGFloat = 8) {
            guard !text.isEmpty, x < layout.headlineRight - 24 else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
            let size = (text as NSString).size(withAttributes: attributes)
            let y = baseline - size.height / 2
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
            x += ceil(size.width) + gap
        }
        draw(
            countText.hasPrefix(numberText) ? numberText : countText, font: fonts.number,
            color: inks.text, gap: 6)
        draw(unitText, font: fonts.unit, color: inks.textDim)
        if let duration = card.headline.piece(.duration) {
            draw(duration.text, font: fonts.duration, color: inks.textDim)
        }
        drawWordmark(lineEnd: x, baseline: baseline, width: content.width)
        if content.geometry.layout == .narrow {
            x = layout.textLeft
            baseline = layout.clauseCenterY + rise
        }
        if let tally = card.headline.piece(.tally) {
            let parts = tally.text.split(separator: " ", maxSplits: 1).map(String.init)
            let diff = MacTheme.Ramp.font(.diff)
            draw(parts.first ?? "", font: diff, color: inks.page(.live, face: content.face), gap: 4)
            if parts.count > 1 { draw(parts[1], font: diff, color: NSColor(hex: inks.palette.danger) ?? .systemRed) }
        }
        for kind in [NeuralBrainCard.Piece.Kind.failure, .state] {
            guard let piece = card.headline.piece(kind) else { continue }
            let tone = piece.tone.map { inks.page($0, face: content.face) } ?? inks.textDim
            drawClause(piece.text, kind: kind, tone: tone, x: &x, baseline: baseline, inks: inks)
        }
    }

    private func drawClause(
        _ text: String, kind: NeuralBrainCard.Piece.Kind, tone: NSColor, x: inout CGFloat,
        baseline: CGFloat, inks: BrainInks
    ) {
        let font = MacTheme.Ramp.font(.control)
        var glyph = ""
        if kind == .failure, text.lowercased().contains("fixed") || text.lowercased().contains("passed") {
            glyph = "↻ "
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tone]
        let string = glyph + text
        let size = (string as NSString).size(withAttributes: attributes)
        let room = layout.headlineRight - x
        guard room > 40 else { return }
        let drawn = size.width > room ? truncated(string, attributes: attributes, width: room) : string
        (drawn as NSString).draw(at: CGPoint(x: x, y: baseline - size.height / 2), withAttributes: attributes)
        x += min(size.width, room) + 8
    }

    private func truncated(_ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) -> String {
        var characters = Array(text)
        while !characters.isEmpty {
            let candidate = String(characters) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width { return candidate }
            characters.removeLast()
        }
        return "…"
    }


    private func drawLiveHeadline(_ live: NeuralLiveCard, content: Content, lift: CGFloat, now: Date) {
        let inks = content.inks
        let compact = content.density == .compact
        let reading = live.reading(now: now, lastActivity: lastActivity)
        let tone = inks.page(reading.tone, face: content.face)
        let wordFont = MacTheme.Ramp.font(.cardTitle)
        let sized = NSFont(descriptor: wordFont.fontDescriptor, size: compact ? 14 : 16) ?? wordFont
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let baseline = layout.headlineCenterY + lift
        var x = layout.textLeft
        let glyphSize: CGFloat = compact ? 12 : 14
        drawLiveGlyph(reading.glyph, at: CGPoint(x: x + glyphSize / 2, y: baseline), size: glyphSize, tone: tone)
        x += glyphSize + 8
        let wordColor: NSColor = tone
        let word = reading.word
        let wordAttributes: [NSAttributedString.Key: Any] = [.font: sized, .foregroundColor: wordColor]
        let narrow = content.geometry.layout == .narrow
        let wordSize = (word as NSString).size(withAttributes: wordAttributes)
        (word as NSString).draw(
            at: CGPoint(x: x, y: baseline - wordSize.height / 2), withAttributes: wordAttributes)
        x += ceil(wordSize.width) + 12
        var lineEnd = x
        defer { drawWordmark(lineEnd: lineEnd, baseline: baseline, width: content.width) }
        let counts = reading.counts
        let countAttributes: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: inks.textDim]
        var countsX = x
        var countsY = baseline
        if narrow {
            if compact { return }
            countsX = layout.textLeft
            countsY = layout.clauseCenterY + lift
        }
        let room = layout.headlineRight - countsX
        if room > 60 {
            let drawn = (counts as NSString).size(withAttributes: countAttributes).width > room
                ? truncated(counts, attributes: countAttributes, width: room) : counts
            let size = (drawn as NSString).size(withAttributes: countAttributes)
            (drawn as NSString).draw(
                at: CGPoint(x: countsX, y: countsY - size.height / 2), withAttributes: countAttributes)
            if !narrow { lineEnd = countsX + ceil(size.width) + 8 }
        }
    }

    /// Megatron's name at the right end of the headline's line, when Core's rule says the headline
    /// leaves it room. It is part of the card's one pass, in the chips' own label voice.
    private func drawWordmark(lineEnd: CGFloat, baseline: CGFloat, width: Double) {
        guard NeuralStageMetrics.cardShowsWordmark(
            width: width, headlineEnd: Double(lineEnd), headlineRight: Double(layout.headlineRight),
            wordmarkWidth: Double(layout.wordmarkSize.width))
        else { return }
        let size = layout.wordmarkSize
        wordmarkDrawn = true
        layout.wordmark.draw(
            at: CGPoint(x: layout.headlineRight - size.width, y: baseline - size.height / 2))
    }

    private func drawLiveGlyph(_ glyph: NeuralLiveCard.Glyph, at center: CGPoint, size: CGFloat, tone: NSColor) {
        tone.setStroke()
        tone.setFill()
        switch glyph {
        case .pulse:
            let path = NSBezierPath(ovalIn: NSRect(x: center.x - size * 0.3, y: center.y - size * 0.3, width: size * 0.6, height: size * 0.6))
            path.fill()
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            ring.lineWidth = 1.2
            ring.stroke()
        case .pauseBars:
            NSBezierPath(roundedRect: NSRect(x: center.x - size * 0.32, y: center.y - size * 0.4, width: size * 0.22, height: size * 0.8), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: center.x + size * 0.1, y: center.y - size * 0.4, width: size * 0.22, height: size * 0.8), xRadius: 1, yRadius: 1).fill()
        case .dashedClock:
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
            ring.lineWidth = 1.3
            ring.setLineDash([2.2, 2], count: 2, phase: 0)
            ring.stroke()
            let hands = NSBezierPath()
            hands.move(to: center)
            hands.line(to: CGPoint(x: center.x, y: center.y - size * 0.3))
            hands.move(to: center)
            hands.line(to: CGPoint(x: center.x + size * 0.22, y: center.y))
            hands.lineWidth = 1.2
            hands.stroke()
        case .triangle:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: center.x, y: center.y - size * 0.5))
            path.line(to: CGPoint(x: center.x + size * 0.5, y: center.y + size * 0.42))
            path.line(to: CGPoint(x: center.x - size * 0.5, y: center.y + size * 0.42))
            path.close()
            path.lineWidth = 1.4
            path.lineJoinStyle = .round
            path.stroke()
        }
    }


    private func drawNowLine(_ live: NeuralLiveCard, content: Content, rect: CGRect, now: Date, clock: Double) {
        let inks = content.inks
        let compact = content.density == .compact
        let line = live.line(
            now: now, lastActivity: lastActivity,
            quoteArrivedAt: live.quote.flatMap { quoteArrivals[$0.stepID] }, compact: compact)
        let centerY = rect.midY
        if line.kind == .quote, let quote = line.quote {
            drawQuote(
                speaker: quote.speaker, words: { quote.line(fittingChars: $0) }, rect: rect,
                inks: inks, centerY: centerY)
            return
        }
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let argFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: inks.text]
        var x = rect.minX
        let titleSize = (line.title as NSString).size(withAttributes: titleAttributes)
        var trailingText = ""
        var trailingColor = inks.textDim
        var slide: CGFloat = 0
        var trailingAlpha: CGFloat = 1
        switch line.trailing {
        case .output(let text, let tone):
            trailingText = text
            trailingColor = tone == .quiet ? inks.textDim : inks.page(.attention, face: content.face)
            let elapsed = clock - outputArrivedAt
            if elapsed < NeuralLiveCard.outputSlide {
                let t = NeuralTransition.easeOutCubic(elapsed / NeuralLiveCard.outputSlide)
                slide = CGFloat(NeuralLiveCard.outputSlideDistance * (1 - t))
                trailingAlpha = CGFloat(t)
            }
        case .silence(let text):
            trailingText = text
            trailingColor = inks.page(.attention, face: content.face)
        case .none:
            break
        }
        let trailingAttributes: [NSAttributedString.Key: Any] = [.font: argFont, .foregroundColor: trailingColor.withAlphaComponent(trailingAlpha)]
        let maxTrailing = rect.width * 0.42
        var trailingWidth: CGFloat = 0
        if !trailingText.isEmpty {
            let drawn = truncated(trailingText, attributes: trailingAttributes, width: maxTrailing)
            let size = (drawn as NSString).size(withAttributes: trailingAttributes)
            trailingWidth = size.width
            let fitted = size.width > maxTrailing ? truncated(drawn, attributes: trailingAttributes, width: maxTrailing) : drawn
            (fitted as NSString).draw(
                at: CGPoint(x: rect.maxX - size.width, y: centerY - size.height / 2 + slide),
                withAttributes: trailingAttributes)
        }
        (line.title as NSString).draw(
            at: CGPoint(x: x, y: centerY - titleSize.height / 2), withAttributes: titleAttributes)
        x += ceil(titleSize.width) + 8
        if let argument = line.argument {
            let attributes: [NSAttributedString.Key: Any] = [.font: argFont, .foregroundColor: inks.textDim]
            let room = rect.maxX - trailingWidth - 12 - x
            if room > 30 {
                let drawn = truncated(argument, attributes: attributes, width: room)
                let shown = (argument as NSString).size(withAttributes: attributes).width <= room ? argument : drawn
                let size = (shown as NSString).size(withAttributes: attributes)
                (shown as NSString).draw(
                    at: CGPoint(x: x, y: centerY - size.height / 2), withAttributes: attributes)
            }
        }
    }

    private func drawFirstWords(_ card: NeuralBrainCard, content: Content, rect: CGRect) {
        let inks = content.inks
        if let quote = card.quote {
            drawQuote(
                speaker: quote.speaker,
                words: { card.quoteLine(fittingChars: $0) ?? quote.words }, rect: rect, inks: inks,
                centerY: rect.midY)
            return
        }
        let font = MacTheme.Ramp.font(.panelDetail)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inks.textDim]
        let text = fitted(rect.width) { card.digest(fitting: $0) } measure: {
            ($0 as NSString).size(withAttributes: attributes).width
        }
        guard !text.isEmpty else { return }
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: rect.minX, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func fitted(_ width: CGFloat, make: (Int) -> String, measure: (String) -> CGFloat) -> String {
        var best = make(0)
        var characters = 24
        var last = ""
        while characters < 400 {
            let candidate = make(characters)
            if candidate == last { break }
            guard measure(candidate) <= width else { break }
            best = candidate
            last = candidate
            characters += 6
        }
        return best
    }

    private func drawQuote(
        speaker: String, words: (Int) -> String, rect: CGRect, inks: BrainInks, centerY: CGFloat
    ) {
        let accent = NSColor(hex: inks.palette.accent) ?? inks.text
        let mark = "\u{201C}"
        let markFont = NSFont.systemFont(ofSize: 15, weight: .bold)
        let markSize = (mark as NSString).size(withAttributes: [.font: markFont])
        (mark as NSString).draw(
            at: CGPoint(x: rect.minX, y: centerY - markSize.height / 2 + 2),
            withAttributes: [.font: markFont, .foregroundColor: accent])
        let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let nameAttributes: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: accent]
        let nameSize = (speaker as NSString).size(withAttributes: nameAttributes)
        let nameX = rect.minX + markSize.width + 4
        (speaker as NSString).draw(
            at: CGPoint(x: nameX, y: centerY - nameSize.height / 2), withAttributes: nameAttributes)
        let wordsFont = italic(MacTheme.Ramp.font(.panelDetail))
        let wordsAttributes: [NSAttributedString.Key: Any] = [.font: wordsFont, .foregroundColor: inks.text]
        let wordsX = nameX + ceil(nameSize.width) + 8
        let room = rect.maxX - wordsX
        guard room > 24 else { return }
        let prefix = speaker + ": "
        let text = fitted(room) { characters in
            let line = words(characters + prefix.count)
            return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
        } measure: { ($0 as NSString).size(withAttributes: wordsAttributes).width }
        let size = (text as NSString).size(withAttributes: wordsAttributes)
        (text as NSString).draw(
            at: CGPoint(x: wordsX, y: centerY - size.height / 2), withAttributes: wordsAttributes)
    }

    private func italic(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }


    private func drawButton(
        _ target: CardTarget, title: String, icon: String?, on: Bool, inks: BrainInks,
        enabled: Bool = true
    ) {
        let rect = target.rect.insetBy(dx: 0.5, dy: 0.5)
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        if !enabled { cg.setAlpha(0.45) }
        let isHot = hoverTarget == target.kind && enabled
        let isDown = pressed == target.kind
        let accent = NSColor(hex: inks.palette.accent) ?? inks.text
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        (isDown ? inks.rule : inks.canvas.blended(withFraction: 0.0, of: inks.raised) ?? inks.canvas).setFill()
        path.fill()
        let line = (isHot || on) ? accent : inks.rule
        line.setStroke()
        path.lineWidth = 1
        path.stroke()
        let font = MacTheme.Ramp.font(.control)
        let ink = (isHot || on) ? accent : inks.textDim
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = (title as NSString).size(withAttributes: attributes)
        var x = rect.minX + 10
        if let icon, let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold))
        {
            let tinted = image.tinted(ink)
            let imageSize = tinted.size
            tinted.draw(
                in: NSRect(x: x, y: rect.midY - imageSize.height / 2, width: imageSize.width, height: imageSize.height))
            x += imageSize.width + 5
        }
        (title as NSString).draw(
            at: CGPoint(x: x, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawChip(
        _ chip: NeuralBrainCard.ZoneChip, rect: CGRect, inks: BrainInks, hot: Bool, face: NeuralFace
    ) {
        let said = chip.zone == .say
        let tone: NSColor
        switch chip.tone {
        case .danger: tone = NSColor(hex: inks.palette.danger) ?? .systemRed
        case .attention: tone = NSColor(hex: inks.palette.warn) ?? .systemOrange
        default: tone = inks.page(chip.zone)
        }
        let accent = NSColor(hex: inks.palette.accent) ?? tone
        let outline = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: outline, xRadius: outline.height / 2, yRadius: outline.height / 2)
        inks.canvas.setFill()
        path.fill()
        let edge: NSColor = said ? accent : (hot ? tone : inks.rule)
        edge.withAlphaComponent(said || hot ? 0.9 : 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let glyphRadius: CGFloat = 5.5
        let shape = BrainShapes.path(chip.zone.shape, radius: glyphRadius)
        if let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            cg.translateBy(x: rect.minX + 10, y: rect.midY - glyphRadius)
            cg.addPath(shape)
            cg.setStrokeColor(tone.cgColor)
            cg.setLineWidth(1.3)
            cg.strokePath()
            cg.restoreGState()
        }
        let font = MacTheme.Ramp.font(.badge)
        let ink = said ? accent : inks.text
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: 0.6]
        let label = chip.label.uppercased()
        let labelSize = (label as NSString).size(withAttributes: labelAttributes)
        let x = rect.minX + 10 + 14
        (label as NSString).draw(at: CGPoint(x: x, y: rect.midY - labelSize.height / 2), withAttributes: labelAttributes)
        let countAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inks.text]
        let count = "\(chip.count)"
        let countSize = (count as NSString).size(withAttributes: countAttributes)
        (count as NSString).draw(
            at: CGPoint(x: x + ceil(labelSize.width) + 6, y: rect.midY - countSize.height / 2),
            withAttributes: countAttributes)
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

    private func target(at point: CGPoint) -> CardTarget? {
        layout.targets.last { $0.rect.contains(point) && ($0.kind != .replay || content?.canReplay == true) }
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true, event: event) }

    override func mouseExited(with event: NSEvent) {
        hoverTarget = nil
        setHovered(false, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(true, event: event)
    }

    private func setHovered(_ value: Bool, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = value ? target(at: point)?.kind : nil
        let changed = value != hovered || next != hoverTarget
        hovered = value
        hoverTarget = next
        guard changed else { return }
        if value != hovered || true { onHover?(value) }
        needsDisplay = true
        if value { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        refreshLightsHover()
    }

    var onLightsHover: ((Bool) -> Void)?

    private func refreshLightsHover() { onLightsHover?(hovered) }

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


    private func invalidateAccessibility() {
        guard let content else { return }
        elements = []
        func element(
            _ label: String, _ rect: CGRect, help: String? = nil, _ press: @escaping @MainActor () -> Void
        ) {
            let item = BrainPressElement()
            item.setAccessibilityRole(.button)
            item.setAccessibilityLabel(label)
            item.setAccessibilityHelp(help)
            item.setAccessibilityParent(self)
            item.setAccessibilityFrameInParentSpace(rect)
            item.onPress = press
            elements.append(item)
        }
        for target in layout.targets {
            switch target.kind {
            case .replay: element(NeuralReading.replayLabel, target.rect) { [weak self] in self?.onReplay?() }
            case .rows:
                element(
                    NeuralReading.rowsLabel, target.rect,
                    help: NeuralReading.rowsHelp(showingRows: content.showsRows)
                ) { [weak self] in self?.onRows?() }
            case .open: element(Localized.text("Open"), target.rect) { [weak self] in self?.onOpen?() }
            case .zone(let zone):
                element(zone.displayLabel, target.rect) { [weak self] in self?.onZone?(zone) }
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(NeuralReading.named(content.card.spoken))
    }

    override func accessibilityChildren() -> [Any]? { elements }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }

    /// What the harness reads: how many chips and buttons the layout holds and what it drew.
    var reading: (chips: Int, buttons: Int, headline: String, hasLive: Bool) {
        (
            layout.chipRects.count, layout.targets.filter { if case .zone = $0.kind { return false } else { return true } }.count,
            content?.card.headline.pieces.map(\.text).joined(separator: " ") ?? "", liveCard != nil
        )
    }

    var chipCenters: [(zone: NeuralZone, point: CGPoint)] {
        layout.chipRects.map { ($0.chip.zone, CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
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

extension NSImage {
    /// The template image filled with `color`.
    fileprivate func tinted(_ color: NSColor) -> NSImage {
        let copy = self.copy() as? NSImage ?? self
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}

/// The one second a live card ticks at while any of them is on screen: the counts and the silence
/// move without anything arriving. Settled cards register nothing, so a conversation of finished
/// turns owns no timer; the timer runs only while some live card is in a window somebody can see
/// (`DisplayGate`) and stops the moment none is, to start again when the app, a window or a scroll
/// brings one back.
@MainActor
final class BrainLiveTick {
    static let shared = BrainLiveTick()
    private let cards = NSHashTable<BrainCardView>.weakObjects()
    private var timer: Timer?
    private var observing = false

    var isRunning: Bool { timer != nil }
    var cardCount: Int { cards.allObjects.count }

    func register(_ card: BrainCardView) {
        cards.add(card)
        observe()
        reconsider()
    }

    func unregister(_ card: BrainCardView) {
        cards.remove(card)
        reconsider()
    }

    /// Starts the timer when a registered card can be seen, and stops it when none can.
    func reconsider() {
        let seen = cards.allObjects.contains { $0.isSeen }
        if seen, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainThread.call { self?.tick() }
            }
            timer?.tolerance = 0.1
        } else if !seen, timer != nil {
            timer?.invalidate()
            timer = nil
        }
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSView.boundsDidChangeNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainThread.call { self?.reconsider() }
            }
        }
    }

    private func tick() {
        let live = cards.allObjects
        guard live.contains(where: { $0.isSeen }) else {
            reconsider()
            return
        }
        for card in live { card.liveSecondPassed() }
    }
}
