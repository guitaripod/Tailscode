import TailscodeCore
import UIKit

/// One machine's software, drawn from Core's `UpdateCard` and nothing else.
///
/// It is rewritten in place rather than rebuilt: a job in flight lands a new reading every two
/// seconds for minutes on end, and a card that rebuilt itself on each one would throw away what the
/// reader had opened and move the button under their thumb. Lists — the steps, what is new, the
/// details — are laid out again only when their content changes; the clock beside the step under
/// way ticks on its own, once a second, while the card is on screen.
///
/// Two ways to sit: `standalone` draws its own card and names the machine above the headline, for
/// the screen listing every machine; `embedded` draws neither, for a screen that is already about
/// that machine.
@MainActor
final class UpdateCardView: UIView {
    enum Style {
        case standalone
        case embedded
    }

    var onAction: ((UpdateCard.Action) -> Void)?
    var onAutomation: ((Bool) -> Void)?
    /// Something inside changed height — a list opened or closed. A host that sizes its cells from
    /// their content asks for the layout again.
    var onResize: (() -> Void)?

    private let style: Style
    private let machineLabel = UILabel()
    private let badge = ActivityBadgeView(pointSize: 20)
    private let headlineLabel = UILabel()
    private let versionLabel = UILabel()
    private let messageLabel = UILabel()
    private let stepsStack = UIStackView()
    private let notesTitleLabel = UILabel()
    private let notesStack = UIStackView()
    private let moreNotesButton = UIButton(type: .system)
    private let actionsStack = UIStackView()
    private let automationTitle = UILabel()
    private let automationSwitch = UISwitch()
    private let automationStatus = UILabel()
    private let automationRow = UIStackView()
    private let detailsButton = UIButton(type: .system)
    private let factsStack = UIStackView()
    private let footnoteLabel = UILabel()
    private let column = UIStackView()

    private var card: UpdateCard?
    private var notesExpanded = false
    private var detailsExpanded = false
    private var clock: Timer?
    private var clockLabel: UILabel?
    private var clockSince: Date?
    private var drawnSteps: [UpdateCard.Step] = []
    private var drawnNotes: [ReleaseNote] = []
    private var drawnFacts: [UpdateCard.Fact] = []
    private var drawnActions: [ActionKey] = []

    /// How much of what is new a card says before it offers the rest.
    private static let noteLimit = 4

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        if style == .standalone {
            backgroundColor = Theme.Color.groupedSurface
            layer.cornerRadius = Theme.Radius.card
            layer.cornerCurve = .continuous
        }

        machineLabel.font = Theme.Ramp.font(.sectionLabel)
        machineLabel.adjustsFontForContentSizeCategory = true
        machineLabel.textColor = Theme.Color.secondaryLabel
        machineLabel.numberOfLines = 1

        headlineLabel.font = Theme.Ramp.font(.cardTitle)
        headlineLabel.adjustsFontForContentSizeCategory = true
        headlineLabel.textColor = Theme.Color.label
        headlineLabel.numberOfLines = 0

        versionLabel.font = Theme.Ramp.font(.panelLabel)
        versionLabel.adjustsFontForContentSizeCategory = true
        versionLabel.textColor = Theme.Color.secondaryLabel
        versionLabel.numberOfLines = 0

        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titles = UIStackView(arrangedSubviews: [headlineLabel, versionLabel])
        titles.axis = .vertical
        titles.spacing = 2
        let header = UIStackView(arrangedSubviews: [badge, titles])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.m
        header.isAccessibilityElement = true
        header.accessibilityTraits = .header

        for label in [messageLabel, automationStatus, footnoteLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        messageLabel.font = Theme.Ramp.font(.panelDetail)
        messageLabel.textColor = Theme.Color.secondaryLabel

        stepsStack.axis = .vertical
        stepsStack.spacing = Theme.Spacing.s

        notesTitleLabel.font = Theme.Ramp.font(.sectionLabel)
        notesTitleLabel.adjustsFontForContentSizeCategory = true
        notesTitleLabel.textColor = Theme.Color.secondaryLabel
        notesStack.axis = .vertical
        notesStack.spacing = Theme.Spacing.xs

        var more = UIButton.Configuration.plain()
        more.contentInsets = .zero
        more.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = Theme.Ramp.font(.control)
            return attributes
        }
        moreNotesButton.configuration = more
        moreNotesButton.contentHorizontalAlignment = .leading
        moreNotesButton.addAction(
            UIAction { [weak self] _ in self?.toggleNotes() }, for: .touchUpInside)

        actionsStack.spacing = Theme.Spacing.l
        layoutActions()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: UpdateCardView, _) in view.layoutActions()
        }

        automationTitle.font = Theme.Ramp.font(.panelLabel)
        automationTitle.adjustsFontForContentSizeCategory = true
        automationTitle.textColor = Theme.Color.label
        automationTitle.numberOfLines = 0
        automationSwitch.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                Theme.Haptics.tap()
                self.automationSwitch.isEnabled = false
                self.onAutomation?(self.automationSwitch.isOn)
            }, for: .valueChanged)
        automationSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let switchLine = UIStackView(arrangedSubviews: [automationTitle, automationSwitch])
        switchLine.axis = .horizontal
        switchLine.alignment = .center
        switchLine.spacing = Theme.Spacing.s
        automationStatus.font = Theme.Ramp.font(.panelFootnote)
        automationStatus.textColor = Theme.Color.secondaryLabel
        automationRow.addArrangedSubview(switchLine)
        automationRow.addArrangedSubview(automationStatus)
        automationRow.axis = .vertical
        automationRow.spacing = 2

        var details = UIButton.Configuration.plain()
        details.contentInsets = .zero
        details.imagePlacement = .trailing
        details.imagePadding = Theme.Spacing.xs
        details.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: .caption2)
        details.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = Theme.Ramp.font(.control)
            return attributes
        }
        detailsButton.configuration = details
        detailsButton.tintColor = Theme.Color.secondaryLabel
        detailsButton.contentHorizontalAlignment = .leading
        detailsButton.addAction(
            UIAction { [weak self] _ in self?.toggleDetails() }, for: .touchUpInside)

        factsStack.axis = .vertical
        factsStack.spacing = Theme.Spacing.s

        footnoteLabel.font = Theme.Ramp.font(.panelFootnote)
        footnoteLabel.textColor = Theme.Color.tertiaryLabel

        for view: UIView in [
            machineLabel, header, messageLabel, stepsStack, notesTitleLabel, notesStack,
            moreNotesButton, actionsStack, automationRow, detailsButton, factsStack, footnoteLabel,
        ] {
            column.addArrangedSubview(view)
        }
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.setCustomSpacing(Theme.Spacing.xs, after: machineLabel)
        column.setCustomSpacing(Theme.Spacing.xs, after: notesTitleLabel)
        column.setCustomSpacing(Theme.Spacing.xs, after: notesStack)
        column.setCustomSpacing(Theme.Spacing.s, after: detailsButton)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let inset = style == .standalone ? Theme.Spacing.l : 0
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
    }

    /// One answer painted into the card it belongs to.
    func apply(_ card: UpdateCard) {
        self.card = card
        machineLabel.text = [card.machine, card.subtitle].compactMap { $0 }.joined(separator: " · ")
            .uppercased()
        machineLabel.isHidden = style == .embedded
        badge.show(card.icon, spoken: nil)
        headlineLabel.text = card.headline
        headlineLabel.textColor = card.stage == .failed ? Theme.Color.danger : Theme.Color.label
        versionLabel.text = card.versionLine
        versionLabel.isHidden = card.versionLine == nil
        let header = headlineLabel.superview?.superview
        header?.accessibilityLabel = [card.headline, card.versionLine].compactMap { $0 }
            .joined(separator: ", ")

        messageLabel.text = card.message
        messageLabel.isHidden = card.message == nil

        renderSteps(card.steps)
        renderNotes(card)
        renderActions(card)
        renderAutomation(card.automation)
        renderFacts(card.facts)

        footnoteLabel.text = card.footnote
        footnoteLabel.isHidden = card.footnote == nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        runClock()
    }

    private func renderSteps(_ steps: [UpdateCard.Step]) {
        stepsStack.isHidden = steps.isEmpty
        let shape = steps.map { StepShape(id: $0.id, title: $0.title, state: $0.state) }
        let drawn = drawnSteps.map { StepShape(id: $0.id, title: $0.title, state: $0.state) }
        if shape != drawn {
            for view in stepsStack.arrangedSubviews { view.removeFromSuperview() }
            clockLabel = nil
            for step in steps {
                let row = StepRow(step: step)
                if step.state == .active { clockLabel = row.clock }
                stepsStack.addArrangedSubview(row)
            }
        } else {
            for (row, step) in zip(stepsStack.arrangedSubviews.compactMap { $0 as? StepRow }, steps) {
                row.update(detail: step.detail)
            }
        }
        drawnSteps = steps
        clockSince = steps.first { $0.state == .active }?.since
        runClock()
    }

    private func renderNotes(_ card: UpdateCard) {
        let lines = card.notes.flatMap(\.items)
        notesTitleLabel.text = card.notesTitle?.uppercased()
        notesTitleLabel.isHidden = lines.isEmpty
        notesStack.isHidden = lines.isEmpty
        if card.notes != drawnNotes {
            drawnNotes = card.notes
            notesExpanded = false
            rebuildNotes()
        }
        let hidden = lines.count - Self.noteLimit
        moreNotesButton.isHidden = hidden <= 0
        moreNotesButton.configuration?.title =
            notesExpanded
            ? String(localized: "Show less")
            : String(localized: "Show all \(lines.count)")
    }

    private func rebuildNotes() {
        for view in notesStack.arrangedSubviews { view.removeFromSuperview() }
        let lines = drawnNotes.flatMap(\.items)
        let shown = notesExpanded ? lines : Array(lines.prefix(Self.noteLimit))
        for line in shown {
            notesStack.addArrangedSubview(Bullet(text: line))
        }
    }

    private func toggleNotes() {
        Theme.Haptics.selection()
        notesExpanded.toggle()
        rebuildNotes()
        if let card { renderNotes(card) }
        onResize?()
    }

    private func renderActions(_ card: UpdateCard) {
        let actions = [card.primary].compactMap { $0 } + card.secondary
        let keys = actions.map(ActionKey.init)
        actionsStack.isHidden = actions.isEmpty
        guard keys != drawnActions else { return }
        drawnActions = keys
        for view in actionsStack.arrangedSubviews { view.removeFromSuperview() }
        for action in actions {
            actionsStack.addArrangedSubview(button(for: action))
        }
        actionsStack.addArrangedSubview(UIView())
    }

    /// Side by side while they fit, one under another once the type is large enough that a row of
    /// three would crush the press the card is about.
    private func layoutActions() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        actionsStack.axis = stacked ? .vertical : .horizontal
        actionsStack.alignment = stacked ? .leading : .center
    }

    private func button(for action: UpdateCard.Action) -> UIButton {
        var config =
            action.prominent
            ? Theme.Glass.buttonConfiguration(prominent: true) : UIButton.Configuration.plain()
        config.title = action.title
        config.cornerStyle = .capsule
        config.buttonSize = action.prominent ? .medium : .small
        if action.prominent {
            config.image = UIImage(systemName: action.symbol)
            config.imagePadding = Theme.Spacing.xs
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                textStyle: .subheadline, scale: .small)
        }
        config.titleLineBreakMode = .byTruncatingTail
        if !action.prominent {
            config.contentInsets = NSDirectionalEdgeInsets(
                top: Theme.Spacing.s, leading: 0, bottom: Theme.Spacing.s, trailing: 0)
        }
        let button = UIButton(configuration: config)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        if !action.prominent { button.tintColor = Theme.Color.accent }
        if case .setAside = action.kind { button.tintColor = Theme.Color.secondaryLabel }
        button.isEnabled = action.enabled
        button.addAction(
            UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        return button
    }

    private func renderAutomation(_ automation: UpdateCard.Automation?) {
        automationRow.isHidden = automation == nil
        guard let automation else { return }
        automationTitle.text = automation.title
        automationSwitch.isOn = automation.isOn
        automationSwitch.isEnabled = true
        automationSwitch.accessibilityLabel = automation.title
        automationStatus.text = automation.status
    }

    /// The machine did not change its policy; the switch goes back to what the machine last said.
    func restoreAutomation() {
        renderAutomation(card?.automation)
    }

    private func renderFacts(_ facts: [UpdateCard.Fact]) {
        detailsButton.isHidden = facts.isEmpty
        detailsButton.configuration?.title = String(localized: "Details")
        detailsButton.configuration?.image = UIImage(
            systemName: detailsExpanded ? "chevron.up" : "chevron.down")
        factsStack.isHidden = facts.isEmpty || !detailsExpanded
        guard facts != drawnFacts else { return }
        drawnFacts = facts
        for view in factsStack.arrangedSubviews { view.removeFromSuperview() }
        for fact in facts { factsStack.addArrangedSubview(FactRow(fact: fact)) }
    }

    private func toggleDetails() {
        Theme.Haptics.selection()
        detailsExpanded.toggle()
        renderFacts(drawnFacts)
        onResize?()
    }

    /// A clock that ticks only while there is a step under way and somebody could see it.
    private func runClock() {
        guard window != nil, clockLabel != nil, clockSince != nil else {
            clock?.invalidate()
            clock = nil
            clockLabel?.text = nil
            return
        }
        tick()
        guard clock == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func tick() {
        guard let since = clockSince, let clockLabel else { return }
        clockLabel.text = RelativeWhen.clock(Date().timeIntervalSince(since))
    }

    private struct StepShape: Equatable {
        let id: String
        let title: String
        let state: UpdateCard.Step.State
    }

    /// What distinguishes one drawn press from another, so an answer that changes nothing about
    /// the buttons leaves the buttons alone.
    private struct ActionKey: Equatable {
        let title: String
        let enabled: Bool
        let prominent: Bool

        init(_ action: UpdateCard.Action) {
            title = action.title
            enabled = action.enabled
            prominent = action.prominent
        }
    }
}

/// One step of a job: done, under way with its clock, still to come, or where it stopped.
@MainActor
private final class StepRow: UIView {
    let clock = UILabel()
    private let detail = UILabel()

    init(step: UpdateCard.Step) {
        super.init(frame: .zero)
        let glyph: UIView
        switch step.state {
        case .active:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = Theme.Color.success
            spinner.startAnimating()
            glyph = spinner
        case .done, .pending, .failed:
            let image = UIImageView(
                image: UIImage(
                    systemName: Self.symbol(step.state),
                    withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)))
            image.tintColor = Self.tint(step.state)
            image.contentMode = .scaleAspectFit
            glyph = image
        }
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.text = step.title
        title.font = Theme.Ramp.font(step.state == .active ? .rowTitleStrong : .rowTitle)
        title.adjustsFontForContentSizeCategory = true
        title.textColor =
            step.state == .pending
            ? Theme.Color.tertiaryLabel
            : step.state == .failed ? Theme.Color.danger : Theme.Color.label

        clock.font = Theme.Ramp.font(.rowStamp)
        clock.adjustsFontForContentSizeCategory = true
        clock.textColor = Theme.Color.secondaryLabel
        clock.setContentHuggingPriority(.required, for: .horizontal)

        detail.font = Theme.Ramp.font(.panelFootnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Theme.Color.secondaryLabel
        detail.numberOfLines = 0
        update(detail: step.detail)

        let line = UIStackView(arrangedSubviews: [title, UIView(), clock])
        line.axis = .horizontal
        line.alignment = .firstBaseline
        let text = UIStackView(arrangedSubviews: [line, detail])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [glyph, text])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 22),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = [title.text, Self.spoken(step.state), step.detail].compactMap { $0 }
            .joined(separator: ", ")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(detail text: String?) {
        detail.text = text
        detail.isHidden = text == nil
    }

    private static func symbol(_ state: UpdateCard.Step.State) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending, .active: return "circle"
        }
    }

    private static func tint(_ state: UpdateCard.Step.State) -> UIColor {
        switch state {
        case .done: return Theme.Color.success
        case .failed: return Theme.Color.danger
        case .pending, .active: return Theme.Color.tertiaryLabel
        }
    }

    private static func spoken(_ state: UpdateCard.Step.State) -> String {
        switch state {
        case .done: return String(localized: "done")
        case .active: return String(localized: "under way")
        case .pending: return String(localized: "not started")
        case .failed: return String(localized: "failed")
        }
    }
}

/// One line of what is new.
@MainActor
private final class Bullet: UIView {
    init(text: String) {
        super.init(frame: .zero)
        let dot = UILabel()
        dot.text = "•"
        dot.font = Theme.Ramp.font(.panelDetail)
        dot.textColor = Theme.Color.accent
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        let label = UILabel()
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.text = text
        label.font = Theme.Ramp.font(.panelDetail)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.label
        label.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = text
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A number the card rests on, with who said it — copyable, because it is what a bug report needs.
@MainActor
private final class FactRow: UIView, UIContextMenuInteractionDelegate {
    private let fact: UpdateCard.Fact

    init(fact: UpdateCard.Fact) {
        self.fact = fact
        super.init(frame: .zero)
        let label = UILabel()
        label.text = fact.label
        label.font = Theme.Ramp.font(.panelFootnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.tertiaryLabel
        let value = UILabel()
        value.text = fact.value
        value.font = Theme.Ramp.font(.panelFootnote)
        value.adjustsFontForContentSizeCategory = true
        value.textColor = Theme.Color.secondaryLabel
        value.numberOfLines = 0
        let column = UIStackView(arrangedSubviews: [label, value])
        column.axis = .vertical
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "\(fact.label): \(fact.value)"
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let value = fact.value
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) {
                    _ in
                    UIPasteboard.general.string = value
                    Theme.Haptics.tap()
                }
            ])
        }
    }
}

/// A list row holding one machine's software card, for a screen that is already about that machine.
/// The row keeps the list's own grouped background; the card inside draws none of its own.
@MainActor
final class UpdateCardCell: UICollectionViewListCell {
    let card = UpdateCardView(style: .embedded)

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: margins.topAnchor, constant: Theme.Spacing.xs),
            card.bottomAnchor.constraint(equalTo: margins.bottomAnchor, constant: -Theme.Spacing.xs),
            card.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
