import CodingAgentKit
import TailscodeCore
import UIKit

/// One spawned agent, as it appears inside the conversation that spawned it:
/// a card at the exact point of the Task call, expandable in place. A subagent
/// is a branch of this conversation, not a conversation of its own, so it never
/// gets a screen of its own to be lost behind.
struct SubagentCard: Hashable {
    let agentID: String
    let title: String
    let agentType: String?
    let isActive: Bool
    let isCompleted: Bool
    let updatedAt: Date
    let expanded: Bool
    let isLoading: Bool
    let steps: [ActivityStep]
    let report: String?
    /// One line of live progress — todo position or tool trail — while the agent works.
    var progress: String?
    /// What the spawning tool call recorded as the agent's answer. Already in
    /// the parent transcript, so a finished card can say what came back before
    /// anyone asks for the agent's own transcript.
    var spawnSummary: String?

    var answer: String? {
        let text = report ?? spawnSummary
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    var statusText: String {
        if isActive {
            if let progress, !progress.isEmpty { return progress }
            return String(localized: "Working")
        }
        if isCompleted {
            return String(
                localized: "Finished \(updatedAt.formatted(.relative(presentation: .named)))")
        }
        return String(
            localized: "Idle since \(updatedAt.formatted(.relative(presentation: .named)))")
    }

    var statusColor: UIColor {
        if isActive { return Theme.Color.success }
        if isCompleted { return Theme.Color.secondaryLabel }
        return Theme.Color.tertiaryLabel
    }

    /// What the card says about the work when collapsed: the tools it has
    /// reached for so far, so a running agent is legible without opening it.
    var stepSummary: String? {
        guard !steps.isEmpty else { return nil }
        var names: [String] = []
        var thoughts = 0
        for step in steps {
            switch step {
            case .tool(let call): if !names.contains(call.name) { names.append(call.name) }
            case .reasoning: thoughts += 1
            }
        }
        var parts = [String(localized: "\(steps.count) steps")]
        if !names.isEmpty {
            let shown = names.prefix(3).joined(separator: " · ")
            parts.append(names.count > 3 ? "\(shown) +\(names.count - 3)" : shown)
        } else if thoughts > 0 {
            parts.append(String(localized: "thinking"))
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// A fan-out too wide to read card by card. A workflow run can spawn a hundred
/// agents; they still belong to this conversation, so they collapse behind one
/// row here rather than being moved somewhere else or flooding the transcript.
struct SubagentGroup: Hashable {
    let id: String
    let total: Int
    let live: Int
    let expanded: Bool

    var title: String { String(localized: "\(total) agents") }

    var detail: String {
        live > 0
            ? String(localized: "\(live) working · tap to see them all")
            : String(localized: "tap to see them all")
    }
}

final class SubagentGroupCell: UICollectionViewCell {
    static let reuseID = "SubagentGroupCell"

    private let container = UIView()
    private let rail = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let mark = ActivityBadgeView(pointSize: 11)
    private let chevron = UIImageView()
    private let toggle = UIButton(type: .system)
    private var onToggle: (() -> Void)?
    private var containerTop: NSLayoutConstraint!

    /// Extra gap above the card when this row opens a new turn.
    var turnInset: CGFloat = 0 {
        didSet { containerTop.constant = Theme.Spacing.xs + turnInset }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let glass = Theme.Glass.view()
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)

        rail.backgroundColor = Theme.Color.accent
        rail.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = UIImage(
            systemName: "square.stack.3d.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        iconView.tintColor = Theme.Color.accent
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = Theme.Ramp.font(.rowDetail)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.adjustsFontForContentSizeCategory = true

        chevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let column = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        column.axis = .vertical
        column.spacing = 2
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

        contentView.addSubview(container)
        [rail, iconView, column, mark, chevron, toggle].forEach(container.addSubview)
        mark.translatesAutoresizingMaskIntoConstraints = false

        containerTop = container.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            containerTop,
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            container.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l + Theme.Spacing.m),
            container.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            rail.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rail.topAnchor.constraint(equalTo: container.topAnchor),
            rail.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 3),

            iconView.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: Theme.Spacing.m),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            column.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.Spacing.s),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Spacing.m),

            mark.leadingAnchor.constraint(greaterThanOrEqualTo: column.trailingAnchor, constant: Theme.Spacing.s),
            mark.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: Theme.Spacing.s),
            chevron.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            chevron.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),

            toggle.topAnchor.constraint(equalTo: container.topAnchor),
            toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toggle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ group: SubagentGroup, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        titleLabel.text = group.title
        detailLabel.text = group.expanded ? String(localized: "tap to collapse") : group.detail
        rail.backgroundColor = group.live > 0 ? Theme.Color.success : Theme.Color.accent
        iconView.tintColor = group.live > 0 ? Theme.Color.success : Theme.Color.accent
        mark.show(group.live > 0 ? .openWork : nil, spoken: nil)
        chevron.transform = group.expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        toggle.accessibilityLabel = "\(group.title), \(group.detail)"
        toggle.accessibilityValue =
            group.expanded ? String(localized: "Expanded") : String(localized: "Collapsed")
    }

    @objc private func toggleTapped() {
        Theme.Haptics.selection()
        onToggle?()
    }
}

final class SubagentCardCell: UICollectionViewCell {
    static let reuseID = "SubagentCardCell"

    private let container = UIView()
    private let rail = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let typeBadge = PaddedLabel()
    private let statusLabel = UILabel()
    private let statusDot = UIView()
    private let mark = ActivityBadgeView(pointSize: 11)
    private let chevron = UIImageView()
    private let previewLabel = UILabel()
    private let stack = UIStackView()
    private let toggle = UIButton(type: .system)
    private let renderer = ToolStepRenderer()
    private var onToggle: (() -> Void)?
    private var containerTop: NSLayoutConstraint!

    /// Extra gap above the card when this row opens a new turn.
    var turnInset: CGFloat = 0 {
        didSet { containerTop.constant = Theme.Spacing.xs + turnInset }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let glass = Theme.Glass.view()
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)

        rail.backgroundColor = Theme.Color.accent
        rail.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = UIImage(
            systemName: "point.3.connected.trianglepath.dotted",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        iconView.tintColor = Theme.Color.accent
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        typeBadge.font = Theme.Ramp.font(.pill)
        typeBadge.textColor = Theme.Color.accent
        typeBadge.backgroundColor = Theme.Color.accent.withAlphaComponent(0.12)
        typeBadge.layer.cornerRadius = 5
        typeBadge.layer.cornerCurve = .continuous
        typeBadge.clipsToBounds = true
        typeBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        typeBadge.setContentHuggingPriority(.required, for: .horizontal)

        statusDot.layer.cornerRadius = 3
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = Theme.Ramp.font(.rowDetail)
        statusLabel.adjustsFontForContentSizeCategory = true

        chevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        previewLabel.font = Theme.Ramp.font(.cardBody)
        previewLabel.textColor = Theme.Color.secondaryLabel
        previewLabel.numberOfLines = 2

        let statusRow = UIStackView(arrangedSubviews: [
            statusDot, statusLabel, typeBadge, mark, UIView(),
        ])
        statusRow.axis = .horizontal
        statusRow.spacing = Theme.Spacing.xs
        statusRow.alignment = .center

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.isUserInteractionEnabled = false

        let column = UIStackView(arrangedSubviews: [titleLabel, statusRow, previewLabel, stack])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(toggleTapped(_:event:)), for: .touchUpInside)

        contentView.addSubview(container)
        [rail, iconView, column, chevron, toggle].forEach(container.addSubview)

        containerTop = container.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            containerTop,
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            container.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l + Theme.Spacing.m),
            container.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            rail.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rail.topAnchor.constraint(equalTo: container.topAnchor),
            rail.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 3),

            iconView.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: Theme.Spacing.m),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.m),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            column.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.Spacing.s),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -Theme.Spacing.s),

            chevron.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            chevron.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),

            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),

            toggle.topAnchor.constraint(equalTo: container.topAnchor),
            toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toggle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        _ card: SubagentCard, onToggle: @escaping () -> Void,
        onLinkTap: ((URL) -> Void)? = nil
    ) {
        self.onToggle = onToggle
        renderer.onLinkTap = onLinkTap
        renderer.onToolTap = nil

        titleLabel.text = card.title
        statusLabel.text = card.statusText
        statusLabel.textColor = card.statusColor
        statusDot.backgroundColor = card.statusColor
        rail.backgroundColor = card.isActive ? Theme.Color.success : Theme.Color.accent
        iconView.tintColor = card.isActive ? Theme.Color.success : Theme.Color.accent
        if let type = card.agentType, !type.isEmpty {
            typeBadge.text = type
            typeBadge.isHidden = false
        } else {
            typeBadge.isHidden = true
        }
        mark.show(card.isActive && !card.expanded ? .openWork : nil, spoken: nil)
        chevron.transform = card.expanded ? CGAffineTransform(rotationAngle: .pi) : .identity

        let preview = Self.collapsedPreview(card)
        previewLabel.text = preview
        previewLabel.isHidden = card.expanded || preview == nil

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.isHidden = !card.expanded
        renderer.reset()
        if card.expanded {
            if card.isLoading && card.steps.isEmpty {
                stack.addArrangedSubview(Self.loadingRow())
            }
            for step in card.steps { stack.addArrangedSubview(renderer.view(for: step)) }
            if let answer = card.answer {
                stack.addArrangedSubview(Self.reportView(answer))
            } else if !card.isLoading && card.steps.isEmpty {
                stack.addArrangedSubview(
                    ToolStepRenderer.pathLabel(
                        String(localized: "This agent has not written anything yet.")))
            }
        }

        isAccessibilityElement = false
        toggle.accessibilityLabel = String(localized: "Agent: \(card.title)")
        toggle.accessibilityValue =
            "\(card.statusText). "
            + (card.expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
        toggle.accessibilityHint = card.expanded
            ? String(localized: "Double tap to hide this agent's work")
            : String(localized: "Double tap to show this agent's work")
    }

    /// Collapsed, the card answers "what is it doing / what did it find" — the
    /// live tool trail while it runs, what it reported once it is done.
    private static func collapsedPreview(_ card: SubagentCard) -> String? {
        if card.isActive { return card.stepSummary ?? String(localized: "Working on it…") }
        guard let answer = card.answer else { return card.stepSummary }
        return answer
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadingRow() -> UIView {
        let mark = ActivityBadgeView(pointSize: 11)
        mark.show(.openWork, spoken: nil)
        let label = ToolStepRenderer.pathLabel(
            String(localized: "Loading this agent's transcript…"))
        let row = UIStackView(arrangedSubviews: [mark, label, UIView()])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .center
        return row
    }

    /// The agent's answer to the parent — the one part of a subagent run the
    /// parent conversation actually consumed, so it is set apart from the steps
    /// and rendered as prose and code the way any other message would be.
    private static func reportView(_ report: String) -> UIView {
        let heading = UILabel()
        heading.font = Theme.Ramp.font(.sectionLabel)
        heading.textColor = Theme.Color.tertiaryLabel
        heading.text = String(localized: "REPORTED BACK")
        let column = UIStackView(arrangedSubviews: [heading])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        for segment in MessageSegment.split(report) {
            switch segment {
            case .prose(let text):
                let body = UILabel()
                body.numberOfLines = 0
                body.attributedText = TextBubbleCell.rendered(text, color: Theme.Color.label)
                column.addArrangedSubview(body)
            case .code(let language, let source):
                column.addArrangedSubview(codeView(CodeBlock(language: language, source: source)))
            case .table(let table):
                column.addArrangedSubview(TableCell.tableView(table))
            }
        }
        return column
    }

    private static func codeView(_ block: CodeBlock) -> UIView {
        let label = DiffWashLabel()
        label.numberOfLines = 0
        label.lineBreakMode = SyntaxHighlighter.isDiff(block.language) ? .byClipping : .byCharWrapping
        label.font = Theme.Ramp.font(.code)
        label.textColor = Theme.Color.label
        label.attributedText = CodeBlockCell.highlightedCode(
            block.source, language: block.language, font: Theme.Ramp.font(.code))
        label.washes = CodeBlockCell.washes(block.source, language: block.language)
        label.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        box.backgroundColor = Theme.Color.codeBackground
        box.layer.cornerRadius = Theme.Radius.control
        box.layer.cornerCurve = .continuous
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: Theme.Spacing.s),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Theme.Spacing.s),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Theme.Spacing.s),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Theme.Spacing.s),
        ])
        return box
    }

    @objc private func toggleTapped(_ sender: UIButton, event: UIEvent) {
        if let touch = event.allTouches?.first,
            renderer.handleTap(at: touch.location(in: container), in: container)
        {
            Theme.Haptics.tap()
            return
        }
        Theme.Haptics.selection()
        onToggle?()
    }
}

final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom)
    }
}
