import TailscodeCore
import UIKit

/// The face of a turn that stopped with an error. It is a card rather than a red bubble because
/// what the server said is evidence, not an answer: the words are quoted in the code face, the
/// card holds perfectly still, and the one thing worth trying is a button that sends the prompt
/// again.
final class FailedTurnCell: UICollectionViewCell {
    static let reuseID = "FailedTurnCell"

    private let card = UIView()
    private lazy var cardTop = card.topAnchor.constraint(equalTo: contentView.topAnchor)

    var gapAbove: CGFloat = 0 {
        didSet { cardTop.constant = gapAbove }
    }
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let reasonLabel = UILabel()
    private let action = SlopButton(type: .system)
    private var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        card.backgroundColor = Theme.Color.secondaryBackground
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        icon.image = UIImage(
            systemName: FailedTurn.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        icon.tintColor = FailedTurn.tone.color
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0

        let header = UIStackView(arrangedSubviews: [icon, titleLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = Theme.Spacing.s

        detailLabel.font = Theme.Ramp.font(.panelDetail)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0

        reasonLabel.font = Theme.Ramp.font(.code)
        reasonLabel.adjustsFontForContentSizeCategory = true
        reasonLabel.textColor = Theme.Color.label
        reasonLabel.numberOfLines = 0

        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        action.configuration = config
        action.contentHorizontalAlignment = .leading
        action.addAction(UIAction { [weak self] _ in self?.retry() }, for: .touchUpInside)
        action.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchSlop.hit).isActive = true

        let stack = UIStackView(arrangedSubviews: [header, detailLabel, reasonLabel, action])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.xs
        stack.setCustomSpacing(Theme.Spacing.s, after: reasonLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            cardTop,
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            card.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetry = nil
    }

    func configure(_ turn: FailedTurn, onRetry: (() -> Void)?) {
        self.onRetry = onRetry
        titleLabel.text = turn.title
        detailLabel.text = turn.detail
        reasonLabel.text = turn.reason
        action.configuration?.title = turn.action
        action.isHidden = !turn.offersRemedy || onRetry == nil
        isAccessibilityElement = true
        accessibilityLabel = turn.spoken
        accessibilityTraits = .staticText
        accessibilityCustomActions = action.isHidden ? [] : [retryAction(turn.action)]
    }

    /// The card's one button as a VoiceOver action: the card reads as one element, which hides
    /// the button inside it, so the press is handed to the rotor instead.
    private func retryAction(_ title: String) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: title) { [weak self] _ in
            self?.retry()
            return true
        }
    }

    private func retry() {
        Theme.Haptics.send()
        onRetry?()
    }
}
