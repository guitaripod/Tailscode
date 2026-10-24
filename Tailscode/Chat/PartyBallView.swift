import UIKit

/// The glass sphere a party card wears: a radial gradient lit from the upper left in the model's
/// house hue, a pale rim, and a small lit button at its centre that is the level when it is
/// pressed. A slot with nothing in it is the same shape, hollow, with a plus.
@MainActor
final class PartyBallView: UIView {
    static let filledDiameter: CGFloat = 44
    static let hollowDiameter: CGFloat = 34
    private static let buttonDiameter: CGFloat = 15

    var hue: UIColor? {
        didSet { paint() }
    }

    var isHollow = false {
        didSet {
            guard isHollow != oldValue else { return }
            invalidateIntrinsicContentSize()
            paint()
        }
    }

    private let gradient = CAGradientLayer()
    private let button = UIView()
    private let plus = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.type = .radial
        gradient.startPoint = CGPoint(x: 0.32, y: 0.26)
        gradient.endPoint = CGPoint(x: 1.05, y: 1.0)
        gradient.locations = [0, 0.5, 1]
        layer.addSublayer(gradient)
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 8
        layer.borderWidth = 1.5
        button.layer.borderWidth = 2
        button.layer.shadowOffset = .zero
        button.layer.shadowRadius = 5
        button.layer.shadowOpacity = 0.9
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        plus.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        plus.tintColor = Theme.Color.secondaryLabel
        plus.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plus)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: Self.buttonDiameter),
            button.heightAnchor.constraint(equalToConstant: Self.buttonDiameter),
            plus.centerXAnchor.constraint(equalTo: centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        button.layer.cornerRadius = Self.buttonDiameter / 2
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: PartyBallView, _) in view.paint()
        }
        paint()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let side = isHollow ? Self.hollowDiameter : Self.filledDiameter
        return CGSize(width: side, height: side)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        gradient.frame = bounds
        gradient.cornerRadius = bounds.width / 2
    }

    private func paint() {
        gradient.isHidden = isHollow
        button.isHidden = isHollow
        plus.isHidden = !isHollow
        guard !isHollow else {
            layer.borderColor = Theme.Color.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
            layer.shadowOpacity = 0
            return
        }
        let base = (hue ?? Theme.Color.tertiaryLabel).resolvedColor(with: traitCollection)
        gradient.colors = [
            Self.mixed(base, with: .white, 0.5).cgColor, base.cgColor,
            Self.mixed(base, with: .black, 0.38).cgColor,
        ]
        layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        layer.shadowColor = base.cgColor
        layer.shadowOpacity = 0.35
        button.backgroundColor = Self.mixed(base, with: .white, 0.72).withAlphaComponent(0.92)
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        button.layer.shadowColor = base.cgColor
    }

    /// `amount` of the way from `color` toward `other`, in sRGB, for the lit and shaded sides of
    /// the sphere.
    private static func mixed(_ color: UIColor, with other: UIColor, _ amount: CGFloat) -> UIColor {
        var from: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) = (0, 0, 0, 0)
        var to: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) = (0, 0, 0, 0)
        color.getRed(&from.r, green: &from.g, blue: &from.b, alpha: &from.a)
        other.getRed(&to.r, green: &to.g, blue: &to.b, alpha: &to.a)
        return UIColor(
            red: from.r + (to.r - from.r) * amount, green: from.g + (to.g - from.g) * amount,
            blue: from.b + (to.b - from.b) * amount, alpha: 1)
    }
}
