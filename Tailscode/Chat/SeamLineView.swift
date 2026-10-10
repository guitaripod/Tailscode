import TailscodeCore
import UIKit

/// The one line a seam in the transcript is drawn as: a short rule, what happened, a quiet
/// chevron when it opens onto more, and a hairline carrying on to the edge. A compaction, a model
/// change and a turn picked back up after a restart all stand between the turns they separate,
/// so they share this component rather than three plates.
///
/// It is a 32-point row so a finger can hit it with the 24-point line inside, and the words wrap
/// and grow with Dynamic Type rather than clip.
final class SeamLineView: UIControl {
    private let leadRule = UIView()
    private let tailRule = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private let chevron = UIImageView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for rule in [leadRule, tailRule] {
            rule.backgroundColor = Theme.Color.separator
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        }
        leadRule.widthAnchor.constraint(equalToConstant: Theme.Spacing.l).isActive = true
        tailRule.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        tailRule.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = Theme.Ramp.font(.rowDetail)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        [leadRule, icon, label, chevron, tailRule].forEach(row.addArrangedSubview)
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: CGFloat(Theme.Chat.metrics.seamRowHeight)),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Draws one seam. `symbol` is the SF Symbol some seams lead with, `tint` the ink of the symbol
    /// and the words, and `tappable` whether the line opens onto more, which is what shows the
    /// chevron and what makes it a button to VoiceOver.
    func show(text: String, symbol: String?, tint: UIColor, tappable: Bool, spoken: String? = nil) {
        label.text = text
        label.textColor = tint
        icon.isHidden = symbol == nil
        icon.image = symbol.flatMap {
            UIImage(
                systemName: $0,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        }
        icon.tintColor = tint
        chevron.isHidden = !tappable
        isUserInteractionEnabled = tappable
        accessibilityLabel = spoken ?? text
        accessibilityTraits = tappable ? .button : .staticText
    }
}
