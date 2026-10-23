import AppKit
import TailscodeCore

/// Every colour the account draws with, resolved from the palette the row wears. The named
/// themes are Core's palettes; under System they are the platform's own (amber is `systemOrange`,
/// red `systemRed`), because `BrainInks` already makes that palette.
@MainActor
struct AccountPaint: Equatable {
    let inks: BrainInks

    init(_ inks: BrainInks) { self.inks = inks }

    private var palette: Palette { inks.palette }

    private func color(_ hex: String) -> NSColor { NSColor(hex: hex) ?? .labelColor }

    var accent: NSColor { color(palette.accent) }
    var warn: NSColor { color(palette.warn) }
    var danger: NSColor { color(palette.danger) }
    var info: NSColor { color(palette.info) }
    var text: NSColor { color(palette.text) }
    /// The quiet ink. Under System the palette's own dim ink is a label colour whose alpha the
    /// palette lost, so it reads as the full ink; there it is the ink a little way into the canvas.
    var dim: NSColor {
        if palette.name == ThemeSelection.systemID {
            return color(Contrast.blend(palette.canvas, palette.text, 0.62) ?? palette.textDim)
        }
        return color(palette.textDim)
    }
    var rule: NSColor { color(palette.rule) }
    var raised: NSColor { color(palette.canvasRaised) }
    var canvas: NSColor { color(palette.canvas) }
    var isDark: Bool { palette.isDark }

    /// The stronger hairline: the canvas a third of the way to the dim ink.
    var rule2: NSColor { mix(canvas, dim, 0.34) }

    /// A recessed box on the canvas.
    var well: NSColor { color(Contrast.blend(palette.canvas, palette.text, 0.045) ?? palette.canvasRaised) }

    /// What failed output wears: the dim ink pulled toward the danger tone.
    var dangerText: NSColor { mix(dim, danger, 0.72) }

    func zone(_ zone: NeuralZone) -> NSColor { inks.page(zone) }

    func tone(_ tone: NeuralTone) -> NSColor {
        switch tone {
        case .live, .identity: return accent
        case .attention: return warn
        case .danger: return danger
        case .quiet: return dim
        }
    }

    func verdict(_ verdict: NeuralVerdict.Step) -> NSColor {
        switch verdict {
        case .done: return accent
        case .fixed, .tryingAgain, .waiting, .stalled: return warn
        case .failed: return danger
        case .running: return accent
        case .stopped: return dim
        }
    }

    func family(_ family: ModelTint.Family?) -> NSColor {
        guard let family else { return accent }
        return color(ModelTint.hex(family, in: palette))
    }

    func mix(_ one: NSColor, _ other: NSColor, _ amount: CGFloat) -> NSColor {
        one.blended(withFraction: amount, of: other) ?? one
    }
}

/// The ramp's roles as the account sets them, and the arithmetic of text that wraps: a height is
/// asked of the same layout engine that draws the words, never estimated from a character count.
@MainActor
enum AccountType {
    static func attributes(
        _ role: TypeRole, _ color: NSColor, lineBreak: NSLineBreakMode = .byWordWrapping
    ) -> [NSAttributedString.Key: Any] {
        var attributes = MacTheme.Ramp.attributes(role, color: color)
        let paragraph =
            ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
            ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        attributes[.paragraphStyle] = paragraph
        return attributes
    }

    static func string(
        _ text: String, _ role: TypeRole, _ color: NSColor, lineBreak: NSLineBreakMode = .byWordWrapping
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes(role, color, lineBreak: lineBreak))
    }

    static func font(_ role: TypeRole) -> NSFont { MacTheme.Ramp.font(role) }

    /// The width of `text` on one line, tracking included: what `draw` will take.
    static func width(_ text: String, _ role: TypeRole) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: attributes(role, .labelColor)).size().width)
    }

    static func monoWidth(_ role: TypeRole) -> CGFloat {
        ceil(("0" as NSString).size(withAttributes: [.font: font(role)]).width)
    }

    /// One line of a role, with the leading its paragraph style asks for.
    static func lineHeight(_ role: TypeRole) -> CGFloat {
        height(string("Mg", role, .labelColor), width: 400)
    }

    /// The height `text` takes at `width`, in at most `maxLines` lines (0 for all of them).
    static func height(_ text: NSAttributedString, width: CGFloat, maxLines: Int = 0) -> CGFloat {
        guard text.length > 0, width > 1 else { return 0 }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    /// How many lines `text` takes at `width`.
    static func lineCount(_ text: NSAttributedString, width: CGFloat, role: TypeRole) -> Int {
        let line = lineHeight(role)
        guard line > 0 else { return 0 }
        return Int((height(text, width: width) / line).rounded())
    }

    /// Draws `text` on one line, centred on `midY`, cut with an ellipsis at `maxWidth`; returns
    /// the width it took.
    @discardableResult
    static func draw(
        _ text: String, _ role: TypeRole, _ color: NSColor, x: CGFloat, midY: CGFloat,
        maxWidth: CGFloat = CGFloat.greatestFiniteMagnitude, rightAligned: Bool = false,
        lineBreak: NSLineBreakMode = .byTruncatingTail
    ) -> CGFloat {
        guard maxWidth > 1, !text.isEmpty else { return 0 }
        let attributed = string(text, role, color, lineBreak: lineBreak)
        let line = lineHeight(role)
        let natural = ceil(attributed.size().width)
        let used = min(natural, maxWidth)
        let left = rightAligned ? x - used : x
        attributed.draw(
            with: NSRect(x: left, y: midY - line / 2, width: used + 1, height: line),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        return used
    }

    /// Prose as the agent wrote it: a word between backticks is code, in the mono face and the
    /// info colour, and nothing else is rewritten.
    static func prose(_ text: String, role: TypeRole, paint: AccountPaint) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = attributes(role, paint.text)
        var code = attributes(.code, paint.info)
        if let paragraph = base[.paragraphStyle] { code[.paragraphStyle] = paragraph }
        var inCode = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            result.append(NSAttributedString(string: run, attributes: inCode ? code : base))
            run = ""
        }
        for character in text {
            if character == "`" {
                flush()
                inCode.toggle()
            } else {
                run.append(character)
            }
        }
        flush()
        return result
    }
}

/// The small marks every verdict wears, so amber and red are told apart by shape and word and
/// never by colour alone: a check for done, a circular arrow for fixed on retry, a cross for
/// failed, a triangle for an error being retried, a dot for running, pause bars for waiting, a
/// dashed clock for stuck, a square for stopped.
@MainActor
enum AccountGlyphs {
    static func verdict(
        _ verdict: NeuralVerdict.Step, cx: CGFloat, cy: CGFloat, size: CGFloat, color: NSColor
    ) {
        color.set()
        switch verdict {
        case .done: check(cx: cx, cy: cy, size: size)
        case .fixed: retryArrow(cx: cx, cy: cy, size: size)
        case .failed: cross(cx: cx, cy: cy, half: size * 0.3)
        case .tryingAgain: triangle(cx: cx, cy: cy, size: size)
        case .running: dot(cx: cx, cy: cy, radius: size * 0.3)
        case .waiting: pauseBars(cx: cx, cy: cy, size: size)
        case .stalled: dashedClock(cx: cx, cy: cy, size: size)
        case .stopped: stopSquare(cx: cx, cy: cy, size: size)
        }
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    static func check(cx: CGFloat, cy: CGFloat, size: CGFloat) {
        let u = size / 12
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx - 4.2 * u, y: cy + 0.2 * u))
        path.line(to: NSPoint(x: cx - 1.3 * u, y: cy + 3.2 * u))
        path.line(to: NSPoint(x: cx + 4.4 * u, y: cy - 3.4 * u))
        stroke(path, width: 1.7)
    }

    static func retryArrow(cx: CGFloat, cy: CGFloat, size: CGFloat) {
        let radius = size * 0.38
        let start = -0.15 * Double.pi
        let end = 1.55 * Double.pi
        let path = NSBezierPath()
        let steps = 28
        for index in 0...steps {
            let angle = start + (end - start) * Double(index) / Double(steps)
            let point = NSPoint(x: cx + radius * CGFloat(cos(angle)), y: cy + radius * CGFloat(sin(angle)))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        stroke(path, width: 1.7)
        let tip = NSPoint(x: cx + radius * CGFloat(cos(end)), y: cy + radius * CGFloat(sin(end)))
        let head = NSBezierPath()
        head.move(to: NSPoint(x: tip.x - size * 0.28, y: tip.y - size * 0.22))
        head.line(to: NSPoint(x: tip.x + size * 0.06, y: tip.y + size * 0.02))
        head.line(to: NSPoint(x: tip.x - size * 0.26, y: tip.y + size * 0.26))
        stroke(head, width: 1.7)
    }

    static func cross(cx: CGFloat, cy: CGFloat, half: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx - half, y: cy - half))
        path.line(to: NSPoint(x: cx + half, y: cy + half))
        path.move(to: NSPoint(x: cx + half, y: cy - half))
        path.line(to: NSPoint(x: cx - half, y: cy + half))
        stroke(path, width: 1.8)
    }

    static func triangle(cx: CGFloat, cy: CGFloat, size: CGFloat) {
        let h = size * 0.42
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: cx, y: cy - h))
        outline.line(to: NSPoint(x: cx + h * 1.15, y: cy + h * 0.8))
        outline.line(to: NSPoint(x: cx - h * 1.15, y: cy + h * 0.8))
        outline.close()
        stroke(outline, width: 1.5)
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: cx, y: cy - h * 0.25))
        stem.line(to: NSPoint(x: cx, y: cy + h * 0.2))
        stroke(stem, width: 1.5)
        NSBezierPath(ovalIn: NSRect(x: cx - 0.6, y: cy + h * 0.52 - 0.6, width: 1.2, height: 1.2)).fill()
    }

    static func pauseBars(cx: CGFloat, cy: CGFloat, size: CGFloat) {
        let h = size * 0.7
        let w = max(1.8, size * 0.17)
        for offset in [-size * 0.28, size * 0.28] {
            NSBezierPath(
                roundedRect: NSRect(x: cx + offset - w / 2, y: cy - h / 2, width: w, height: h),
                xRadius: w / 2, yRadius: w / 2
            ).fill()
        }
    }

    static func dashedClock(cx: CGFloat, cy: CGFloat, size: CGFloat) {
        let ring = NSBezierPath(
            ovalIn: NSRect(x: cx - size * 0.42, y: cy - size * 0.42, width: size * 0.84, height: size * 0.84))
        ring.setLineDash([1.8, 1.8], count: 2, phase: 0)
        stroke(ring, width: 1.4)
        let hands = NSBezierPath()
        hands.move(to: NSPoint(x: cx, y: cy - size * 0.24))
        hands.line(to: NSPoint(x: cx, y: cy))
        hands.line(to: NSPoint(x: cx + size * 0.18, y: cy + size * 0.1))
        stroke(hands, width: 1.4)
    }

    static func stopSquare(cx: CGFloat, cy: CGFloat, size: CGFloat) {
        let side = size * 0.55
        let path = NSBezierPath(
            roundedRect: NSRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side),
            xRadius: 1.6, yRadius: 1.6)
        stroke(path, width: 1.5)
    }

    static func dot(cx: CGFloat, cy: CGFloat, radius: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)).fill()
    }

    /// A zone's shape, stroked, centred at (`cx`, `cy`): the shape fills about 13 points of an 18
    /// point box.
    static func zone(_ zone: NeuralZone, cx: CGFloat, cy: CGFloat, color: NSColor, radius: CGFloat = 6.5) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: cx - radius, y: cy - radius)
        context.addPath(BrainShapes.path(zone.shape, radius: radius))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    /// The quote a said row and a note wear: two filled commas turned the way an opening double
    /// quote is.
    static func quote(cx: CGFloat, cy: CGFloat, color: NSColor) {
        color.set()
        for offset in [CGFloat(-4.2), CGFloat(3.2)] {
            let x = cx + offset
            NSBezierPath(ovalIn: NSRect(x: x - 2.6, y: cy + 2.2 - 2.6, width: 5.2, height: 5.2)).fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: x + 2.3, y: cy + 1.6))
            tail.curve(
                to: NSPoint(x: x - 0.6, y: cy - 5.6), controlPoint1: NSPoint(x: x + 2.9, y: cy - 2.4),
                controlPoint2: NSPoint(x: x + 1.8, y: cy - 4.4))
            stroke(tail, width: 2.2)
        }
    }

    static func magnifier(x: CGFloat, midY: CGFloat, color: NSColor) {
        color.set()
        let ring = NSBezierPath(ovalIn: NSRect(x: x + 1, y: midY - 6, width: 9, height: 9))
        stroke(ring, width: 1.5)
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: x + 9, y: midY + 2))
        handle.line(to: NSPoint(x: x + 13, y: midY + 6))
        stroke(handle, width: 1.5)
    }

    /// The family dot at the head of a speaker's name.
    static func familyDot(cx: CGFloat, cy: CGFloat, radius: CGFloat, color: NSColor) {
        color.set()
        dot(cx: cx, cy: cy, radius: radius)
    }

    /// A plan item's mark: a check for done, a dot for the one in progress, an open ring for the rest.
    static func planMark(_ state: NeuralAccount.PlanState, cx: CGFloat, cy: CGFloat, paint: AccountPaint) {
        switch state {
        case .done:
            paint.accent.set()
            check(cx: cx, cy: cy, size: 12)
        case .inProgress:
            paint.accent.set()
            dot(cx: cx, cy: cy, radius: 4)
        case .pending:
            paint.dim.withAlphaComponent(0.8).set()
            let ring = NSBezierPath(ovalIn: NSRect(x: cx - 3.6, y: cy - 3.6, width: 7.2, height: 7.2))
            ring.lineWidth = 1.3
            ring.stroke()
        }
    }

    /// The effort the turn ran at: five bars of rising height, lit up to its level, hollow when
    /// the server chose, a rainbow for a power.
    static func effortBars(_ face: NeuralFace, x: CGFloat, midY: CGFloat, paint: AccountPaint) {
        let heights: [CGFloat] = [4, 6.5, 9, 11, 12]
        for (index, h) in heights.enumerated() {
            let rect = NSRect(x: x + CGFloat(index) * 5, y: midY + 6 - h, width: 3, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2)
            if face.hollow {
                paint.dim.withAlphaComponent(0.7).setStroke()
                path.lineWidth = 1
                path.stroke()
                continue
            }
            let lit = index < face.effort
            var color = paint.text
            if face.rainbow {
                color = NSColor(hue: CGFloat(index) / 5, saturation: 0.65, brightness: 0.95, alpha: 1)
            } else if face.ember {
                color = paint.warn
            }
            (lit || face.rainbow ? color : paint.dim.withAlphaComponent(0.32)).setFill()
            path.fill()
        }
    }
}

/// A selectable block of words. The brain's keys are the brain's even while the pointer has put
/// the caret in a note, so every key but a command chord goes to the account first; a click both
/// sets the cursor to the step the words belong to and lets the selection begin.
@MainActor
final class AccountTextView: NSTextView, BrainKeyTaker {
    var onPress: (() -> Void)?
    var onLink: ((String) -> Void)?
    var keys: ((NSEvent) -> Bool)?
    weak var host: BrainSurfaceHost?
    private let storageHolder: NSTextStorage

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        storageHolder = storage
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isRichText = true
        importsGraphics = false
        allowsUndo = false
        isAutomaticLinkDetectionEnabled = false
        delegate = self
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    /// Sets the words and lays them out at `width`, in at most `maxLines` lines; returns the
    /// height and sizes the view to it.
    @discardableResult
    func set(_ text: NSAttributedString, width: CGFloat, maxLines: Int = 0) -> CGFloat {
        storageHolder.setAttributedString(text)
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.size = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        setFrameSize(NSSize(width: max(width, 1), height: height))
        setAccessibilityValue(text.string)
        return height
    }

    func setLinkLook(_ color: NSColor) {
        linkTextAttributes = [
            .foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    func setSelectionLook(_ color: NSColor) {
        selectedTextAttributes = [.backgroundColor: color.withAlphaComponent(0.3)]
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isSelectable ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) {
            if let keys {
                if keys(event) { return }
            } else if host?.handleBrainKey(event, from: self) == true {
                return
            }
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    func takesBrainKey(_ event: NSEvent) -> Bool { host?.brainKeyApplies(event) ?? false }

    override func resetCursorRects() {
        if isSelectable { addCursorRect(bounds, cursor: .iBeam) }
    }
}

extension AccountTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let text = (link as? URL)?.absoluteString ?? (link as? String) else { return false }
        onLink?(text)
        return true
    }
}

/// A flat button, a pill, a chip or a link: the one control the account draws buttons with. It
/// takes the keyboard only when the account sends it there (Enter on the card) or when full
/// keyboard access asks every control to, so a click never takes the keys from the list.
@MainActor
final class AccountButton: NSView, BrainKeyTaker {
    enum Style: Equatable {
        case pill
        case filled
        case ghost
        case link
        case step
        case relation(retry: Bool)
    }

    var style: Style { didSet { if style != oldValue { restyle() } } }
    var title: String { didSet { if title != oldValue { restyle() } } }
    var emphasis: String? { didSet { if emphasis != oldValue { restyle() } } }
    var paint: AccountPaint { didSet { if paint != oldValue { needsDisplay = true } } }
    var onTap: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var tone: NSColor?
    var isLit = false { didSet { if isLit != oldValue { needsDisplay = true } } }
    weak var host: BrainSurfaceHost?
    var keyboardEngaged = false
    private(set) var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    init(title: String, style: Style, paint: AccountPaint) {
        self.title = title
        self.style = style
        self.paint = paint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { keyboardEngaged || NSApp.isFullKeyboardAccessEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var role: TypeRole {
        switch style {
        case .pill, .filled, .ghost: return .control
        case .link: return .rowMeta
        case .step: return .rowStamp
        case .relation: return .chip
        }
    }

    private func restyle() {
        setAccessibilityLabel(title)
        let size = fittingSize
        setFrameSize(size)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override var fittingSize: NSSize {
        let text = AccountType.width(title, role) + (emphasis.map { AccountType.width(" " + $0, role) } ?? 0)
        switch style {
        case .pill: return NSSize(width: text + 18, height: 24)
        case .filled, .ghost: return NSSize(width: text + 28, height: 30)
        case .link: return NSSize(width: text, height: AccountType.lineHeight(role))
        case .step: return NSSize(width: text + 6, height: 18)
        case .relation: return NSSize(width: text + 20, height: 22)
        }
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let lit = hovered || isLit || (window?.firstResponder === self)
        let ink: NSColor
        switch style {
        case .pill:
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            (pressed ? paint.rule : paint.raised).setFill()
            path.fill()
            (lit ? paint.accent : paint.rule2).setStroke()
            path.lineWidth = 1
            path.stroke()
            ink = lit ? paint.accent : paint.text
        case .filled:
            let fill = tone ?? paint.warn
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            fill.withAlphaComponent(hovered || pressed ? 0.85 : 1).setFill()
            path.fill()
            ink = paint.canvas
        case .ghost:
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            (lit ? paint.accent : paint.rule2).setStroke()
            path.lineWidth = 1
            path.stroke()
            ink = paint.text
        case .link:
            ink = lit ? paint.text : paint.dim
        case .step:
            ink = lit ? paint.accent : paint.dim
        case .relation(let retry):
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            (lit ? paint.accent : (retry ? paint.accent.withAlphaComponent(0.55) : paint.rule2)).setStroke()
            path.lineWidth = 1
            path.stroke()
            ink = paint.text
        }
        let line = AccountType.lineHeight(role)
        var x: CGFloat
        switch style {
        case .link: x = 0
        case .step: x = 3
        case .relation: x = 10
        case .pill: x = 9
        case .filled, .ghost: x = 14
        }
        let room = bounds.width - x * 2
        var titleInk = ink
        if emphasis != nil, case .relation = style { titleInk = paint.dim }
        let used = AccountType.draw(title, role, titleInk, x: x, midY: bounds.midY, maxWidth: max(room, 1))
        if let emphasis {
            let attributes = AccountType.attributes(role, ink)
            let bold = NSFont.monospacedSystemFont(ofSize: AccountType.font(role).pointSize, weight: .bold)
            var withBold = attributes
            withBold[.font] = bold
            (" " + emphasis as NSString).draw(
                at: NSPoint(x: x + used, y: bounds.midY - line / 2), withAttributes: withBold)
        }
        if style == .link {
            let underline = NSBezierPath()
            underline.move(to: NSPoint(x: 0, y: bounds.maxY - 1.5))
            underline.line(to: NSPoint(x: min(used, bounds.width), y: bounds.maxY - 1.5))
            underline.lineWidth = 1
            (lit ? paint.dim : paint.rule2).setStroke()
            underline.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        needsDisplay = true
        onHover?(false)
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

    override func resignFirstResponder() -> Bool {
        keyboardEngaged = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    func takesBrainKey(_ event: NSEvent) -> Bool { host?.brainKeyApplies(event) ?? false }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// A status word in a tone: a capsule with a hairline in its colour, and a verdict's mark before
/// the word when it has one.
@MainActor
final class AccountPill: NSView {
    var word = "" { didSet { if word != oldValue { restyle() } } }
    var color = NSColor.secondaryLabelColor { didSet { if color != oldValue { needsDisplay = true } } }
    var verdict: NeuralVerdict.Step? { didSet { if verdict != oldValue { restyle() } } }
    var height: CGFloat = 18 { didSet { if height != oldValue { restyle() } } }
    var role: TypeRole = .badge { didSet { if role != oldValue { restyle() } } }
    /// The mark's room is kept but nothing is drawn in it: a pulse is laid over it instead.
    var hidesGlyph = false { didSet { if hidesGlyph != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let glyph: CGFloat = verdict == nil ? 0 : 18
        return NSSize(width: AccountType.width(word, role) + 16 + glyph, height: height)
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    private func restyle() {
        setAccessibilityLabel(word)
        setFrameSize(fittingSize)
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        color.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
        var x: CGFloat = 8
        if let verdict {
            if !hidesGlyph { AccountGlyphs.verdict(verdict, cx: 14, cy: bounds.midY, size: 12, color: color) }
            x = 24
        }
        AccountType.draw(word, role, color, x: x, midY: bounds.midY, maxWidth: bounds.width - x - 8)
    }
}

/// A dot that breathes, knocks or holds still, laid on the render server so it costs nothing per
/// frame: the vocabulary's own swell, begun at the last whole period of absolute time so every
/// dot on screen swells as one hand.
@MainActor
final class AccountPulseDot: NSView {
    private let dot = CAShapeLayer()
    private var motion = NeuralMotion.still
    private var diameter: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    func configure(color: NSColor, motion: NeuralMotion, diameter: CGFloat) {
        self.diameter = diameter
        self.motion = motion
        dot.fillColor = color.cgColor
        setFrameSize(NSSize(width: diameter + 2, height: diameter + 2))
        needsLayout = true
        applyMotion()
    }

    override func layout() {
        super.layout()
        dot.frame = bounds
        dot.path = CGPath(
            ellipseIn: CGRect(
                x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter,
                height: diameter), transform: nil)
        applyMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { applyMotion() }
    }

    private func applyMotion() {
        BrainMotion.breathe(dot, motion)
    }

    var isBreathing: Bool { BrainMotion.isBreathing(dot) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A 1 point rule or a washed rectangle that is only a colour: the account's quiet furniture.
@MainActor
final class AccountRuleView: NSView {
    var color = NSColor.separatorColor { didSet { needsDisplay = true } }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
