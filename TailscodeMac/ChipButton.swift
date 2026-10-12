import AppKit
import TailscodeCore

/// A view whose corners are half its height, so a pill is a capsule at whatever size its words
/// make it and no radius is ever written down for one.
@MainActor
final class CapsuleView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// What a chip's ground is made of, in one place so a chip and a segmented chip cannot disagree:
/// the theme's ink mixed into its canvas at the share `ChatChrome` names, an outline for a control,
/// and a radius of half the height.
@MainActor
enum ChipGround {
    static func paint(_ layer: CALayer, kind: ChatChrome.Kind, height: CGFloat) {
        let fill = ChatChrome.fill(kind)
        let ground = MacTheme.Color.canvas.blended(
            withFraction: CGFloat(fill.inkShare), of: MacTheme.Color.label) ?? MacTheme.Color.canvas
        layer.backgroundColor = ground.cgColor
        layer.borderColor = MacTheme.Color.separator.cgColor
        layer.borderWidth = fill.outlined ? 1 : 0
        layer.cornerRadius = height / 2
    }
}

/// The one shape every control in the composer's row is: `ChatChrome`'s pointer chip, a capsule
/// twenty-four points tall with an opaque fill — the theme's ink mixed into its canvas — and, for a
/// control, an outline. A chip that reads a fact is flat and one that makes a choice is outlined,
/// and the live ones carry their meaning on a dot, never on a tinted capsule, so this draws the
/// ground and nothing else: what stands inside it is the subclass's.
///
/// The ground is the button's own layer, redrawn when the appearance or the theme changes rather
/// than remembered, because a colour resolved under one theme answers that theme forever.
@MainActor
class ChipButton: NSButton {
    let kind: ChatChrome.Kind
    let metrics = ChatChrome.chip(on: .pointer)

    private var installed: NSView?

    init(kind: ChatChrome.Kind = .control) {
        self.kind = kind
        super.init(frame: .zero)
        isBordered = false
        title = ""
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = ChatChrome.fill(kind).outlined ? 1 : 0
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)
        setContentHuggingPriority(.required, for: .horizontal)
        HoverPlate.attach(to: self, placement: .over, radius: height / 2)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        needsDisplay = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The table's twenty-four, and taller only when the window's type is large enough that its
    /// words would not fit inside them.
    var height: CGFloat {
        let font = MacTheme.Ramp.font(ChatChrome.chipRole)
        let line = font.ascender - font.descender + font.leading
        return max(CGFloat(metrics.height), ceil(line + 8))
    }

    var padding: CGFloat { CGFloat(metrics.padding) }

    private var leadingPin: NSLayoutConstraint?
    private var trailingPin: NSLayoutConstraint?

    /// Puts what the chip says inside it, centred and held off the edges by the table's padding.
    /// `trailing` is for a content that draws a little past its own box.
    func install(content: NSView, leading: CGFloat? = nil, trailing: CGFloat? = nil) {
        installed?.removeFromSuperview()
        installed = content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let start = content.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: leading ?? padding)
        let end = content.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -(trailing ?? padding))
        leadingPin = start
        trailingPin = end
        NSLayoutConstraint.activate([start, end, content.centerYAnchor.constraint(equalTo: centerYAnchor)])
        invalidateIntrinsicContentSize()
    }

    /// How far the content stands from each edge, changed when what the chip says changes shape.
    func setInsets(leading: CGFloat, trailing: CGFloat) {
        leadingPin?.constant = leading
        trailingPin?.constant = -trailing
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let installed, let leadingPin, let trailingPin else {
            return NSSize(width: height, height: height)
        }
        return NSSize(
            width: ceil(installed.fittingSize.width + leadingPin.constant - trailingPin.constant),
            height: height)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ChipGround.paint(layer, kind: kind, height: bounds.height)
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func themeChanged() {
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            .fill()
    }

    /// The labels inside are ornament: a press anywhere on the chip is a press on the chip.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

/// A chip that says one thing: an optional SF Symbol at the table's twelve points and an optional
/// word in the chip's one type role. Meaning rides the glyph's tone; the word is the theme's
/// ordinary ink.
@MainActor
class SymbolChip: ChipButton {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let row = NSStackView()
    private var tone: ActivityTone?

    var symbol: String? {
        didSet { redrawIcon() }
    }

    /// What a press does, for a chip that has no target of its own.
    var onTap: (() -> Void)? {
        didSet {
            target = self
            action = #selector(tapped)
        }
    }

    @objc private func tapped() { onTap?() }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.isHidden = newValue.isEmpty
            fit()
        }
    }

    /// The tone the glyph wears; nil is the theme's ordinary secondary ink.
    var glyphTone: ActivityTone? {
        get { tone }
        set {
            tone = newValue
            redrawIcon()
        }
    }

    override init(kind: ChatChrome.Kind = .control) {
        super.init(kind: kind)
        icon.imageScaling = .scaleNone
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        label.setContentCompressionResistancePriority(.init(450), for: .horizontal)
        label.isHidden = true
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CGFloat(metrics.iconGap)
        row.setViews([icon, label], in: .center)
        install(content: row)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A chip with a glyph and no word is a square, so the glyph is centred rather than held off
    /// the edge by the padding a word needs.
    private func fit() {
        let side = label.isHidden
            ? max(0, (height - CGFloat(metrics.iconSize) * MacTheme.UIScale.factor) / 2)
            : padding
        setInsets(leading: side, trailing: side)
    }

    /// The chip's type and glyph are asked for again rather than remembered: a type-scale step
    /// changes what the role is worth.
    func restyle() {
        label.font = MacTheme.Ramp.font(ChatChrome.chipRole)
        label.textColor = MacTheme.Color.label
        redrawIcon()
        fit()
    }

    private func redrawIcon() {
        guard let symbol else {
            icon.image = nil
            icon.isHidden = true
            fit()
            return
        }
        icon.isHidden = false
        let configuration = NSImage.SymbolConfiguration(
            pointSize: CGFloat(metrics.iconSize) * MacTheme.UIScale.factor, weight: .medium)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        icon.contentTintColor = tone.map(\.color) ?? MacTheme.Color.secondaryLabel
        fit()
    }
}

/// A row of words in one capsule, a press on one of them a door rather than a selection: the
/// composer's lanes. It is drawn here rather than by AppKit's segmented control because that one
/// sets its own height, its own radius and its own weight, and the row it stands in is made of
/// chips of one height, one radius and one type role.
@MainActor
final class SegmentedChip: NSView {
    var onSelect: ((Int) -> Void)?
    private let stack = NSStackView()
    private var segments: [SegmentButton] = []
    private let metrics = ChatChrome.chip(on: .pointer)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.group)
        setContentHuggingPriority(.required, for: .horizontal)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var height: CGFloat {
        let font = MacTheme.Ramp.font(ChatChrome.chipRole)
        return max(CGFloat(metrics.height), ceil(font.ascender - font.descender + font.leading + 8))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: stack.fittingSize.width, height: height)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ChipGround.paint(layer, kind: .control, height: bounds.height)
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func repaint() {
        needsDisplay = true
        restyle()
    }

    /// One word per segment, each with its own tooltip and the words a screen reader says.
    func set(words: [String], tips: [String]) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        segments = []
        for (index, word) in words.enumerated() {
            if index > 0 { stack.addArrangedSubview(divider()) }
            let segment = SegmentButton(radius: height / 2)
            segment.title = word
            segment.toolTip = tips.indices.contains(index) ? tips[index] : nil
            segment.setAccessibilityLabel(tips.indices.contains(index) ? tips[index] : word)
            segment.onPress = { [weak self] in self?.onSelect?(index) }
            segments.append(segment)
            stack.addArrangedSubview(segment)
            segment.heightAnchor.constraint(equalTo: heightAnchor).isActive = true
        }
        restyle()
        invalidateIntrinsicContentSize()
    }

    func restyle() {
        for segment in segments { segment.restyle(padding: CGFloat(metrics.padding)) }
        invalidateIntrinsicContentSize()
    }

    private func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 12).isActive = true
        line.layer?.backgroundColor = MacTheme.Color.separator.cgColor
        line.setAccessibilityElement(false)
        return line
    }
}

@MainActor
private final class SegmentButton: NSButton {
    var onPress: (() -> Void)?
    private var padding: CGFloat = 9
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)
        HoverPlate.attach(to: self, placement: .over, radius: radius)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func restyle(padding: CGFloat) {
        self.padding = padding
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: MacTheme.Ramp.font(ChatChrome.chipRole),
                .foregroundColor: MacTheme.Color.label,
            ])
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let word = attributedTitle.size().width
        return NSSize(width: ceil(word + padding * 2), height: NSView.noIntrinsicMetric)
    }

    @objc private func pressed() { onPress?() }
}

/// Chips laid out in lines that break where the next one would not fit, each line centred, so a row
/// of starters is two lines in a wide pane and four in a narrow one. The height it needs is a
/// consequence of the width it is given, which is why it sets its own height constraint when it is
/// laid out rather than asking for an intrinsic one.
@MainActor
final class StarterFlow: NSView {
    private var chips: [NSView] = []
    private let spacing = CGFloat(ChatChrome.chip(on: .pointer).spacing)
    private lazy var tall = heightAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        tall.isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func set(_ views: [NSView]) {
        for chip in chips { chip.removeFromSuperview() }
        chips = views
        for chip in views {
            chip.translatesAutoresizingMaskIntoConstraints = true
            addSubview(chip)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = place()
        if tall.constant != height { tall.constant = height }
    }

    private func place() -> CGFloat {
        let sizes = chips.map { $0.fittingSize }
        var lines: [[Int]] = [[]]
        var used: CGFloat = 0
        for index in sizes.indices {
            let width = sizes[index].width
            let next = used == 0 ? width : used + spacing + width
            if next > bounds.width, !lines[lines.count - 1].isEmpty {
                lines.append([index])
                used = width
            } else {
                lines[lines.count - 1].append(index)
                used = next
            }
        }
        var y: CGFloat = 0
        for line in lines where !line.isEmpty {
            let total = line.reduce(CGFloat(0)) { $0 + sizes[$1].width }
                + spacing * CGFloat(line.count - 1)
            var x = max(0, (bounds.width - total) / 2)
            let rowHeight = line.map { sizes[$0].height }.max() ?? 0
            for index in line {
                chips[index].frame = NSRect(
                    x: x, y: y + (rowHeight - sizes[index].height) / 2, width: sizes[index].width,
                    height: sizes[index].height)
                x += sizes[index].width + spacing
            }
            y += rowHeight + spacing
        }
        return max(0, y - spacing)
    }

    nonisolated override var isFlipped: Bool { true }
}
