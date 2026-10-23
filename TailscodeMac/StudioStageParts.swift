import AppKit
import ImageIO
import TailscodeCore

/// A small label on a dark pill, over picture content: the sketch's caption and the drop target's
/// sentence. The fill is the scrim token, so the ink clears contrast over a bright sketch as well as
/// a dark one.
@MainActor
final class StudioPill: NSView {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            label.stringValue = text
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    private let label = StudioTheme.label(.panelFootnote, color: MacTheme.Color.label)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        addSubview(label)
        setAccessibilityElement(false)
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
            layer?.backgroundColor = StudioTheme.scrim.cgColor
        }
        label.font = MacTheme.Ramp.font(.panelFootnote)
    }

    override var fittingSize: NSSize {
        NSSize(
            width: ceil(label.intrinsicContentSize.width) + 28,
            height: StudioTheme.height(of: .panelFootnote) + 10)
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.frame = NSRect(x: 10, y: 5, width: max(0, bounds.width - 20), height: bounds.height - 10)
    }
}

/// The sentence that stands for a machine working out what it was asked: a glyph that breathes on the
/// shared swell while the wait is on, and the words Core wrote for it. It holds no state of its own —
/// the stage hands it a line, and it is perfectly still the moment `working` is false.
@MainActor
final class StudioStatusView: NSView {
    private let badge = ActivityBadgeView(pointSize: 26)
    private let line = StudioTheme.label(.cardTitle, color: MacTheme.Color.label, lines: 3, alignment: .center)

    init() {
        super.init(frame: .zero)
        addSubview(badge)
        addSubview(line)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(line words: String, working: Bool) {
        if line.stringValue != words {
            line.stringValue = words
            line.font = MacTheme.Ramp.font(.cardTitle)
            needsLayout = true
        }
        badge.activity = working ? .working : nil
        badge.isHidden = !working
    }

    func fitting(width: CGFloat) -> NSSize {
        let text = line.attributedStringValue.boundingRect(
            with: NSSize(width: max(40, width), height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let badgeHeight: CGFloat = badge.isHidden ? 0 : 36
        return NSSize(width: ceil(min(width, text.width + 8)), height: ceil(text.height) + badgeHeight + 4)
    }

    override func layout() {
        super.layout()
        let badgeHeight: CGFloat = badge.isHidden ? 0 : 36
        badge.frame = NSRect(x: (bounds.width - 36) / 2, y: 0, width: 36, height: badgeHeight)
        line.frame = NSRect(x: 0, y: badgeHeight + 2, width: bounds.width, height: bounds.height - badgeHeight - 2)
    }
}

/// One honest sentence in the failure tone, and the one thing that fixes it. It is the only thing on
/// the stage that is about a failure, and it holds perfectly still: nothing here is animated into
/// looking busy.
@MainActor
final class StudioFailureCard: StudioRaisedView {
    var onRemedy: ((StudioRemedy) -> Void)?
    private let icon = NSImageView()
    private let sentence = StudioTheme.label(.cardBody, color: MacTheme.Color.label, lines: 6)
    private let button = NSButton(title: "", target: nil, action: nil)
    private var remedy: StudioRemedy = .retry

    init() {
        super.init(radius: StudioTheme.stageRadius)
        icon.image = StudioTheme.symbol("exclamationmark.triangle.fill", size: 18, weight: .semibold)
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(sentence)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = #selector(pressed)
        button.keyEquivalent = ""
        button.bezelColor = MacTheme.Color.accent
        addSubview(button)
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
        icon.contentTintColor = MacTheme.Color.danger
        sentence.font = MacTheme.Ramp.font(.cardBody)
    }

    func show(reason: String, remedy: StudioRemedy) {
        self.remedy = remedy
        sentence.stringValue = reason
        button.title = remedy.title
        button.setAccessibilityLabel(remedy.title)
        setAccessibilityRole(.group)
        setAccessibilityLabel(reason)
        needsLayout = true
    }

    private static let pad: CGFloat = 20
    private static let iconSide: CGFloat = 26

    func fitting(width: CGFloat) -> NSSize {
        let textWidth = max(120, width - 2 * Self.pad - Self.iconSide - 12)
        let text = sentence.attributedStringValue.boundingRect(
            with: NSSize(width: textWidth, height: 600), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let buttonHeight: CGFloat = 28
        let height = 2 * Self.pad + ceil(text.height) + 14 + buttonHeight
        let usedWidth = min(width, ceil(text.width) + 2 * Self.pad + Self.iconSide + 12 + 4)
        return NSSize(width: max(usedWidth, min(width, 280)), height: height)
    }

    override func layout() {
        super.layout()
        let textWidth = bounds.width - 2 * Self.pad - Self.iconSide - 12
        let text = sentence.attributedStringValue.boundingRect(
            with: NSSize(width: textWidth, height: 600), options: [.usesLineFragmentOrigin, .usesFontLeading])
        icon.frame = NSRect(x: Self.pad, y: Self.pad - 2, width: Self.iconSide, height: Self.iconSide)
        sentence.frame = NSRect(
            x: Self.pad + Self.iconSide + 12, y: Self.pad, width: textWidth, height: ceil(text.height))
        let size = button.fittingSize
        button.frame = NSRect(
            x: Self.pad + Self.iconSide + 12, y: Self.pad + ceil(text.height) + 14, width: size.width,
            height: 28)
    }

    @objc private func pressed() { onRemedy?(remedy) }
}

/// The empty stage's invitation: one sentence about what the box is for and four worked examples,
/// each a brief that was actually rendered and came back right. A starter is the first half of a
/// sentence — it lands in the words box and the person finishes it; nothing is sent by touching one.
@MainActor
final class StudioInvitationView: NSView {
    static var examples: [ImageGenBrief.Example] { ImageGenBrief.examples }

    var onPick: ((ImageGenBrief.Example) -> Void)?
    private let title = StudioTheme.label(.headline, color: MacTheme.Color.label, lines: 2, alignment: .center)
    private let subtitle = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel, alignment: .center)
    private var cards: [StudioStarterCard] = []

    init() {
        super.init(frame: .zero)
        title.stringValue = Localized.text("Describe a picture, or drop one here to edit")
        subtitle.stringValue = Localized.text("Or start from one of these")
        addSubview(title)
        addSubview(subtitle)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ examples: [ImageGenBrief.Example]) {
        guard cards.count != examples.count else { return }
        for card in cards { card.removeFromSuperview() }
        cards = examples.map { example in
            let card = StudioStarterCard(example: example)
            card.onPress = { [weak self] in self?.onPick?(example) }
            addSubview(card)
            return card
        }
        needsLayout = true
    }

    private static let cardHeight: CGFloat = 60
    private static let gap: CGFloat = 12

    func fitting(width: CGFloat) -> NSSize {
        let columns = width >= 520 ? 2 : 1
        let rows = Int((Double(max(cards.count, 1)) / Double(columns)).rounded(.up))
        let titleHeight = StudioTheme.height(of: .headline) * 2
        let height =
            titleHeight + 6 + StudioTheme.height(of: .panelFootnote) + 22
            + CGFloat(rows) * Self.cardHeight + CGFloat(max(rows - 1, 0)) * Self.gap
        return NSSize(width: width, height: height)
    }

    override func layout() {
        super.layout()
        let titleHeight = StudioTheme.height(of: .headline) * 2
        let wrapped = title.attributedStringValue.boundingRect(
            with: NSSize(width: bounds.width, height: titleHeight), options: [.usesLineFragmentOrigin])
        let used = min(titleHeight, ceil(wrapped.height))
        title.frame = NSRect(x: 0, y: titleHeight - used, width: bounds.width, height: used)
        let subtitleY = titleHeight + 6
        subtitle.frame = NSRect(x: 0, y: subtitleY, width: bounds.width, height: StudioTheme.height(of: .panelFootnote))
        let columns = bounds.width >= 520 ? 2 : 1
        let cardWidth = (bounds.width - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)
        let top = subtitleY + StudioTheme.height(of: .panelFootnote) + 22
        for (index, card) in cards.enumerated() {
            let column = index % columns
            let row = index / columns
            card.frame = NSRect(
                x: CGFloat(column) * (cardWidth + Self.gap),
                y: top + CGFloat(row) * (Self.cardHeight + Self.gap), width: cardWidth,
                height: Self.cardHeight)
        }
    }
}

/// One worked example, as a raised card that answers the pointer before it is pressed.
@MainActor
final class StudioStarterCard: NSView {
    var onPress: (() -> Void)?
    private let plate = PointerPlate()
    private let glyph = NSImageView()
    private let title = StudioTheme.label(.rowTitleStrong, color: MacTheme.Color.label)
    private let detail = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private var tracking: NSTrackingArea?
    private var pressing = false

    init(example: ImageGenBrief.Example) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        plate.radius = 12
        addSubview(plate)
        glyph.image = StudioTheme.symbol(Self.symbol(for: example.id), size: 15, weight: .medium)
        glyph.imageScaling = .scaleProportionallyDown
        glyph.contentTintColor = MacTheme.Color.secondaryLabel
        addSubview(glyph)
        title.stringValue = example.title
        detail.stringValue = example.detail
        addSubview(title)
        addSubview(detail)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(example.title). \(example.detail)")
        toolTip = example.detail
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
        }
        layer?.borderWidth = 1
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        glyph.contentTintColor = MacTheme.Color.secondaryLabel
    }

    private static func symbol(for id: String) -> String {
        switch id {
        case "menu": return "textformat"
        case "portrait": return "scope"
        case "diagram": return "square.grid.3x3"
        case "cutout": return "scissors"
        default: return "photo"
        }
    }

    override func layout() {
        super.layout()
        plate.frame = bounds
        glyph.frame = NSRect(x: 14, y: (bounds.height - 28) / 2, width: 28, height: 28)
        let x: CGFloat = 54
        let width = bounds.width - x - 12
        let titleHeight = StudioTheme.height(of: .rowTitleStrong)
        let detailHeight = StudioTheme.height(of: .panelFootnote)
        let top = (bounds.height - titleHeight - detailHeight - 2) / 2
        title.frame = NSRect(x: x, y: top, width: width, height: titleHeight)
        detail.frame = NSRect(x: x, y: top + titleHeight + 2, width: width, height: detailHeight)
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

    override func mouseEntered(with event: NSEvent) { plate.show(.hover) }

    override func mouseExited(with event: NSEvent) {
        pressing = false
        plate.show(.rest)
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        plate.show(.press)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        plate.show(inside ? .hover : .rest)
        if pressing, inside { onPress?() }
        pressing = false
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
