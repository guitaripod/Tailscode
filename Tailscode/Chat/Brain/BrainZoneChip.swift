import TailscodeCore
import UIKit

/// A zone as a small capsule: its node shape in the zone's colour, its word where there is room,
/// its count. On the card a chip opens the brain diving into that zone; in the filter row it turns
/// the zone's filter on and off. SAID is the one chip that is never without its word and wears the
/// accent, because the agent's own voice is the thing a person looks for.
@MainActor
final class BrainZoneChip: UIControl {
    struct Content: Equatable {
        var zone: NeuralZone
        var count: Int
        var tone: NeuralNodeTone
        var showsWord: Bool
        var isOn: Bool
        var word: String
        var numberOnly = false
    }

    private let icon = BrainShapeIcon()
    private let label = UILabel()
    private var content: Content?
    private let height: CGFloat

    init(height: CGFloat = 28) {
        self.height = height
        super.init(frame: .zero)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) { (view: BrainZoneChip, _) in view.traitsChanged() }
        layer.cornerRadius = height / 2
        layer.borderWidth = 1
        layer.cornerCurve = .continuous
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = false
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byClipping
        addSubview(icon)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var onTap: (() -> Void)?
    var onSolo: (() -> Void)?

    @objc private func tapped() {
        Theme.Haptics.selection()
        onTap?()
    }

    private static let padding: CGFloat = 7
    private static let gap: CGFloat = 3
    private static let iconSize: CGFloat = 13

    func configure(_ new: Content) {
        guard content != new else { return }
        content = new
        let zoneInk = BrainCanvas.nodeTone(new.tone, zone: new.zone)
        let said = new.zone == .say
        icon.set(shape: new.zone.shape, color: zoneInk)
        let ink: UIColor = said ? Theme.Color.accent : Theme.Color.label
        let text = NSMutableAttributedString()
        if new.showsWord, !new.word.isEmpty {
            text.append(
                NSAttributedString(
                    string: new.word + " ",
                    attributes: Theme.Ramp.attributes(
                        .chip, color: said ? Theme.Color.accent : Theme.Color.secondaryLabel)))
        }
        text.append(
            NSAttributedString(
                string: String(new.count),
                attributes: Theme.Ramp.attributes(.chip, color: ink)))
        label.attributedText = text
        let border: UIColor = said ? Theme.Color.accent.wash(0.65) : Theme.Color.separator
        layer.borderColor = border.resolvedColor(with: traitCollection).cgColor
        backgroundColor = new.isOn ? Theme.Color.accent.wash(0.16) : .clear
        if new.isOn {
            layer.borderColor = Theme.Color.accent.resolvedColor(with: traitCollection).cgColor
        }
        accessibilityLabel = Localized.text("%1$@, %2$lld steps", new.zone.displayLabel, new.count)
        accessibilityTraits = new.isOn ? [.button, .selected] : .button
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func traitsChanged() {
        guard let current = content else { return }
        content = nil
        configure(current)
    }

    override var intrinsicContentSize: CGSize {
        let text = label.attributedText?.size().width.rounded(.up) ?? 0
        return CGSize(
            width: Self.padding + Self.iconSize + Self.gap + text + Self.padding, height: height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(
            x: Self.padding - 2, y: (bounds.height - Self.iconSize - 4) / 2,
            width: Self.iconSize + 4, height: Self.iconSize + 4)
        let text = label.attributedText?.size() ?? .zero
        label.frame = CGRect(
            x: Self.padding + Self.iconSize + Self.gap - 1, y: (bounds.height - text.height) / 2,
            width: ceil(text.width) + 2, height: ceil(text.height))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: bounds).contains(point)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}
