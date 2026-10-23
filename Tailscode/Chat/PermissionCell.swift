import CodingAgentKit
import UIKit

/// An inline, in-stream approval card for a pending tool permission — replaces the blocking alert
/// so the decision reads next to the action it authorizes.
final class PermissionCell: UICollectionViewCell {
    static let reuseID = "PermissionCell"

    private let bar = Theme.Glass.view()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let allowButton = UIButton(type: .system)
    private let alwaysButton = UIButton(type: .system)
    private let denyButton = UIButton(type: .system)
    private let decisionButtons = UIStackView()
    private var onDecision: ((PermissionDecision) -> Void)?
    private var barTop: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = Theme.Radius.card
        bar.layer.cornerCurve = .continuous
        bar.clipsToBounds = true
        bar.isUserInteractionEnabled = false
        contentView.addSubview(bar)

        iconView.image = UIImage(
            systemName: "hand.raised.fill", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        iconView.tintColor = Theme.Color.warning
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.Ramp.font(.cardBody)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        configureButton(
            allowButton, title: String(localized: "Allow once"), tint: Theme.Color.accent,
            filled: true)
        configureButton(
            alwaysButton, title: String(localized: "Always"), tint: Theme.Color.accent, filled: false)
        configureButton(
            denyButton, title: String(localized: "Deny"), tint: Theme.Color.danger, filled: false)
        allowButton.addTarget(self, action: #selector(allowTapped), for: .touchUpInside)
        alwaysButton.addTarget(self, action: #selector(alwaysTapped), for: .touchUpInside)
        denyButton.addTarget(self, action: #selector(denyTapped), for: .touchUpInside)

        let buttons = decisionButtons
        [allowButton, alwaysButton, denyButton].forEach(buttons.addArrangedSubview)
        buttons.spacing = Theme.Spacing.s
        buttons.translatesAutoresizingMaskIntoConstraints = false
        arrangeDecisionButtons()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: PermissionCell, _) in cell.arrangeDecisionButtons()
        }

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(buttons)

        barTop = bar.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            barTop,
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            iconView.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
            iconView.topAnchor.constraint(equalTo: bar.topAnchor, constant: Theme.Spacing.m),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.Spacing.s),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.m),

            detailLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: Theme.Spacing.s),
            detailLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
            detailLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.m),

            buttons.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: Theme.Spacing.m),
            buttons.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.m),
            buttons.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -Theme.Spacing.m),
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchSlop.hit),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { barTop.constant = gapAbove }
    }

    /// Three decisions side by side while each has the width for its words, one under another when
    /// the reader's type is large enough that a word would be broken to fit.
    private func arrangeDecisionButtons() {
        let stacked = traitCollection.preferredContentSizeCategory >= .extraExtraLarge
        decisionButtons.axis = stacked ? .vertical : .horizontal
        decisionButtons.distribution = stacked ? .fill : .fillEqually
    }

    private func configureButton(_ button: UIButton, title: String, tint: UIColor, filled: Bool) {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        config.baseBackgroundColor = tint
        config.baseForegroundColor = filled ? Theme.Color.onAccent : tint
        config.cornerStyle = .large
        config.buttonSize = .medium
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    func configure(title: String, detail: String, onDecision: @escaping (PermissionDecision) -> Void) {
        titleLabel.text = title
        detailLabel.text = detail
        self.onDecision = onDecision
    }

    @objc private func allowTapped() { Theme.Haptics.success(); onDecision?(.once) }
    @objc private func alwaysTapped() { Theme.Haptics.success(); onDecision?(.always) }
    @objc private func denyTapped() { Theme.Haptics.warning(); onDecision?(.reject) }
}
