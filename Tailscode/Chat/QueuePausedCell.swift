import TailscodeCore
import UIKit

/// The note under a queue a Stop paused: nothing in it goes until the person resumes it. It is a
/// card of its own rather than a line of a queued row because the pause belongs to the queue, not
/// to any one message, and the press it offers acts on all of them.
final class QueuePausedCell: UICollectionViewCell {
    static let reuseID = "QueuePausedCell"

    private let card = UIView()
    private lazy var cardTop = card.topAnchor.constraint(equalTo: contentView.topAnchor)
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let resumeButton = UIButton(type: .system)
    private var onResume: (() -> Void)?

    var gapAbove: CGFloat = 0 {
        didSet { cardTop.constant = gapAbove }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        card.backgroundColor = Theme.Color.secondaryBackground
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Theme.Color.separator.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        icon.image = UIImage(
            systemName: SendQueueReading.heldSymbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        icon.tintColor = Theme.Color.secondaryLabel
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
        detailLabel.text = QueueReading.pausedHint

        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.title = QueueReading.resume
        resumeButton.configuration = config
        resumeButton.addAction(UIAction { [weak self] _ in self?.onResume?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [header, detailLabel, resumeButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.xs
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
        onResume = nil
    }

    func configure(count: Int, onResume: @escaping () -> Void) {
        self.onResume = onResume
        let line = QueueReading.pausedLine(count: count)
        titleLabel.text = line
        isAccessibilityElement = true
        accessibilityLabel = "\(line). \(QueueReading.pausedHint)"
        accessibilityTraits = .staticText
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: QueueReading.resume) { [weak self] _ in
                self?.onResume?()
                return true
            }
        ]
    }
}
