import TailscodeCore
import UIKit

/// The board's first words: what it adds up to as a sentence, how much of it is watched, and which
/// machines it spans when there is more than one. The sentence and the watch line are Core's; this
/// only sets the working part in the live ink and the waiting part in attention.
@MainActor
final class AgentsHeaderCell: UICollectionViewCell {
    private let sentenceLabel = UILabel()
    private let watchLabel = UILabel()
    private let chips = UIScrollView()
    private let chipRow = UIStackView()
    private let column = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        sentenceLabel.font = Theme.Ramp.font(.statusSentence)
        sentenceLabel.numberOfLines = 0
        sentenceLabel.adjustsFontForContentSizeCategory = true
        sentenceLabel.accessibilityTraits = .header

        watchLabel.font = Theme.Ramp.font(.statusLine)
        watchLabel.textColor = Theme.Color.secondaryLabel
        watchLabel.numberOfLines = 0
        watchLabel.adjustsFontForContentSizeCategory = true

        chipRow.axis = .horizontal
        chipRow.spacing = Theme.Spacing.s
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chips.showsHorizontalScrollIndicator = false
        chips.alwaysBounceHorizontal = false
        chips.translatesAutoresizingMaskIntoConstraints = false
        chips.addSubview(chipRow)
        NSLayoutConstraint.activate([
            chipRow.topAnchor.constraint(equalTo: chips.contentLayoutGuide.topAnchor),
            chipRow.bottomAnchor.constraint(equalTo: chips.contentLayoutGuide.bottomAnchor),
            chipRow.leadingAnchor.constraint(equalTo: chips.contentLayoutGuide.leadingAnchor),
            chipRow.trailingAnchor.constraint(equalTo: chips.contentLayoutGuide.trailingAnchor),
            chips.frameLayoutGuide.heightAnchor.constraint(equalTo: chipRow.heightAnchor),
        ])

        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.setCustomSpacing(Theme.Spacing.m, after: watchLabel)
        [sentenceLabel, watchLabel, chips].forEach(column.addArrangedSubview)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.s),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.s),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.xs),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.xs),
        ])
        isAccessibilityElement = false
        accessibilityElements = [sentenceLabel, watchLabel, chips]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ board: AgentBoard) {
        sentenceLabel.attributedText = Self.sentence(board)
        sentenceLabel.accessibilityLabel = board.sentence
        watchLabel.text = board.watchLine
        let machines = board.showsMachines ? board.machines : []
        chips.isHidden = machines.isEmpty
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        machines.map(AgentsMachineChip.init).forEach(chipRow.addArrangedSubview)
    }

    private static func sentence(_ board: AgentBoard) -> NSAttributedString {
        let font = Theme.Ramp.font(.statusSentence)
        var tones: [UIColor] = []
        if board.headline.working > 0 { tones.append(ActivityTone.live.color) }
        if board.headline.needsYou > 0 { tones.append(ActivityTone.attention.color) }
        if tones.isEmpty, board.headline.background > 0 { tones.append(ActivityTone.live.color) }
        let parts = board.sentence.components(separatedBy: " · ")
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                result.append(
                    NSAttributedString(
                        string: " · ",
                        attributes: [.font: font, .foregroundColor: Theme.Color.tertiaryLabel]))
            }
            let ink = parts.count == tones.count ? tones[index] : Theme.Color.label
            result.append(NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: ink]))
        }
        return result
    }
}

/// One machine the board spans: whether it answers, in a shape as well as a colour, and how many
/// of its agents are running.
@MainActor
private final class AgentsMachineChip: UIView {
    init(_ machine: AgentMachine) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerCurve = .continuous
        layer.cornerRadius = Theme.Radius.control

        let mark = UIImageView(
            image: UIImage(
                systemName: Self.symbol(machine.reachable),
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)))
        mark.tintColor = Self.ink(machine.reachable)
        mark.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = Theme.Color.secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.text = machine.running > 0 ? "\(machine.name) · \(machine.running)" : machine.name

        let row = UIStackView(arrangedSubviews: [mark, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.xs + 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = true
        accessibilityLabel = Self.spoken(machine)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func symbol(_ reachable: Bool?) -> String {
        switch reachable {
        case true?: return "circle.fill"
        case false?: return "wifi.slash"
        case nil: return "circle"
        }
    }

    private static func ink(_ reachable: Bool?) -> UIColor {
        switch reachable {
        case true?: return Theme.Color.success
        case false?: return Theme.Color.danger
        case nil: return Theme.Color.tertiaryLabel
        }
    }

    private static func spoken(_ machine: AgentMachine) -> String {
        let state: String
        switch machine.reachable {
        case true?: state = String(localized: "answering")
        case false?: state = String(localized: "not answering")
        case nil: state = String(localized: "not checked yet")
        }
        guard machine.running > 0 else { return "\(machine.name), \(state)" }
        return "\(machine.name), \(state), " + String(localized: "\(machine.running) running")
    }
}

/// The board with nothing on it: says what it is for rather than turning a spinner, because an
/// empty board is the usual one.
@MainActor
final class AgentsEmptyCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.image = UIImage(
            systemName: "waveform.path.ecg",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .light))
        imageView.tintColor = Theme.Color.tertiaryLabel
        imageView.contentMode = .scaleAspectFit

        label.font = Theme.Ramp.font(.panelDetail)
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.text = String(
            localized:
                "Agents that are working, waiting on you or have just finished show up here, across every machine you have connected.")

        let column = UIStackView(arrangedSubviews: [imageView, label])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xl),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        isAccessibilityElement = true
        accessibilityLabel = label.text
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A section's name and how many it holds, with a word on the far side where there is one to say
/// (how many finished turns are unread).
@MainActor
final class AgentsSectionHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = Theme.Ramp.font(.panelFootnote)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.xs),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.xs),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, count: Int, detail: String?, urgent: Bool) {
        let font = Theme.Ramp.font(.sectionLabel)
        let ink = urgent ? Theme.Color.warning : Theme.Color.secondaryLabel
        let text = NSMutableAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: font, .foregroundColor: ink,
                .kern: Typography.spec(.sectionLabel).tracking * font.pointSize,
            ])
        text.append(
            NSAttributedString(
                string: "  \(count)",
                attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(0.8)]))
        titleLabel.attributedText = text
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        accessibilityLabel = [title, AgentsWords.agents(count)]
            .joined(separator: ", ") + (detail.map { ", " + $0 } ?? "")
    }
}
