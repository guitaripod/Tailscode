import TailscodeCore
import UIKit

/// How far a touch target may reach past what is drawn. A chip is 30 points tall and a finger is
/// not, so the target is outset to the chat chrome's hit size rather than the chip being drawn
/// taller.
enum TouchSlop {
    static var hit: CGFloat { CGFloat(ChatChrome.chip(on: .touch).hit) }

    static func area(of bounds: CGRect, minimum: CGFloat = TouchSlop.hit) -> CGRect {
        bounds.insetBy(
            dx: -max(0, (minimum - bounds.width) / 2), dy: -max(0, (minimum - bounds.height) / 2))
    }

    static func clamped(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 0.5),
            y: min(max(point.y, bounds.minY), bounds.maxY - 0.5))
    }
}

/// A button whose touch target is at least a finger wide however small it is drawn.
class SlopButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: bounds).contains(point)
    }
}

/// One chip of the chat's chrome, drawn from `ChatChrome`: a capsule with a 12-point glyph, one
/// type role, an opaque fill and a 44-point target.
///
/// The fill is the canvas with a share of the ink mixed in, never a translucent grey, so the
/// transcript passing under the row cannot print through the chip. Tone is carried on the glyph
/// alone; the words stay in the theme's ink. A control is outlined and a fact is not.
@MainActor
final class ChatChip: UIControl {
    let kind: ChatChrome.Kind
    private let metrics = ChatChrome.chip(on: .touch)
    private let iconView = UIImageView()
    private let badge = ActivityBadgeView(pointSize: 12)
    private let label = UILabel()
    private let content = UIStackView()
    private var shownImage: UIImage?
    private var shownSymbol: String?
    private var shownTone: ActivityTone = .quiet
    private var shownLive: ActivityIcon?
    private var labelCeiling = NSLayoutConstraint()
    private var heldWidth = NSLayoutConstraint()
    private var iconSlot: NSLayoutConstraint?
    private(set) var needsMeasure = true

    init(kind: ChatChrome.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var text: String? {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            label.text = newValue
            needsMeasure = true
        }
    }

    override var isHidden: Bool {
        didSet { if oldValue, !isHidden { needsMeasure = true } }
    }

    /// The width this chip's words ask for with no minimum on it, which is what the row's slots
    /// record: measured from the content stack so the held width it is given cannot feed back into
    /// what it measures.
    var naturalWidth: CGFloat {
        needsMeasure = false
        let fitted = content.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize, withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel)
        return ceil(fitted.width) + CGFloat(metrics.padding) * 2
    }

    func setNeedsMeasure() { needsMeasure = true }

    /// The least this chip is wide, so it keeps the room of the widest it has been.
    func hold(_ width: CGFloat) {
        guard heldWidth.constant != width else { return }
        heldWidth.constant = width
    }

    /// Keeps the icon's room whether or not the picture in it is the widest, so a ring that gives
    /// way to a symbol, or the other way round, leaves the words where they were.
    func reserveIcon(symbols: [String], minimum: CGFloat) {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: CGFloat(metrics.iconSize), weight: .semibold)
        let widest = symbols.compactMap {
            UIImage(systemName: $0, withConfiguration: configuration)?.size.width
        }.max() ?? 0
        iconSlot?.isActive = false
        iconSlot = iconView.widthAnchor.constraint(equalToConstant: ceil(max(widest, minimum)))
        iconSlot?.isActive = true
        needsMeasure = true
    }

    /// The most of `reference`'s width the words may take before they truncate, for a chip whose
    /// text is a sentence: a share of the room there is rather than a number of points, so a wide
    /// window gives it more and a narrow one less.
    func limitText(toShareOf reference: UIView, share: CGFloat) {
        labelCeiling.isActive = false
        labelCeiling = label.widthAnchor.constraint(
            lessThanOrEqualTo: reference.widthAnchor, multiplier: share)
        labelCeiling.isActive = true
    }

    var textColor: UIColor {
        get { label.textColor }
        set { label.textColor = newValue }
    }

    /// An SF Symbol at the chip's icon size, its colour the tone's.
    func setSymbol(_ name: String?, tone: ActivityTone = .quiet) {
        shownSymbol = name
        shownTone = tone
        shownImage = nil
        shownLive = nil
        needsMeasure = true
        badge.show(nil, spoken: nil)
        iconView.image = name.flatMap {
            UIImage(
                systemName: $0,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: CGFloat(metrics.iconSize), weight: .semibold))
        }
        iconView.tintColor = Self.glyphColor(kind, tone: tone)
        iconView.isHidden = name == nil
    }

    /// A drawn glyph that carries its own colour, such as the context ring.
    func setImage(_ image: UIImage?) {
        shownImage = image
        shownSymbol = nil
        shownLive = nil
        needsMeasure = true
        badge.show(nil, spoken: nil)
        iconView.image = image
        iconView.isHidden = image == nil
    }

    /// The vocabulary's own mark for work in flight, which breathes unless the reader has asked
    /// for less movement.
    func setLive(_ icon: ActivityIcon?) {
        guard icon != shownLive else { return }
        shownLive = icon
        shownSymbol = nil
        shownImage = nil
        needsMeasure = true
        iconView.image = nil
        iconView.isHidden = true
        badge.show(icon, spoken: nil)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.5 }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: bounds).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    private func build() {
        let fill = ChatChrome.fill(kind)
        backgroundColor = Self.fillColor(share: fill.inkShare)
        layer.cornerCurve = .continuous
        if fill.outlined {
            layer.borderWidth = 1
            layer.borderColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        }

        label.font = Theme.Ramp.font(ChatChrome.chipRole)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = kind == .fact ? Theme.Color.secondaryLabel : Theme.Color.label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(UILayoutPriority(999), for: .horizontal)

        iconView.contentMode = .center
        iconView.isHidden = true
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        content.axis = .horizontal
        content.alignment = .center
        content.spacing = CGFloat(metrics.iconGap)
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        [iconView, badge, label].forEach(content.addArrangedSubview)
        addSubview(content)

        let height = heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(metrics.height))
        heldWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        NSLayoutConstraint.activate([
            height, heldWidth,
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: CGFloat(metrics.padding)),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -CGFloat(metrics.padding)),
            content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 5),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (chip: ChatChip, _) in
            chip.backgroundColor = Self.fillColor(share: ChatChrome.fill(chip.kind).inkShare)
            if ChatChrome.fill(chip.kind).outlined {
                chip.layer.borderColor =
                    Theme.Color.separator.resolvedColor(with: chip.traitCollection).cgColor
            }
            chip.iconView.tintColor = Self.glyphColor(chip.kind, tone: chip.shownTone)
        }
    }

    /// The canvas with a share of the ink mixed in, resolved for whichever theme and face is
    /// showing, so it is one opaque colour.
    static func fillColor(share: Double) -> UIColor {
        UIColor { traits in
            let canvas = Theme.Color.background.resolvedColor(with: traits)
            let ink = Theme.Color.label.resolvedColor(with: traits)
            return ink.withAlphaComponent(CGFloat(share)).blended(over: canvas, traits: traits)
        }
    }

    private static func glyphColor(_ kind: ChatChrome.Kind, tone: ActivityTone) -> UIColor {
        let resolved = ChatChrome.glyphTone(kind, tone: tone)
        return resolved == .quiet ? Theme.Color.secondaryLabel : resolved.color
    }
}

/// The facts row: the chips that say what is true of the conversation, in one line that scrolls
/// sideways before it would ever wrap, hidden when it has nothing to say.
@MainActor
final class ChatFactsRow: UIView {
    private let scroll = FactsScrollView()
    private let stack = UIStackView()
    private let chips: [ChatChip]
    private weak var bleedHost: UIView?
    private var scrollLeading = NSLayoutConstraint()
    private var scrollTrailing = NSLayoutConstraint()
    private var slots = StatusBandSlots()

    init(chips: [ChatChip]) {
        self.chips = chips
        super.init(frame: .zero)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = CGFloat(ChatChrome.chip(on: .touch).spacing)
        stack.translatesAutoresizingMaskIntoConstraints = false
        chips.forEach {
            $0.isHidden = true
            stack.addArrangedSubview($0)
        }
        scroll.addSubview(stack)
        addSubview(scroll)
        scrollLeading = scroll.leadingAnchor.constraint(equalTo: leadingAnchor)
        scrollTrailing = scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollLeading, scrollTrailing,
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scroll.frameLayoutGuide.heightAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.heightAnchor),
        ])
        isHidden = true
        accessibilityContainerType = .semanticGroup
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (row: ChatFactsRow, _) in row.resetSlots()
        }
    }

    /// A different type size is a different set of widths, so what was held at the old one is
    /// forgotten and every chip is measured again. A new conversation is a new view controller and
    /// so a new row, which is the other way the slots start over.
    private func resetSlots() {
        slots.reset()
        chips.forEach {
            $0.hold(0)
            $0.setNeedsMeasure()
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Lets the chips scroll edge to edge: the scroll view takes the whole width of `host` and the
    /// room between the row and each edge becomes content inset, so the first chip rests where the
    /// row starts and a scrolled chip leaves at the screen's edge rather than being cut off in the
    /// middle of the page.
    func bleed(to host: UIView) {
        bleedHost = host
        scrollLeading.isActive = false
        scrollTrailing.isActive = false
        scrollLeading = scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor)
        scrollTrailing = scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        NSLayoutConstraint.activate([scrollLeading, scrollTrailing])
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let host = bleedHost, bounds.width > 0 else { return }
        let left = max(0, convert(CGPoint.zero, to: host).x - host.bounds.minX)
        let right = max(0, host.bounds.width - left - bounds.width)
        let inset = scroll.contentInset
        guard abs(inset.left - left) > 0.5 || abs(inset.right - right) > 0.5 else { return }
        let atStart = scroll.contentOffset.x <= -inset.left + 0.5
        scroll.contentInset = UIEdgeInsets(top: 0, left: left, bottom: 0, right: right)
        if atStart { scroll.contentOffset.x = -left }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: scroll.frame).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
            self.point(inside: point, with: event)
        else { return nil }
        let inner = scroll.frame.contains(point) ? point : TouchSlop.clamped(point, in: scroll.frame)
        return scroll.hitTest(convert(inner, to: scroll), with: event)
    }

    /// Whether any chip has something to say, and so whether the row takes room at all.
    var hasContent: Bool { chips.contains { !$0.isHidden } }

    /// Each chip keeps the room of the widest it has been, as a minimum: the row scrolls, so a
    /// chip that grows costs the ones after it a nudge once and never a reflow of the ones before.
    private func holdWidths() {
        let row = bounds.width > 0 ? Double(bounds.width) : nil
        for (index, chip) in chips.enumerated() where !chip.isHidden && chip.needsMeasure {
            let id = String(index)
            slots.widen(id, to: Double(chip.naturalWidth), in: row)
            chip.hold(CGFloat(slots.width(of: id, in: row)))
        }
    }

    func refresh() {
        holdWidths()
        let show = hasContent
        guard isHidden == show else { return }
        isHidden = !show
    }
}

private final class FactsScrollView: UIScrollView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: bounds).contains(point)
    }
}

/// Canvas fading to clear, laid behind the facts row so transcript text that scrolls toward the
/// chips fades out before it reaches them, with solid canvas under the row itself.
@MainActor
final class FadeScrimView: UIView {
    private let gradient = CAGradientLayer()
    private let fade: CGFloat

    init(fade: CGFloat) {
        self.fade = fade
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        paint()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: FadeScrimView, _) in view.paint()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        let share = bounds.height > 0 ? min(1, Double(fade / bounds.height)) : 0
        gradient.locations = [0, NSNumber(value: share), 1]
        CATransaction.commit()
    }

    private func paint() {
        let canvas = Theme.Color.background.resolvedColor(with: traitCollection)
        gradient.colors = [
            canvas.withAlphaComponent(0).cgColor, canvas.cgColor, canvas.cgColor,
        ]
    }
}
