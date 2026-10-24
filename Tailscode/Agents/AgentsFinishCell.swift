import TailscodeCore
import UIKit

/// A turn that ended in the last hour, said in one line of what it did or why it failed: a tick or
/// a cross, how long ago, and a dot while nobody has read it. Opens the chat.
@MainActor
final class AgentsFinishCell: UICollectionViewCell {
    private let badgeBox = UIView()
    private let badge = ActivityBadgeView(pointSize: 16)
    private let titleLabel = UILabel()
    private let agoLabel = UILabel()
    private let unreadDot = UIView()
    private let lineLabel = UILabel()
    private let machineLabel = UILabel()
    private let titleRow = UIStackView()
    private let hairline = UIView()
    private let highlight = UIView()
    private var endedAt: Date?

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.backgroundColor = Theme.Color.groupedSurface
        highlight.alpha = 0
        highlight.layer.cornerRadius = Theme.Radius.control
        highlight.layer.cornerCurve = .continuous
        highlight.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(highlight)

        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.addSubview(badge)

        titleLabel.font = Theme.Ramp.font(.rowTitleStrong)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true

        agoLabel.font = Theme.Ramp.font(.rowStamp)
        agoLabel.textColor = Theme.Color.tertiaryLabel
        agoLabel.adjustsFontForContentSizeCategory = true
        agoLabel.setContentHuggingPriority(.required, for: .horizontal)
        agoLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        unreadDot.backgroundColor = Theme.Color.accent
        unreadDot.layer.cornerRadius = 4
        unreadDot.translatesAutoresizingMaskIntoConstraints = false

        lineLabel.font = Theme.Ramp.font(.rowDetail)
        lineLabel.textColor = Theme.Color.secondaryLabel
        lineLabel.numberOfLines = 0
        lineLabel.adjustsFontForContentSizeCategory = true

        machineLabel.font = Theme.Ramp.font(.panelFootnote)
        machineLabel.textColor = Theme.Color.tertiaryLabel
        machineLabel.numberOfLines = 0
        machineLabel.adjustsFontForContentSizeCategory = true

        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Theme.Spacing.s
        [titleLabel, unreadDot, agoLabel].forEach(titleRow.addArrangedSubview)

        let column = UIStackView(arrangedSubviews: [titleRow, lineLabel, machineLabel])
        column.axis = .vertical
        column.spacing = 3
        let body = UIStackView(arrangedSubviews: [badgeBox, column])
        body.axis = .horizontal
        body.alignment = .top
        body.spacing = Theme.Spacing.m
        body.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(body)

        hairline.backgroundColor = Theme.Color.separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hairline)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: contentView.topAnchor),
            highlight.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            badgeBox.widthAnchor.constraint(equalToConstant: 24),
            badge.centerXAnchor.constraint(equalTo: badgeBox.centerXAnchor),
            badge.topAnchor.constraint(equalTo: badgeBox.topAnchor, constant: 2),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            body.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            body.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            body.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.xs),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.xs),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
            hairline.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.xs),
            hairline.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: AgentsFinishCell, _) in cell.adaptAxes()
        }
        adaptAxes()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func adaptAxes() {
        let large = AgentsLayout.isLarge(traitCollection)
        titleRow.axis = large ? .vertical : .horizontal
        titleRow.alignment = large ? .leading : .firstBaseline
    }

    override var isHighlighted: Bool {
        didSet { highlight.alpha = isHighlighted ? 1 : 0 }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        badge.prepareForReuse()
    }

    func configure(_ finish: AgentFinish, showsMachines: Bool, now: Date) {
        endedAt = finish.endedAt
        badge.show(AgentGlyph.icon(for: finish.outcome), spoken: nil)
        titleLabel.text = finish.title
        lineLabel.text = finish.line
        machineLabel.text = finish.machine
        machineLabel.isHidden = !showsMachines
        unreadDot.isHidden = !finish.unread
        var parts = [finish.title, AgentGlyph.spoken(for: finish.outcome), finish.line]
        if showsMachines { parts.append(finish.machine) }
        if finish.unread { parts.append(String(localized: "unread")) }
        accessibilityLabel =
            parts.joined(separator: ". ") + ". "
            + String(localized: "\(AgentsWords.spokenAge(finish.endedAt, now: now)) ago")
        tick(now: now)
    }

    func tick(now: Date) {
        guard let endedAt else { return }
        agoLabel.text = AgentsWords.ago(endedAt, now: now)
    }
}
