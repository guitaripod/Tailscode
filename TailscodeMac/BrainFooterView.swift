import AppKit
import TailscodeCore

/// A small pill button drawn by hand: a word, an optional glyph, a hairline that takes the accent
/// when the pointer is on it. The card's Replay and Rows, the footer's buttons and the answer's
/// chips are all this, so every small button in an open brain reads as one family.
@MainActor
class BrainPillButton: NSView {
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityLabel(title)
        }
    }
    var symbol: String? {
        didSet {
            guard symbol != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var isDashed = false { didSet { if isDashed != oldValue { needsDisplay = true } } }
    var inks: BrainInks? { didSet { if inks != oldValue { needsDisplay = true } } }
    var onTap: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var role: TypeRole = .control { didSet { invalidateIntrinsicContentSize() } }
    var isMono = false
    var maximumWidth: CGFloat = 0
    private(set) var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }

    private var font: NSFont {
        isMono ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular) : MacTheme.Ramp.font(role)
    }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        var width = ceil(text) + 22 + (symbol == nil ? 0 : 15)
        if maximumWidth > 0 { width = min(width, maximumWidth) }
        return NSSize(width: width, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let inks else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let accent = NSColor(hex: inks.palette.accent) ?? inks.text
        (pressed ? inks.rule : inks.raised).setFill()
        path.fill()
        let lit = hovered || isOn
        (lit ? accent : inks.rule).setStroke()
        path.lineWidth = 1
        if isDashed { path.setLineDash([3, 2.4], count: 2, phase: 0) }
        path.stroke()
        let ink = lit ? accent : inks.textDim
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        var x = rect.minX + 10
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        {
            let size = image.size
            let tinted = NSImage(size: size, flipped: false) { frame in
                image.draw(in: frame)
                ink.set()
                frame.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            x += size.width + 5
        }
        let room = rect.maxX - 10 - x
        let size = (title as NSString).size(withAttributes: attributes)
        let shown = size.width > room ? Self.cut(title, attributes: attributes, width: room) : title
        (shown as NSString).draw(
            at: CGPoint(x: x, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    static func cut(_ text: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) -> String {
        var characters = Array(text)
        while !characters.isEmpty {
            let candidate = String(characters) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width { return candidate }
            characters.removeLast()
        }
        return "…"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        onHover?(true)
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        onHover?(false)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if inside { onTap?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onTap?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) {
            onTap?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// An answer word that a step carries literally: the path or command the answer quotes. Hovering it
/// lights the steps that touched it and dims the rest; pressing it holds the light.
@MainActor
final class BrainTokenChip: BrainPillButton {
    private(set) var token = ""
    var isHeld = false { didSet { isOn = isHeld } }

    convenience init(token: String, inks: BrainInks) {
        self.init(frame: .zero)
        self.token = token
        self.inks = inks
        title = token
        isMono = true
        isDashed = true
        maximumWidth = 280
        setAccessibilityLabel(Localized.text("Answer word %@", token))
    }
}

/// The paths and commands the answer quotes, as chips in the footer. Only a word some step
/// carries literally is offered, so the row never claims a link the transcript cannot show.
@MainActor
final class BrainChipStrip: NSView {
    private(set) var tokens: [String] = []
    private(set) var chips: [BrainTokenChip] = []
    private let caption = NSTextField(labelWithString: "")
    var onHover: ((String?) -> Void)?
    var onPress: ((String) -> Void)?
    static let limit = 6
    private var inks: BrainInks?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        caption.font = MacTheme.Ramp.font(.sectionLabel)
        caption.stringValue = Localized.text("In the answer").uppercased()
        addSubview(caption)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    func show(_ next: [String], inks: BrainInks, held: String?) {
        self.inks = inks
        caption.textColor = inks.textDim
        if next != tokens {
            tokens = next
            for chip in chips { chip.removeFromSuperview() }
            chips = next.prefix(Self.limit).map { token in
                let chip = BrainTokenChip(token: token, inks: inks)
                chip.onHover = { [weak self] entered in self?.onHover?(entered ? token : nil) }
                chip.onTap = { [weak self] in self?.onPress?(token) }
                addSubview(chip)
                return chip
            }
        }
        for chip in chips {
            chip.inks = inks
            chip.isHeld = chip.token == held
        }
        needsLayout = true
    }

    /// How wide the strip would like to be, caption and chips.
    var naturalWidth: CGFloat {
        guard !chips.isEmpty else { return 0 }
        caption.sizeToFit()
        return caption.frame.width + 8 + chips.reduce(0) { $0 + $1.intrinsicContentSize.width + 6 }
    }

    override func layout() {
        super.layout()
        caption.sizeToFit()
        guard !chips.isEmpty else {
            caption.isHidden = true
            return
        }
        caption.isHidden = false
        caption.frame.origin = CGPoint(x: 0, y: (bounds.height - caption.frame.height) / 2)
        var x = caption.frame.maxX + 8
        for chip in chips {
            let width = chip.intrinsicContentSize.width
            if x + width > bounds.width {
                chip.isHidden = true
                continue
            }
            chip.isHidden = false
            chip.frame = CGRect(x: x, y: (bounds.height - 24) / 2, width: width, height: 24)
            x += width + 6
        }
    }

    var visibleChips: Int { chips.filter { !$0.isHidden }.count }
}

/// A drawn slider for a replay: a track, what has played, the ticks of the failed steps and a knob.
/// Dragging it scrubs the brain through the turn and letting go leaves the playhead where it was;
/// the end of the track is the turn as it stands.
@MainActor
final class BrainScrubber: NSView {
    var fraction: Double = 1 {
        didSet {
            guard fraction != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(Int((fraction * 100).rounded()))
        }
    }
    var ticks: [(fraction: Double, failed: Bool)] = [] {
        didSet {
            guard ticks.count != oldValue.count
                || zip(ticks, oldValue).contains(where: { $0.fraction != $1.fraction || $0.failed != $1.failed })
            else { return }
            needsDisplay = true
        }
    }
    var onScrub: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var inks: BrainInks? { didSet { if inks != oldValue { needsDisplay = true } } }
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(NeuralReading.scrubLabel)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var track: NSRect {
        NSRect(x: 7, y: bounds.midY - 2, width: max(0, bounds.width - 14), height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let inks else { return }
        let rail = track
        inks.rule.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 2, yRadius: 2).fill()
        let accent = NSColor(hex: inks.palette.accent) ?? inks.text
        let played = NSRect(x: rail.minX, y: rail.minY, width: rail.width * CGFloat(fraction), height: rail.height)
        accent.setFill()
        NSBezierPath(roundedRect: played, xRadius: 2, yRadius: 2).fill()
        for tick in ticks {
            let x = rail.minX + rail.width * CGFloat(tick.fraction)
            let color = tick.failed ? (NSColor(hex: inks.palette.danger) ?? .systemRed) : inks.textDim.withAlphaComponent(0.5)
            color.setFill()
            let height: CGFloat = tick.failed ? 9 : 5
            NSRect(x: x - 0.5, y: rail.midY - height - 3, width: 1, height: height).fill()
        }
        let knob = NSRect(x: played.maxX - 6, y: bounds.midY - 6, width: 12, height: 12)
        accent.setFill()
        NSBezierPath(ovalIn: knob).fill()
        inks.canvas.setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        scrub(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        scrub(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        scrub(event)
        onEnd?()
    }

    private func scrub(_ event: NSEvent) {
        let rail = track
        guard rail.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let next = min(1, max(0, Double((point.x - rail.minX) / rail.width)))
        fraction = next
        onScrub?(next)
    }

    override func accessibilityPerformIncrement() -> Bool { step(by: 0.05) }
    override func accessibilityPerformDecrement() -> Bool { step(by: -0.05) }

    private func step(by delta: Double) -> Bool {
        let next = min(1, max(0, fraction + delta))
        fraction = next
        onScrub?(next)
        onEnd?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: _ = step(by: -0.05)
        case 124: _ = step(by: 0.05)
        default: super.keyDown(with: event)
        }
    }
}

/// The footer under an open brain: Replay, the scrubber with the turn's failed steps ticked on it,
/// the time, the answer's quoted words, and Rows, Share and Close. What it holds follows Core's
/// `footerParts` for the row's width: Close goes under 960 and, under 640, Replay is its icon and
/// the chips go.
@MainActor
final class BrainFooterView: NSView {
    private weak var host: BrainSurfaceHost?
    let replay = BrainPillButton()
    let scrubber = BrainScrubber()
    private let clock = NSTextField(labelWithString: "")
    let chips = BrainChipStrip()
    let rows = BrainPillButton()
    let share = BrainPillButton()
    let close = BrainPillButton()
    private var parts: [NeuralStageMetrics.FooterPart] = []
    var onReplay: (() -> Void)?
    var onScrub: ((Double) -> Void)?
    var onScrubEnd: (() -> Void)?
    var onShare: (() -> Void)?
    var onRows: (() -> Void)?
    var onClose: (() -> Void)?
    var onChipHover: ((String?) -> Void)?
    var onChipPress: ((String) -> Void)?

    init(host: BrainSurfaceHost) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        replay.symbol = "play.fill"
        replay.title = NeuralReading.replayLabel
        rows.title = NeuralReading.rowsLabel
        share.title = Localized.text("Share")
        share.symbol = "square.and.arrow.up"
        close.title = Localized.text("Close")
        replay.onTap = { [weak self] in self?.onReplay?() }
        rows.onTap = { [weak self] in self?.onRows?() }
        share.onTap = { [weak self] in self?.onShare?() }
        close.onTap = { [weak self] in self?.onClose?() }
        scrubber.onScrub = { [weak self] fraction in self?.onScrub?(fraction) }
        scrubber.onEnd = { [weak self] in self?.onScrubEnd?() }
        chips.onHover = { [weak self] token in self?.onChipHover?(token) }
        chips.onPress = { [weak self] token in self?.onChipPress?(token) }
        clock.font = MacTheme.Ramp.font(.rowStamp)
        clock.alignment = .right
        for view in [replay, scrubber, clock, chips, rows, share, close] as [NSView] { addSubview(view) }
        setAccessibilityRole(.group)
        setAccessibilityLabel(Localized.text("Replay and share"))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// Brings the footer to the model: the playhead, the clock, the quoted words.
    func sync(now: Double) {
        guard let host else { return }
        let model = host.model
        let inks = host.inks
        for button in [replay, rows, share, close] { button.inks = inks }
        scrubber.inks = inks
        let settled = model.turn.outcome != .running
        let playing = model.isReplaying
        replay.title = playing ? Localized.text("Stop") : NeuralReading.replayLabel
        replay.symbol = playing ? "stop.fill" : "play.fill"
        replay.setAccessibilityLabel(playing ? Localized.text("Stop the replay") : NeuralReading.replayLabel)
        replay.isHidden = !settled
        scrubber.isHidden = !settled
        share.isHidden = !settled
        scrubber.fraction = model.replayFraction(now: now) ?? 1
        let fires = model.timeline.fireTimes
        let total = max(model.timeline.duration, 0.001)
        if scrubber.ticks.count != fires.count {
            scrubber.ticks = zip(fires, model.steps).map { time, step in
                (min(1, max(0, time / total)), step.status == .failed && !step.recovered)
            }
        }
        let text: String
        if playing {
            text = model.replayTime(now: now).map { NeuralReading.duration($0) } ?? ""
        } else if settled {
            text = model.line.duration ?? NeuralReading.duration(model.timeline.duration)
        } else {
            text = ""
        }
        if clock.stringValue != text { clock.stringValue = text }
        clock.textColor = inks.textDim
        rows.isOn = host.isShowingRows
        rows.setAccessibilityHelp(NeuralReading.rowsHelp(showingRows: host.isShowingRows))
        rows.toolTip = NeuralReading.rowsHelp(showingRows: host.isShowingRows)
        chips.show(
            settled ? host.answerChips : [], inks: inks, held: model.provenanceToken)
        needsLayout = true
        setAccessibilityLabel(Localized.text("Replay and share"))
    }

    override func layout() {
        super.layout()
        guard let host else { return }
        parts = NeuralStageMetrics.footerParts(width: Double(bounds.width))
        let height = bounds.height
        let button: CGFloat = 26
        let top = (height - button) / 2
        var left: CGFloat = 0
        var right = bounds.width
        let has = { (kind: NeuralStageMetrics.FooterPart.Kind) in self.parts.first { $0.kind == kind } }
        let model = host.model
        let settled = model.turn.outcome != .running
        if let part = has(.replay), settled {
            replay.role = .control
            replay.title = part.isIcon ? "" : (model.isReplaying ? Localized.text("Stop") : NeuralReading.replayLabel)
            let width = part.isIcon ? button : replay.intrinsicContentSize.width
            replay.frame = CGRect(x: 0, y: top, width: width, height: button)
            left = width + 12
        }
        close.isHidden = has(.close) == nil
        if has(.close) != nil {
            let width = close.intrinsicContentSize.width
            close.frame = CGRect(x: right - width, y: top, width: width, height: button)
            right -= width + 6
        }
        if settled {
            let width = share.intrinsicContentSize.width
            share.frame = CGRect(x: right - width, y: top, width: width, height: button)
            right -= width + 6
        }
        let rowsWidth = rows.intrinsicContentSize.width
        rows.frame = CGRect(x: right - rowsWidth, y: top, width: rowsWidth, height: button)
        right -= rowsWidth + 12
        let showsChips = has(.answerChips) != nil && !chips.tokens.isEmpty
        chips.isHidden = !showsChips
        var chipsWidth: CGFloat = 0
        if showsChips {
            chipsWidth = min(chips.naturalWidth, max(0, (right - left) * 0.5))
            chips.frame = CGRect(x: right - chipsWidth, y: 0, width: chipsWidth, height: height)
            right -= chipsWidth + 12
        }
        clock.sizeToFit()
        let clockWidth = settled ? max(clock.frame.width, 58) : 0
        clock.isHidden = !settled
        if settled {
            clock.frame = CGRect(
                x: right - clockWidth, y: (height - clock.frame.height) / 2, width: clockWidth,
                height: clock.frame.height)
            right -= clockWidth + 10
        }
        scrubber.frame = CGRect(x: left, y: 0, width: max(0, right - left), height: height)
    }

    /// What the harness reads: which parts the footer shows.
    var shown: [NeuralStageMetrics.FooterPart.Kind] {
        var out: [NeuralStageMetrics.FooterPart.Kind] = []
        if !replay.isHidden { out.append(.replay) }
        if !scrubber.isHidden { out.append(.scrubber) }
        if !clock.isHidden { out.append(.time) }
        if !chips.isHidden { out.append(.answerChips) }
        if !rows.isHidden { out.append(.rows) }
        if !share.isHidden { out.append(.share) }
        if !close.isHidden { out.append(.close) }
        return out
    }

    var clockText: String { clock.stringValue }
    var replayIsIcon: Bool { replay.title.isEmpty }
}
