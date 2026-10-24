import UIKit

/// The five bars of a level, drawn the way the pill's meter draws them: the first `lit` in the
/// model's hue, the rest in a quiet ink.
@MainActor
final class PartyBarsView: UIView {
    private static let heights: [CGFloat] = [5, 7, 9, 11, 13]
    private static let width: CGFloat = 3
    private static let gap: CGFloat = 2

    var lit = 0 {
        didSet { setNeedsDisplay() }
    }

    var hue: UIColor? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: PartyBarsView, _) in view.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(Self.heights.count)
        return CGSize(
            width: count * Self.width + (count - 1) * Self.gap, height: Self.heights.last ?? 13)
    }

    override func draw(_ rect: CGRect) {
        let traits = traitCollection
        let unlit = UIColor.label.withAlphaComponent(0.17).resolvedColor(with: traits)
        let on = (hue ?? Theme.Color.tertiaryLabel).resolvedColor(with: traits)
        for (index, height) in Self.heights.enumerated() {
            let bar = CGRect(
                x: CGFloat(index) * (Self.width + Self.gap), y: bounds.maxY - height,
                width: Self.width, height: height)
            (index < lit ? on : unlit).setFill()
            UIBezierPath(roundedRect: bar, cornerRadius: Self.width / 2).fill()
        }
    }
}

/// A small capsule on a quiet fill: the machine a slot lives on, or a recent model to take.
@MainActor
final class PartyPillView: UIControl {
    private let dot = UIImageView()
    private let label = UILabel()

    init(font: UIFont, insets: UIEdgeInsets) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.tertiaryLabel.withAlphaComponent(0.2)
        label.font = font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        dot.isHidden = true
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.isUserInteractionEnabled = false
        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
        ])
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    var dotColor: UIColor? {
        didSet {
            dot.isHidden = dotColor == nil
            dot.image = dotColor.map { EffortMeterView.dotImage($0) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, 18)
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}
