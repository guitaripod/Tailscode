import CodingAgentKit
import TailscodeCore
import UIKit

/// What the card at the end of an expert's task says: that the task can be finished, or its
/// debrief — drafting, waiting for the person, settled, or failed.
enum ExpertCardFace: Equatable {
    case finish(ExpertRow)
    /// `wentOn`: the task went on after this debrief was written, so the card offers to finish it
    /// again rather than letting the later turns go unrepresented.
    case debrief(ExpertDebrief, ExpertRow, pressing: Set<String>, wentOn: Bool)
}

/// The end of an expert's task. Each proposal names its own action beside Skip as plain buttons,
/// so nothing on the card looks chosen before it is pressed; the one filled control is Accept all,
/// with Later beside it. Nothing reaches the notebook until it is accepted.
final class ExpertDebriefCell: UICollectionViewCell, RowGapCell {
    static let reuseID = "ExpertDebriefCell"

    var onFinish: (() -> Void)?
    var onAccept: ((ExpertProposal) -> Void)?
    var onSkip: ((ExpertProposal) -> Void)?
    var onAcceptAll: (() -> Void)?
    var onLater: (() -> Void)?
    var onRetry: (() -> Void)?

    private let card = UIView()
    private lazy var cardTop = card.topAnchor.constraint(equalTo: contentView.topAnchor)
    var gapAbove: CGFloat = 0 {
        didSet { cardTop.constant = gapAbove }
    }
    private let stack = UIStackView()
    private let mark = ExpertMarkView(side: 30)

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = Theme.Color.secondaryBackground
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            cardTop,
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: ExpertDebriefCell, _) in
            cell.card.layer.borderColor = cell.borderColor.resolvedColor(with: cell.traitCollection).cgColor
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var borderColor = Theme.Color.separator

    func configure(_ face: ExpertCardFace) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        switch face {
        case .finish(let row):
            borderColor = ExpertStyle.color(row.hue).withAlphaComponent(0.35)
            mark.show(row)
            stack.addArrangedSubview(header(row.expert.name, detail: ExpertWords.finishTaskDetail, tone: .quiet, spinning: false))
            let finish = Self.press(ExpertWords.finishTask, prominent: false) { [weak self] in self?.onFinish?() }
            stack.addArrangedSubview(Self.trailingRow([finish]))
        case .debrief(let debrief, let row, let pressing, let wentOn):
            borderColor = ExpertStyle.color(row.hue).withAlphaComponent(debrief.state == .failed ? 0.2 : 0.35)
            mark.show(row)
            let headline = ExpertReading.debriefHeadline(debrief, name: row.expert.name)
            stack.addArrangedSubview(
                header(headline.text, detail: ExpertReading.debriefDetail(debrief), tone: headline.tone,
                       spinning: debrief.state == .drafting))
            if let entry = debrief.journal, debrief.state != .drafting {
                stack.addArrangedSubview(journal(entry))
            }
            for proposal in debrief.proposals {
                stack.addArrangedSubview(rule())
                stack.addArrangedSubview(proposalRow(proposal, open: debrief.state == .open, pressing: pressing.contains(proposal.id)))
            }
            switch debrief.state {
            case .open where !debrief.pending.isEmpty:
                let later = Self.press(ExpertWords.later, prominent: false) { [weak self] in self?.onLater?() }
                let all = Self.press(ExpertWords.acceptAll, prominent: true) { [weak self] in self?.onAcceptAll?() }
                all.isEnabled = pressing.isEmpty
                let row = UIStackView(arrangedSubviews: [later, all])
                row.spacing = Theme.Spacing.s
                row.distribution = .fill
                later.widthAnchor.constraint(equalTo: all.widthAnchor, multiplier: 0.42).isActive = true
                stack.addArrangedSubview(row)
            case .failed:
                let retry = Self.press(ExpertWords.tryAgain, prominent: false) { [weak self] in self?.onRetry?() }
                stack.addArrangedSubview(Self.trailingRow([retry]))
            default:
                break
            }
            if wentOn {
                stack.addArrangedSubview(rule())
                let note = UILabel()
                note.text = Localized.text("The task went on after this debrief.")
                note.font = Theme.Ramp.font(.panelDetail)
                note.textColor = Theme.Color.secondaryLabel
                note.numberOfLines = 0
                note.adjustsFontForContentSizeCategory = true
                let finish = Self.press(ExpertWords.finishTask, prominent: false) { [weak self] in self?.onFinish?() }
                let line = UIStackView(arrangedSubviews: [note, finish])
                line.alignment = .center
                line.spacing = Theme.Spacing.s
                stack.addArrangedSubview(line)
            }
        }
        card.layer.borderColor = borderColor.resolvedColor(with: traitCollection).cgColor
        invalidateIntrinsicContentSize()
    }

    private func header(_ title: String, detail: String, tone: ExpertTone, spinning: Bool) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = tone == .failing ? Theme.Color.danger : Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = Theme.Ramp.font(.panelDetail)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.isHidden = detail.isEmpty
        let words = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        words.axis = .vertical
        words.spacing = 2
        let row = UIStackView(arrangedSubviews: [mark, words])
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        if spinning {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            row.addArrangedSubview(spinner)
        }
        row.isAccessibilityElement = true
        row.accessibilityLabel = [title, detail].filter { !$0.isEmpty }.joined(separator: ". ")
        row.accessibilityTraits = .header
        return row
    }

    private func journal(_ entry: ExpertJournalEntry) -> UIView {
        let label = UILabel()
        let text = NSMutableAttributedString(
            string: "\(ExpertWords.journalEntry) · \(entry.title)\n",
            attributes: [.font: Theme.Ramp.font(.rowTitleStrong), .foregroundColor: Theme.Color.label])
        text.append(
            NSAttributedString(
                string: ExpertReading.journalPreview(entry),
                attributes: [.font: Theme.Ramp.font(.panelDetail), .foregroundColor: Theme.Color.secondaryLabel]))
        label.attributedText = text
        label.numberOfLines = 0
        let box = UIView()
        box.backgroundColor = Theme.Color.groupedBackground
        box.layer.cornerRadius = 10
        box.layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
        ])
        box.isAccessibilityElement = true
        box.accessibilityLabel = "\(ExpertWords.journalEntry), \(entry.title). \(ExpertReading.journalPreview(entry))"
        return box
    }

    private func rule() -> UIView {
        let line = UIView()
        line.backgroundColor = Theme.Color.separator
        line.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        return line
    }

    private func proposalRow(_ proposal: ExpertProposal, open: Bool, pressing: Bool) -> UIView {
        let tag = UILabel()
        tag.text = " \(ExpertWords.opLabel(proposal.op).uppercased(with: .current)) "
        tag.font = Theme.Ramp.font(.badge)
        let tone: UIColor
        switch proposal.op {
        case .add: tone = Theme.Color.success
        case .change: tone = Theme.Color.accent
        case .retire: tone = Theme.Color.secondaryLabel
        }
        tag.textColor = tone
        tag.backgroundColor = tone.withAlphaComponent(0.18)
        tag.layer.cornerRadius = 5
        tag.layer.masksToBounds = true
        tag.setContentHuggingPriority(.required, for: .horizontal)
        tag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let title = UILabel()
        title.text = proposal.title
        title.font = Theme.Ramp.font(.rowTitle)
        title.numberOfLines = 0
        title.textColor = proposal.state == .skipped ? Theme.Color.tertiaryLabel : Theme.Color.label
        let summary = UILabel()
        summary.text = proposal.summary
        summary.font = Theme.Ramp.font(.panelDetail)
        summary.textColor = Theme.Color.secondaryLabel
        summary.numberOfLines = 0
        summary.isHidden = proposal.summary.isEmpty
        let reason = UILabel()
        reason.text = proposal.reason
        reason.font = Theme.Ramp.font(.panelFootnote)
        reason.textColor = Theme.Color.tertiaryLabel
        reason.numberOfLines = 0
        reason.isHidden = proposal.reason.isEmpty
        let words = UIStackView(arrangedSubviews: [title, summary, reason])
        words.axis = .vertical
        words.spacing = 2
        let row = UIStackView(arrangedSubviews: [tag, words])
        row.alignment = .top
        row.spacing = Theme.Spacing.s
        if open, proposal.state == .pending {
            let accept = Self.press(ExpertWords.accept(proposal.op), prominent: false) { [weak self] in
                self?.onAccept?(proposal)
            }
            let skip = Self.press(ExpertWords.skip, prominent: false, quiet: true) { [weak self] in
                self?.onSkip?(proposal)
            }
            accept.isEnabled = !pressing
            skip.isEnabled = !pressing
            let presses = UIStackView(arrangedSubviews: [accept, skip])
            presses.axis = .vertical
            presses.spacing = 4
            presses.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(presses)
            accept.accessibilityLabel = "\(ExpertWords.accept(proposal.op)), \(proposal.title)"
            skip.accessibilityLabel = "\(ExpertWords.skip), \(proposal.title)"
        } else if let state = ExpertWords.proposalState(proposal.state, op: proposal.op) {
            let label = UILabel()
            label.text = state
            label.font = Theme.Ramp.font(.panelFootnote)
            label.textColor = proposal.state == .accepted ? Theme.Color.success : Theme.Color.tertiaryLabel
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(label)
        }
        words.isAccessibilityElement = true
        words.accessibilityLabel = [
            ExpertWords.opLabel(proposal.op), proposal.title, proposal.summary, proposal.reason,
        ].filter { !$0.isEmpty }.joined(separator: ", ")
        return row
    }

    private static func press(
        _ title: String, prominent: Bool, quiet: Bool = false, action: @escaping () -> Void
    ) -> UIButton {
        var config: UIButton.Configuration = prominent ? .filled() : .gray()
        config.title = title
        config.cornerStyle = .capsule
        config.buttonSize = prominent ? .large : .small
        config.baseForegroundColor =
            prominent ? Theme.Color.onAccent : quiet ? Theme.Color.secondaryLabel : Theme.Color.accent
        if prominent { config.baseBackgroundColor = Theme.Color.accent }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = Theme.Ramp.font(.control)
            return updated
        }
        let button = UIButton(configuration: config)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { _ in
            Theme.Haptics.tap()
            action()
        }, for: .touchUpInside)
        return button
    }

    private static func trailingRow(_ views: [UIView]) -> UIView {
        let row = UIStackView(arrangedSubviews: [UIView()] + views)
        row.spacing = Theme.Spacing.s
        return row
    }
}
