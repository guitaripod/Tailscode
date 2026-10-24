import TailscodeCore
import UIKit

/// A session waiting on the person, with what it asks word for word and the answer in place:
/// Deny and Approve for a command, one button per option for a question. The command is wrapped
/// and selectable, never cut, because the whole point of the card is to read what is about to run.
@MainActor
final class AgentsAskCell: ContentCardCell {
    var onDecide: ((Bool) -> Void)?
    var onOption: ((String) -> Void)?
    var onOpenChat: (() -> Void)?

    private let tile = UIView()
    private let badge = ActivityBadgeView(pointSize: 16)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let leadLabel = UILabel()
    private let objectView = AgentsCommandView()
    private let denyButton = UIButton(type: .system)
    private let approveButton = UIButton(type: .system)
    private let decisionRow = UIStackView()
    private let optionStack = UIStackView()
    private let statusLabel = UILabel()
    private let column = UIStackView()
    private var marks: [ButtonWorkMark] = []
    private var waitingSince: Date?
    private var machine: String?
    private var heardAt: Date?
    private var isAway = false
    private var statusIsAway = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        surface.backgroundColor = UIColor { traits in
            Theme.Color.groupedSurface.resolvedColor(with: traits)
                .mixed(with: Theme.Color.warning.resolvedColor(with: traits), fraction: 0.1)
        }
        surface.layer.borderWidth = 1
        surface.layer.borderColor = Theme.Color.warning.withAlphaComponent(0.42).cgColor
        build()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: AgentsAskCell, _) in cell.adaptAxes()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        tile.layer.cornerRadius = Theme.Radius.control
        tile.layer.cornerCurve = .continuous
        tile.backgroundColor = ActivityTone.attention.color.withAlphaComponent(0.14)
        tile.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(badge)

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true

        subtitleLabel.font = Theme.Ramp.font(.panelFootnote)
        subtitleLabel.textColor = Theme.Color.secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.adjustsFontForContentSizeCategory = true

        leadLabel.font = Theme.Ramp.font(.panelDetail)
        leadLabel.textColor = Theme.Color.label
        leadLabel.numberOfLines = 0
        leadLabel.adjustsFontForContentSizeCategory = true

        configureDecisionButtons()
        optionStack.axis = .vertical
        optionStack.spacing = Theme.Spacing.s

        statusLabel.font = Theme.Ramp.font(.panelFootnote)
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.spacing = 2
        let head = UIStackView(arrangedSubviews: [tile, titles])
        head.axis = .horizontal
        head.alignment = .top
        head.spacing = Theme.Spacing.m

        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        [head, leadLabel, objectView, decisionRow, optionStack, statusLabel]
            .forEach(column.addArrangedSubview)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: ChatRowContentView.tileSize),
            tile.heightAnchor.constraint(equalToConstant: ChatRowContentView.tileSize),
            badge.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        isAccessibilityElement = false
        adaptAxes()
    }

    private func configureDecisionButtons() {
        var deny = UIButton.Configuration.gray()
        deny.title = String(localized: "Deny")
        deny.cornerStyle = .large
        deny.baseForegroundColor = Theme.Color.label
        denyButton.configuration = deny
        denyButton.addAction(
            UIAction { [weak self] _ in self?.onDecide?(false) }, for: .touchUpInside)

        var approve = UIButton.Configuration.filled()
        approve.title = String(localized: "Approve")
        approve.image = UIImage(
            systemName: "lock.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        approve.imagePadding = Theme.Spacing.s
        approve.cornerStyle = .large
        approve.baseBackgroundColor = Theme.Color.accent
        approve.baseForegroundColor = Theme.Color.onAccent
        approveButton.configuration = approve
        approveButton.accessibilityHint = String(
            localized: "Asks you to confirm with Face ID or your passcode")
        approveButton.addAction(
            UIAction { [weak self] _ in self?.onDecide?(true) }, for: .touchUpInside)

        for button in [denyButton, approveButton] {
            button.titleLabel?.numberOfLines = 0
            button.configuration?.titleLineBreakMode = .byWordWrapping
            button.configuration?.titleTextAttributesTransformer = AgentsPeekStyle.controlText
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(
                top: 12, leading: Theme.Spacing.m, bottom: 12, trailing: Theme.Spacing.m)
        }
        decisionRow.axis = .horizontal
        decisionRow.distribution = .fillEqually
        decisionRow.spacing = Theme.Spacing.m
        [denyButton, approveButton].forEach(decisionRow.addArrangedSubview)
        marks = [
            ButtonWorkMark(on: denyButton, tint: Theme.Color.label),
            ButtonWorkMark(on: approveButton, tint: Theme.Color.onAccent),
        ]
    }

    private func adaptAxes() {
        decisionRow.axis = AgentsLayout.isLarge(traitCollection) ? .vertical : .horizontal
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        badge.prepareForReuse()
        onDecide = nil
        onOption = nil
        onOpenChat = nil
    }

    func configure(
        _ card: AgentAskCard, state: AgentsActionState?, showsMachines: Bool, heard: Date?, now: Date
    ) {
        badge.show(AgentGlyph.icon(tone: .attention, motion: .attention), spoken: nil)
        titleLabel.text = card.title
        machine = showsMachines ? card.machine : nil
        waitingSince = card.ask.since
        heardAt = heard
        isAway = card.isAway
        leadLabel.text = card.ask.lead
        objectView.isHidden = card.ask.object?.isEmpty ?? true
        if let object = card.ask.object { objectView.show(object) }

        let approval = card.ask.isApproval
        decisionRow.isHidden = !approval
        optionStack.isHidden = approval
        if approval { applyDecision(state, away: card.isAway) } else { applyOptions(card.ask, state, away: card.isAway) }
        applyStatus(state)
        surface.alpha = card.isAway ? 0.62 : 1
        tick(now: now)
        accessibilityElements = [titleLabel, subtitleLabel, leadLabel, objectView]
            + (approval ? [denyButton, approveButton] : optionStack.arrangedSubviews)
            + [statusLabel]
    }

    private func applyDecision(_ state: AgentsActionState?, away: Bool) {
        let busy = state.map { if case .busy = $0 { return true } else { return false } } ?? false
        let done = state.map { if case .done = $0 { return true } else { return false } } ?? false
        let locked = busy || done || away
        denyButton.isEnabled = !locked
        approveButton.isEnabled = !locked
        var chosen: AgentsActionState.Kind?
        switch state {
        case .busy(let kind)?, .done(let kind)?: chosen = kind
        default: chosen = nil
        }
        marks[0].show(busy && chosen == .deny, on: denyButton)
        marks[1].show(busy && chosen == .approve, on: approveButton)
        denyButton.configuration?.title =
            done && chosen == .deny ? String(localized: "Denied") : String(localized: "Deny")
        approveButton.configuration?.title =
            done && chosen == .approve ? String(localized: "Approved") : String(localized: "Approve")
        approveButton.configuration?.image =
            done && chosen == .approve
            ? UIImage(systemName: "checkmark") : UIImage(systemName: "lock.fill")
    }

    private func applyOptions(_ ask: AgentAsk, _ state: AgentsActionState?, away: Bool) {
        optionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let busy = state.map { if case .busy = $0 { return true } else { return false } } ?? false
        let done = state.map { if case .done = $0 { return true } else { return false } } ?? false
        var chosen: String?
        switch state {
        case .busy(.option(let label))?, .done(.option(let label))?: chosen = label
        default: chosen = nil
        }
        let labels = ask.options.isEmpty ? [String(localized: "Answer in the chat")] : ask.options
        for label in labels {
            let button = UIButton(type: .system)
            var configuration = label == chosen && done ? UIButton.Configuration.filled() : .gray()
            configuration.title = label == chosen && done ? String(localized: "Sent") : label
            configuration.cornerStyle = .large
            configuration.baseForegroundColor = Theme.Color.label
            configuration.titleLineBreakMode = .byWordWrapping
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 12, leading: Theme.Spacing.m, bottom: 12, trailing: Theme.Spacing.m)
            if label == chosen && done { configuration.baseBackgroundColor = Theme.Color.accent }
            configuration.titleTextAttributesTransformer = AgentsPeekStyle.controlText
            button.configuration = configuration
            button.titleLabel?.numberOfLines = 0
            button.isEnabled = !(busy || done || away)
            button.accessibilityLabel = label
            let opensChat = ask.options.isEmpty
            button.addAction(
                UIAction { [weak self] _ in
                    if opensChat { self?.onOpenChat?() } else { self?.onOption?(label) }
                }, for: .touchUpInside)
            optionStack.addArrangedSubview(button)
        }
    }

    private func applyStatus(_ state: AgentsActionState?) {
        statusIsAway = false
        if case .failed(let why)? = state {
            statusLabel.text = why
            statusLabel.textColor = Theme.Color.danger
            statusLabel.isHidden = false
        } else if isAway {
            statusIsAway = true
            statusLabel.textColor = Theme.Color.warning
            statusLabel.isHidden = false
        } else {
            statusLabel.text = nil
            statusLabel.isHidden = true
        }
    }

    func tick(now: Date) {
        var parts: [String] = []
        if let machine { parts.append(machine) }
        if let waiting = AgentsWords.waiting(since: waitingSince, now: now) { parts.append(waiting) }
        subtitleLabel.text = parts.joined(separator: " · ")
        subtitleLabel.isHidden = parts.isEmpty
        if statusIsAway {
            statusLabel.text = AgentsWords.lastSeen(heardAt, now: now)
        }
    }
}
