import AppKit
import ImageIO
import TailscodeCore
import UniformTypeIdentifiers

/// The two-part control at the words box's trailing edge: Enhance asks the filed helper for the
/// paragraph, the chevron opens the list of every model on the way that could write it.
@MainActor
final class StudioEnhanceControl: NSView {
    enum Mode: Equatable {
        case find
        case looking
        case ready(ImageGenHelper)
        case off(ImageGenHelper)
        case writing
        case disabled
    }

    var onEnhance: (() -> Void)?
    var onPicker: ((NSView) -> Void)?
    var state: Mode = .find {
        didSet {
            guard state != oldValue else { return }
            refresh()
        }
    }

    private var hovering: Region?
    private var tracking: NSTrackingArea?

    private enum Region { case main, picker }

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var title: String {
        switch state {
        case .find, .ready: return ImageGenWords.enhanceTitle
        case .looking: return ImageGenRewriteWords.lookingTitle
        case .off: return ImageGenWords.enhanceTitle + " · " + ImageGenWords.offMark
        case .writing: return ImageGenWords.enhancingTitle
        case .disabled: return ImageGenWords.enhanceTitle
        }
    }

    private func refresh() {
        switch state {
        case .ready(let helper): toolTip = ImageGenWords.enhanceHint(helper)
        case .find: toolTip = ImageGenWords.enhanceLookingHint
        case .off: toolTip = ImageGenWords.helperOffHint
        default: toolTip = nil
        }
        setAccessibilityLabel(title)
        alphaValue = state == .disabled ? 0.45 : 1
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private static let chevronWidth: CGFloat = 24

    override var intrinsicContentSize: NSSize {
        NSSize(width: 12 + 14 + 4 + StudioTheme.width(of: title, role: .control) + 6 + Self.chevronWidth, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        MacTheme.Color.onGlass.withAlphaComponent(0.12).setFill()
        shape.fill()
        if let hovering {
            let region = hovering == .main
                ? NSRect(x: 0, y: 0, width: bounds.width - Self.chevronWidth, height: bounds.height)
                : NSRect(x: bounds.width - Self.chevronWidth, y: 0, width: Self.chevronWidth, height: bounds.height)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            MacTheme.Color.onGlass.withAlphaComponent(0.1).setFill()
            region.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let ink = MacTheme.Color.onGlass
        let attributes = MacTheme.Ramp.attributes(.control, color: ink)
        if let spark = StudioTheme.symbol("sparkle", size: 10, weight: .semibold) {
            let tinted = NSImage(size: spark.size, flipped: false) { rect in
                spark.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: 10, y: (bounds.height - 12) / 2, width: 12, height: 12))
        }
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: 26, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        let chevron = NSBezierPath()
        let x = bounds.width - Self.chevronWidth / 2 - 1
        let y = bounds.height / 2
        chevron.move(to: NSPoint(x: x - 3, y: y - 1.5))
        chevron.line(to: NSPoint(x: x, y: y + 1.5))
        chevron.line(to: NSPoint(x: x + 3, y: y - 1.5))
        ink.withAlphaComponent(0.7).setStroke()
        chevron.lineWidth = 1.2
        chevron.lineCapStyle = .round
        chevron.stroke()
    }

    private func region(at point: NSPoint) -> Region {
        point.x >= bounds.width - Self.chevronWidth ? .picker : .main
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        hovering = region(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), state != .disabled else { return }
        switch region(at: point) {
        case .main:
            if state != .writing, state != .looking { onEnhance?() }
        case .picker:
            onPicker?(self)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard state != .disabled, state != .writing, state != .looking else { return false }
        onEnhance?()
        return true
    }
}

/// Generate beside the words — or Stop in its place while the machine works, because those are the
/// same place on the same hand. The accent is spent here once: the primary action of the whole surface.
@MainActor
final class StudioGoButton: NSView {
    enum Mode { case generate, stop }

    var onPress: (() -> Void)?
    var mode: Mode = .generate {
        didSet { if mode != oldValue { refresh() } }
    }

    var isEnabled = true {
        didSet { if isEnabled != oldValue { refresh() } }
    }

    private var pressing = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    var title = ImageGenWords.renderTitle(mode: .generate) {
        didSet { if title != oldValue { refresh() } }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refresh() {
        setAccessibilityLabel(mode == .stop ? ImageGenWords.stopTitle : title)
        setAccessibilityEnabled(isEnabled)
        toolTip = mode == .stop ? ImageGenWords.stopTitle + " (⎋)" : title + " (⌘↩)"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let label: String
        let hint: String
        let ink: NSColor
        switch mode {
        case .generate:
            label = title
            hint = "⌘↩"
            if isEnabled {
                (pressing ? MacTheme.Color.accent.blended(withFraction: 0.2, of: .black) ?? MacTheme.Color.accent : MacTheme.Color.accent).setFill()
                ink = MacTheme.Color.onAccent
            } else {
                MacTheme.Color.onGlass.withAlphaComponent(0.1).setFill()
                ink = MacTheme.Color.onGlassSecondary
            }
        case .stop:
            label = ImageGenWords.stopTitle
            hint = "⎋"
            MacTheme.Color.onGlass.withAlphaComponent(pressing ? 0.22 : (hovering ? 0.18 : 0.13)).setFill()
            ink = MacTheme.Color.onGlass
        }
        shape.fill()
        let main = MacTheme.Ramp.attributes(.control, color: ink)
        let small = MacTheme.Ramp.attributes(.panelFootnote, color: ink.withAlphaComponent(0.75))
        let labelSize = (label as NSString).size(withAttributes: main)
        let hintSize = (hint as NSString).size(withAttributes: small)
        let glyph: CGFloat = mode == .stop ? 14 : 0
        let total = glyph + (mode == .stop ? 8 : 0) + labelSize.width + 10 + hintSize.width
        var x = (bounds.width - total) / 2
        if mode == .stop {
            MacTheme.Color.danger.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - 10) / 2, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
            x += glyph + 8 - 4
        }
        (label as NSString).draw(at: NSPoint(x: x, y: (bounds.height - labelSize.height) / 2), withAttributes: main)
        (hint as NSString).draw(
            at: NSPoint(x: x + labelSize.width + 10, y: (bounds.height - hintSize.height) / 2),
            withAttributes: small)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressing = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressing = false
        needsDisplay = true
        if isEnabled, inside { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}

/// A rewrite, as the card that rises out of the dock over the stage's lower third: who is writing,
/// the paragraph as it streams, and the four things to do with it — use these words, keep mine, write
/// again, or one line to change. Opaque raised canvas, because it carries prose and prose never sits
/// on glass; it floats above the stage and moves nothing.
@MainActor
final class StudioRewriteCard: StudioRaisedView {
    static let riseDistance: CGFloat = 20

    var onUse: (() -> Void)?
    var onKeep: (() -> Void)?
    var onAgain: (() -> Void)?
    var onRevise: ((String) -> Void)?

    private let headline = StudioTheme.label(.panelLabel, color: MacTheme.Color.label)
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private let use = NSButton(title: ImageGenRewriteWords.useTitle, target: nil, action: nil)
    private let keep = NSButton(title: ImageGenRewriteWords.keepTitle, target: nil, action: nil)
    private let again = NSButton(title: ImageGenRewriteWords.againTitle, target: nil, action: nil)
    private let instruction = NSTextField()
    private var draft: ImageGenRewriteDraft?

    init() {
        super.init(radius: 16)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        for button in [use, keep, again] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
        }
        use.action = #selector(usePressed)
        use.keyEquivalent = ""
        use.bezelColor = MacTheme.Color.accent
        keep.action = #selector(keepPressed)
        again.action = #selector(againPressed)
        use.toolTip = ImageGenRewriteWords.useHint
        keep.toolTip = ImageGenRewriteWords.keepHint
        again.toolTip = ImageGenRewriteWords.againHint
        instruction.placeholderString = ImageGenRewriteWords.instructionPlaceholder
        instruction.font = MacTheme.Ramp.font(.panelFootnote)
        instruction.bezelStyle = .roundedBezel
        instruction.target = self
        instruction.action = #selector(revisePressed)
        for view in [headline, scroll, instruction, use, keep, again] { addSubview(view) }
        setAccessibilityRole(.group)
        setAccessibilityLabel(ImageGenRewriteWords.chooseTitle)
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
        headline.font = MacTheme.Ramp.font(.panelLabel)
        text.font = MacTheme.Ramp.font(.cardBody)
        text.textColor = MacTheme.Color.label
    }

    func show(_ next: ImageGenRewriteDraft) {
        let grew = draft?.written != next.written
        draft = next
        headline.stringValue = next.headline
        switch next.phase {
        case .failed:
            headline.textColor = MacTheme.Color.danger
        default:
            headline.textColor = MacTheme.Color.label
        }
        if grew {
            text.string = next.written
            text.scrollToEndOfDocument(nil)
        }
        let writing = next.isWriting
        use.isEnabled = next.isUsable
        use.isHidden = writing
        again.isHidden = writing
        keep.title = writing ? ImageGenRewriteWords.stopTitle : ImageGenRewriteWords.keepTitle
        instruction.isHidden = writing || !next.isUsable
        if case .failed = next.phase {
            text.string = next.original
            again.isHidden = false
        }
        setAccessibilityValue(next.announcement)
        needsLayout = true
    }

    /// As tall as the paragraph it holds, between four lines and ten: a short rewrite is a short card
    /// and a long one scrolls inside it rather than growing over the whole stage.
    func fitting(width: CGFloat) -> CGFloat {
        let font = MacTheme.Ramp.font(.cardBody)
        let words = draft?.written ?? ""
        let measured = (words as NSString).boundingRect(
            with: NSSize(width: max(80, width - 32), height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        let line = ceil(font.ascender - font.descender + font.leading)
        let body = min(max(ceil(measured) + 8, line * 4), line * 10)
        return 14 + StudioTheme.height(of: .panelLabel) + 8 + body + 10 + 28 + 14
    }

    func dismiss(animated: Bool) {
        guard !isHidden else { return }
        draft = nil
        guard animated else {
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = StudioTheme.rewriteRise
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainThread.call {
                guard let self, self.draft == nil else { return }
                self.isHidden = true
                self.alphaValue = 1
            }
        })
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 16
        let width = bounds.width - 2 * pad
        let headlineHeight = StudioTheme.height(of: .panelLabel)
        headline.frame = NSRect(x: pad, y: 14, width: width, height: headlineHeight)
        let bottom = bounds.height - 14
        let rowHeight: CGFloat = 28
        let buttonsY = bottom - rowHeight
        var x = pad
        if !use.isHidden {
            let size = use.fittingSize
            use.frame = NSRect(x: x, y: buttonsY, width: size.width, height: rowHeight)
            x += size.width + 8
        }
        let keepSize = keep.fittingSize
        keep.frame = NSRect(x: x, y: buttonsY, width: keepSize.width, height: rowHeight)
        x += keepSize.width + 8
        if !again.isHidden {
            let size = again.fittingSize
            again.frame = NSRect(x: x, y: buttonsY, width: size.width, height: rowHeight)
            x += size.width + 12
        }
        if !instruction.isHidden {
            instruction.frame = NSRect(x: x, y: buttonsY, width: max(0, bounds.width - pad - x), height: rowHeight)
        }
        let textTop = 14 + headlineHeight + 8
        scroll.frame = NSRect(x: pad, y: textTop, width: width, height: max(0, buttonsY - 10 - textTop))
        text.frame.size.width = scroll.contentSize.width
    }

    @objc private func usePressed() { onUse?() }
    @objc private func keepPressed() { onKeep?() }
    @objc private func againPressed() { onAgain?() }

    @objc private func revisePressed() {
        let line = instruction.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        instruction.stringValue = ""
        onRevise?(line)
    }
}
