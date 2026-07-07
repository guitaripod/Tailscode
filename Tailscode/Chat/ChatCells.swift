import CodingAgentKit
import UIKit

struct ChatRow: Hashable {
    let id: String
    let messageID: String
    let role: MessageRole
    let content: Content

    enum Content: Hashable {
        case text(String)
        case reasoning(String)
        case tool(ToolCall)
        case file(FileReference)
    }
}

final class TextBubbleCell: UICollectionViewCell {
    static let reuseID = "TextBubbleCell"

    private let bubble = UIView()
    private let label = UILabel()
    private var leadingPin: NSLayoutConstraint!
    private var trailingPin: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = Theme.Radius.bubble
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = true
        contentView.addSubview(bubble)
        bubble.addSubview(label)

        leadingPin = bubble.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l)
        trailingPin = bubble.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l)

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Theme.Spacing.s),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Theme.Spacing.s),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Theme.Spacing.m),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, role: MessageRole, reasoning: Bool) {
        label.text = text
        let isUser = role == .user
        leadingPin.isActive = !isUser
        trailingPin.isActive = isUser

        if reasoning {
            bubble.backgroundColor = .clear
            label.textColor = Theme.Color.secondaryLabel
            label.font = UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitItalic)
        } else if isUser {
            bubble.backgroundColor = Theme.Color.userBubble
            label.textColor = .white
            label.font = Theme.Font.body()
        } else {
            bubble.backgroundColor = Theme.Color.assistantBubble
            label.textColor = Theme.Color.label
            label.font = Theme.Font.body()
        }
    }
}

final class ReasoningCell: UICollectionViewCell {
    static let reuseID = "ReasoningCell"

    private let container = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let chevron = UIImageView()
    private let bodyLabel = UILabel()
    private let toggle = UIButton(type: .system)
    private var bodyCollapsedConstraint: NSLayoutConstraint!
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.backgroundColor = Theme.Color.reasoningBackground
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = UIImage(
            systemName: "brain", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        iconView.tintColor = Theme.Color.accent
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "Thinking"
        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        titleLabel.textColor = Theme.Color.secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = UIImage(
            systemName: "chevron.down", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.numberOfLines = 0
        bodyLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        bodyLabel.textColor = Theme.Color.secondaryLabel
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

        contentView.addSubview(container)
        [iconView, titleLabel, chevron, bodyLabel, toggle].forEach(container.addSubview)

        bodyCollapsedConstraint = bodyLabel.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            container.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            container.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.9),

            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.m),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.Spacing.s),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: Theme.Spacing.s),
            chevron.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            chevron.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            bodyLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: Theme.Spacing.s),
            bodyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            bodyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            bodyLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Spacing.m),

            toggle.topAnchor.constraint(equalTo: container.topAnchor),
            toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toggle.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, expanded: Bool, streaming: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        bodyLabel.text = text
        titleLabel.text = streaming ? "Thinking…" : "Thought"
        bodyLabel.isHidden = !expanded
        bodyCollapsedConstraint.isActive = !expanded
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
    }

    @objc private func toggleTapped() {
        Theme.Haptics.tap()
        onToggle?()
    }
}

final class ToolCallCell: UICollectionViewCell {
    static let reuseID = "ToolCallCell"

    private let container = UIView()
    private let header = UILabel()
    private let output = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.backgroundColor = Theme.Color.secondaryBackground
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false

        header.font = .preferredFont(forTextStyle: .footnote)
        header.adjustsFontForContentSizeCategory = true
        header.numberOfLines = 1
        header.translatesAutoresizingMaskIntoConstraints = false

        output.font = Theme.Font.mono(12)
        output.textColor = Theme.Color.secondaryLabel
        output.numberOfLines = 10
        output.lineBreakMode = .byTruncatingTail
        output.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(container)
        container.addSubview(header)
        container.addSubview(output)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.s),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            output.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Theme.Spacing.xs),
            output.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            output.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            output.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Spacing.s),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(tool: ToolCall) {
        let symbol: String
        let color: UIColor
        switch tool.status {
        case .pending, .running: symbol = "gearshape.2"; color = Theme.Color.warning
        case .completed: symbol = "checkmark.circle.fill"; color = Theme.Color.success
        case .error: symbol = "xmark.circle.fill"; color = Theme.Color.danger
        }
        let title = tool.title ?? tool.name
        let attributed = NSMutableAttributedString(
            string: "\(tool.name)  ", attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote).withTraits(.traitBold)])
        attributed.append(NSAttributedString(
            string: tool.status.rawValue,
            attributes: [.foregroundColor: color, .font: UIFont.preferredFont(forTextStyle: .caption1)]))
        header.attributedText = attributed

        let body = tool.output ?? (title == tool.name ? "" : title)
        output.text = body
        output.isHidden = body.isEmpty
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
