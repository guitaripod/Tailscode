import TailscodeCore
import UIKit

/// The face of a turn that finished having said nothing. It is a card rather than a bubble
/// because nothing was said — a bubble would be an empty quotation — and it holds perfectly
/// still, the way every settled state in this app does.
final class AnswerlessTurnCell: UICollectionViewCell {
    static let reuseID = "AnswerlessTurnCell"

    private let card = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let action = UIButton(type: .system)
    private var onAsk: (() -> Void)?

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
            systemName: AnswerlessTurn.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        icon.tintColor = AnswerlessTurn.tone.color
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

        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        action.configuration = config
        action.contentHorizontalAlignment = .leading
        action.addAction(UIAction { [weak self] _ in self?.ask() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [header, detailLabel, action])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.xs
        stack.setCustomSpacing(Theme.Spacing.s, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            card.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
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
        onAsk = nil
    }

    func configure(_ turn: AnswerlessTurn, onAsk: (() -> Void)?) {
        self.onAsk = onAsk
        titleLabel.text = turn.title
        detailLabel.text = turn.detail
        action.configuration?.title = turn.action
        action.isHidden = !turn.offersRemedy || onAsk == nil
        isAccessibilityElement = true
        accessibilityLabel = turn.spoken
        accessibilityTraits = .staticText
    }

    private func ask() {
        Theme.Haptics.send()
        onAsk?()
    }
}
