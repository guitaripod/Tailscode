import TailscodeCore
import UIKit

/// A board of alternatives, offered where it was made. The letters are on the card because they
/// are what the reader picks by, and the whole card is the way in — a design reachable only through
/// a file path is a design nobody looks at.
final class DesignBoardCell: UICollectionViewCell {
    static let reuseID = "DesignBoardCell"

    private let card = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let letters = UIStackView()
    private let action = UIButton(type: .system)
    private var onOpen: (() -> Void)?

    var turnInset: CGFloat = 0 {
        didSet { topInset.constant = Theme.Spacing.xs + turnInset }
    }

    private lazy var topInset = card.topAnchor.constraint(
        equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)

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

        icon.contentMode = .scaleAspectFit
        icon.tintColor = Theme.Color.info
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

        letters.axis = .horizontal
        letters.spacing = Theme.Spacing.xs
        letters.alignment = .center

        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        action.configuration = config
        action.contentHorizontalAlignment = .leading
        action.addAction(UIAction { [weak self] _ in self?.open() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [header, detailLabel, letters, action])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.xs
        stack.setCustomSpacing(Theme.Spacing.s, after: letters)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            topInset,
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(cardTapped))
        card.addGestureRecognizer(tap)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onOpen = nil
        turnInset = 0
    }

    func configure(_ reading: DesignCardReading, onOpen: (() -> Void)?) {
        self.onOpen = onOpen
        icon.image = UIImage(
            systemName: reading.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        titleLabel.text = reading.title
        detailLabel.text = reading.detail
        detailLabel.lineBreakMode = .byTruncatingMiddle
        action.configuration?.title = reading.action
        letters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for letter in reading.letters { letters.addArrangedSubview(Self.chip(letter)) }
        letters.isHidden = reading.letters.isEmpty
        isAccessibilityElement = true
        accessibilityLabel = "\(reading.title). \(reading.detail)"
        accessibilityTraits = .button
    }

    private static func chip(_ letter: String) -> UIView {
        let label = UILabel()
        label.text = letter
        label.font = Theme.Ramp.font(.badge)
        label.textAlignment = .center
        label.textColor = Theme.Color.accent
        label.layer.borderColor = Theme.Color.accent.withAlphaComponent(0.6).cgColor
        label.layer.borderWidth = 1
        label.layer.cornerRadius = 5
        label.layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            label.heightAnchor.constraint(equalToConstant: 20),
        ])
        return label
    }

    @objc private func cardTapped() { open() }

    private func open() {
        Theme.Haptics.send()
        onOpen?()
    }
}
