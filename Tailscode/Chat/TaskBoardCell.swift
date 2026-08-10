import TailscodeCore
import UIKit

/// The agent's plan as one card: done struck through and quiet, the task it is on now in the
/// accent wearing its present-tense wording, what is still ahead dim, headed by the same line
/// the band would wear. The card is the fold of the whole transcript (``TaskBoard``), placed at
/// the last call that moved the list.
final class TaskBoardCell: UICollectionViewCell {
    static let reuseID = "TaskBoardCell"

    private let card = UIView()
    private let header = UILabel()
    private let stack = UIStackView()
    private var cardTop: NSLayoutConstraint!

    var turnInset: CGFloat = 0 {
        didSet { cardTop.constant = Theme.Spacing.xs + turnInset }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = Theme.Color.assistantBubble
        card.layer.cornerRadius = Theme.Radius.bubble
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        header.font = Theme.Ramp.font(.sectionLabel)
        header.adjustsFontForContentSizeCategory = true
        header.textColor = Theme.Color.accent
        header.numberOfLines = 0
        header.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(card)
        card.addSubview(header)
        card.addSubview(stack)
        cardTop = card.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            cardTop,
            card.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            card.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.s),
            card.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.m),
            header.leadingAnchor.constraint(
                equalTo: card.leadingAnchor, constant: Theme.Spacing.m),
            header.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -Theme.Spacing.m),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Theme.Spacing.s),
            stack.leadingAnchor.constraint(
                equalTo: card.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -Theme.Spacing.m),
            stack.bottomAnchor.constraint(
                equalTo: card.bottomAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ board: TaskBoard) {
        header.text = board.headline
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in board.items {
            stack.addArrangedSubview(Self.row(item))
        }
        accessibilityLabel = String(localized: "Task list")
        accessibilityValue = board.headline
    }

    private static func row(_ item: TaskBoard.Item) -> UIView {
        let symbol: String
        let tint: UIColor
        switch item.status {
        case .completed: symbol = "checkmark.circle.fill"; tint = Theme.Color.success
        case .inProgress: symbol = "circle.lefthalf.filled"; tint = Theme.Color.accent
        case .pending: symbol = "circle"; tint = Theme.Color.tertiaryLabel
        }
        let label = UILabel()
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        let attributed = NSMutableAttributedString()
        if let image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
        {
            attributed.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
        }
        let done = item.status == .completed
        let text = item.status == .inProgress ? (item.activeForm ?? item.subject) : item.subject
        var attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.Ramp.font(.panelDetail),
            .foregroundColor: done ? Theme.Color.tertiaryLabel : Theme.Color.label,
        ]
        if done { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        attributed.append(NSAttributedString(string: "  \(text)", attributes: attrs))
        label.attributedText = attributed
        return label
    }
}
