import UIKit

/// A small pill on the card: Replay, Rows or Open. A finger is given a 44 point target however
/// small it is drawn.
@MainActor
final class CardButton: UIControl {
    var onTap: (() -> Void)?
    private let label = UILabel()
    private let icon = UIImageView()
    private var title = ""
    private var hasIcon = false
    private var compact = false
    private var isOn = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) { (view: CardButton, _) in view.traitsChanged() }
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        label.isUserInteractionEnabled = false
        label.adjustsFontForContentSizeCategory = true
        icon.contentMode = .center
        addSubview(icon)
        addSubview(label)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    func set(title new: String, symbol: String?, on: Bool, compact isCompact: Bool) {
        title = new
        hasIcon = symbol != nil
        isOn = on
        compact = isCompact
        let ink = on ? Theme.Color.accent : Theme.Color.label
        label.attributedText = NSAttributedString(
            string: new, attributes: Theme.Ramp.attributes(.control, color: ink))
        icon.image = symbol.flatMap { BrainCanvas.image($0, size: 9)?.withTintColor(ink, renderingMode: .alwaysOriginal) }
        icon.isHidden = symbol == nil
        layer.borderColor = (on ? Theme.Color.accent : Theme.Color.separator).resolvedColor(with: traitCollection).cgColor
        backgroundColor = on ? Theme.Color.accent.wash(0.14) : Theme.Color.background.wash(0.5)
        setNeedsLayout()
    }

    private func traitsChanged() {
        set(title: title, symbol: hasIcon ? "play.fill" : nil, on: isOn, compact: compact)
    }

    func fitted(height: CGFloat) -> CGSize {
        let text = label.attributedText?.size().width.rounded(.up) ?? 0
        return CGSize(width: 12 + (hasIcon ? 13 : 0) + text + 12, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = label.attributedText?.size() ?? .zero
        var x: CGFloat = 12
        if hasIcon {
            icon.frame = CGRect(x: 8, y: 0, width: 12, height: bounds.height)
            x = 21
        }
        label.frame = CGRect(
            x: x, y: (bounds.height - text.height) / 2, width: ceil(text.width) + 2,
            height: ceil(text.height))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        TouchSlop.area(of: bounds).contains(point)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isEnabled ? (isHighlighted ? 0.55 : 1) : 0.4 }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }
}
