import AppKit
import TailscodeCore

/// The footer's copy buttons: a caption over the value it will put on the pasteboard, which says
/// *Copied* in place of the caption for a moment afterwards. The value follows the line as it moves,
/// and the button is as wide as the whole value, at any type size.
@MainActor
final class MeridianCopyButton: NSView {
    private static let confirmFor: Duration = .milliseconds(1200)

    private let ground = TintView(
        fill: { MacTheme.Color.canvasRaised }, stroke: { MacTheme.Color.separator }, radius: 14)
    private let caption = MeridianLabel.framed(.metricLabel, color: MacTheme.Color.secondaryLabel)
    private let value = MeridianLabel.framed(.rowStamp)
    private let title: String
    private var copiedTicket = 0
    private(set) var isConfirming = false
    private(set) var payload = ""
    private var pressed = false {
        didSet { alphaValue = pressed ? 0.6 : 1 }
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ground.translatesAutoresizingMaskIntoConstraints = true
        addSubview(ground)
        addSubview(caption)
        addSubview(value)
        setAccessibilityRole(.button)
        HoverPlate.attach(to: self, placement: .over, radius: 14)
        NotificationCenter.default.addObserver(
            self, selector: #selector(restyle), name: MacTheme.Chrome.didRepaint, object: nil)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }

    override var intrinsicContentSize: NSSize {
        let captionWidth = max(captionSize(title).width, captionSize(Localized.text("Copied")).width)
        let width = max(captionWidth, MeridianMetrics.fit(value).width)
        let height = captionSize(title).height + MeridianMetrics.fit(value).height + 16
        return NSSize(width: ceil(width) + 28, height: max(44, ceil(height)))
    }

    private func captionSize(_ text: String) -> NSSize {
        let size = NSAttributedString(
            string: text.uppercased(), attributes: MacTheme.Ramp.attributes(.metricLabel)
        ).size()
        return NSSize(width: ceil(size.width) + 6, height: ceil(size.height))
    }

    func apply(value text: String) {
        payload = text
        value.stringValue = text
        setAccessibilityLabel("\(title), \(text)")
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let captionHeight = MeridianMetrics.fit(caption).height
        let valueHeight = MeridianMetrics.fit(value).height
        let top = (bounds.height - captionHeight - valueHeight) / 2
        caption.frame = CGRect(x: 14, y: top, width: bounds.width - 28, height: captionHeight)
        value.frame = CGRect(x: 14, y: top + captionHeight, width: bounds.width - 28, height: valueHeight)
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { copyValue() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": copyValue()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        copyValue()
        return true
    }

    func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        isConfirming = true
        copiedTicket += 1
        let ticket = copiedTicket
        restyle()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.confirmFor)
            guard let self, ticket == self.copiedTicket else { return }
            self.isConfirming = false
            self.restyle()
        }
    }

    @objc private func restyle() {
        let text = isConfirming ? Localized.text("Copied") : title
        caption.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: MacTheme.Ramp.attributes(
                .metricLabel,
                color: isConfirming ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel))
        value.font = MacTheme.Ramp.font(.rowStamp)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

/// One choice in the time-format control: the name of the style over what it writes right now, so a
/// person picks 24-hour or 12-hour by reading the time it gives rather than by knowing the words.
@MainActor
final class MeridianStyleSegment: NSControl {
    let style: ClockStyle
    var onSelect: ((ClockStyle) -> Void)?
    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            ground.fill = fillColour
            ground.stroke = strokeColour
            setAccessibilityValue(isChosen ? 1 : 0)
            needsLayout = true
        }
    }

    private let ground: TintView
    private let name = MeridianLabel.framed(.control)
    private let example = MeridianLabel.framed(.rowStamp, color: MacTheme.Color.secondaryLabel)

    override var isFlipped: Bool { true }

    init(style: ClockStyle) {
        self.style = style
        ground = TintView(radius: 12)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        ground.translatesAutoresizingMaskIntoConstraints = true
        ground.fill = fillColour
        ground.stroke = strokeColour
        name.stringValue = style.title
        addSubview(ground)
        addSubview(name)
        addSubview(example)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(style.title)
        HoverPlate.attach(to: self, placement: .over, radius: 12)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var fillColour: (() -> NSColor)? {
        let chosen = isChosen
        return chosen ? { MacTheme.Color.accent.withAlphaComponent(0.2) } : nil
    }

    private var strokeColour: (() -> NSColor)? {
        let chosen = isChosen
        return chosen ? { MacTheme.Color.accent } : nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    func apply(example text: String) {
        example.stringValue = text
        name.font = MacTheme.Ramp.font(.control)
        example.font = MacTheme.Ramp.font(.rowStamp)
        setAccessibilityHelp(text)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let width = max(MeridianMetrics.fit(name).width, MeridianMetrics.fit(example).width) + 24
        let height = MeridianMetrics.fit(name).height + MeridianMetrics.fit(example).height + 10
        return NSSize(width: width, height: max(38, height))
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let nameSize = MeridianMetrics.fit(name)
        let exampleSize = MeridianMetrics.fit(example)
        let top = (bounds.height - nameSize.height - exampleSize.height) / 2
        name.frame = CGRect(
            x: (bounds.width - nameSize.width) / 2, y: top, width: nameSize.width, height: nameSize.height)
        example.frame = CGRect(
            x: (bounds.width - exampleSize.width) / 2, y: top + nameSize.height,
            width: exampleSize.width, height: exampleSize.height)
        name.textColor = isChosen ? MacTheme.Color.accent : MacTheme.Color.label
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        onSelect?(style)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": onSelect?(style)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(style)
        return true
    }
}

/// The time format as a labelled three-way control: Follow system, 24-hour, 12-hour, each showing the
/// time it would write now. Choosing one writes the store and the sheet redraws in place.
@MainActor
final class MeridianStyleControl: NSView {
    var onChoose: ((ClockStyle) -> Void)?

    private let ground = TintView(
        fill: { MacTheme.Color.canvasRaised }, stroke: { MacTheme.Color.separator }, radius: 15)
    private(set) var segments: [MeridianStyleSegment] = ClockStyle.allCases.map {
        MeridianStyleSegment(style: $0)
    }

    private static let inset: CGFloat = 3

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ground.translatesAutoresizingMaskIntoConstraints = true
        addSubview(ground)
        for segment in segments {
            segment.onSelect = { [weak self] style in self?.onChoose?(style) }
            addSubview(segment)
        }
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(Localized.text("Time style"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(style: ClockStyle, instant: Date, viewer: TimeZone) {
        for segment in segments {
            segment.apply(example: segment.style.example(at: instant, in: viewer))
            segment.isChosen = segment.style == style
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let widths = segments.map { $0.intrinsicContentSize.width }
        let height = (segments.map { $0.intrinsicContentSize.height }.max() ?? 38) + 2 * Self.inset
        return NSSize(width: widths.reduce(0, +) + 2 * Self.inset + CGFloat(widths.count - 1) * 2, height: height)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        var x = Self.inset
        for segment in segments {
            let width = segment.intrinsicContentSize.width
            segment.frame = CGRect(
                x: x, y: Self.inset, width: width, height: bounds.height - 2 * Self.inset)
            x += width + 2
        }
    }
}

/// A removable chip that carries its own padding and wraps a row of views in a capsule, for alarms.
@MainActor
final class MeridianPill: NSView {
    private let content: NSView
    private let ground = TintView(
        fill: { MacTheme.Color.canvasRaised }, stroke: { MacTheme.Color.separator })

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        ground.translatesAutoresizingMaskIntoConstraints = true
        addSubview(ground)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let fitting = content.fittingSize
        return NSSize(width: ceil(fitting.width) + 16, height: ceil(fitting.height) + 8)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
    }
}
