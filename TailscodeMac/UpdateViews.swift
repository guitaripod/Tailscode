import AppKit
import TailscodeCore

/// One machine's software, drawn from Core's `UpdateCard` and nothing else.
///
/// It is rewritten in place rather than rebuilt: a job in flight lands a new reading every two
/// seconds for minutes on end, and a card that rebuilt itself on each one would throw away the
/// scroll position and whatever button was under the pointer. Lists — the steps, what is new, the
/// details — are laid out again only when their shape actually changes; the clock beside the step
/// under way ticks on its own, once a second, while the card is in a window.
///
/// Two ways to sit: `standalone` draws its own card and names the machine above the headline, for
/// the window listing every machine; `embedded` draws neither, for a screen that is already about
/// that one machine.
@MainActor
final class UpdateCardView: NSView {
    enum Style {
        case standalone
        case embedded
    }

    var onAction: ((UpdateCard.Action) -> Void)?
    var onAutomation: ((Bool) -> Void)?

    private let style: Style
    private let machineLabel = NSTextField(labelWithString: "")
    private let mark = UpdateMarkView(pointSize: 15)
    private let headlineLabel = NSTextField(wrappingLabelWithString: "")
    private let versionLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let header: NSStackView
    private let stepsStack = FillingStack()
    private let notesTitleLabel = NSTextField(labelWithString: "")
    private let notesStack = FillingStack()
    private let moreNotesButton = RowKit.ActionButton(title: "", action: {})
    private let actionsStack = NSStackView()
    private let automationCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let automationStatus = NSTextField(wrappingLabelWithString: "")
    private let automationRow = FillingStack()
    private let detailsButton = RowKit.ActionButton(title: "", action: {})
    private let factsStack = FillingStack()
    private let footnoteLabel = NSTextField(labelWithString: "")
    private let column = FillingStack()

    private var card: UpdateCard?
    private var notesExpanded = false
    private var detailsExpanded = false
    private var clock: Timer?
    private weak var clockLabel: NSTextField?
    private var clockSince: Date?
    private var drawnSteps: [UpdateCard.Step] = []
    private var drawnNotes: [ReleaseNote] = []
    private var drawnFacts: [UpdateCard.Fact] = []
    private var drawnActions: [ActionKey] = []

    /// How much of what is new a card says before it offers the rest.
    private static let noteLimit = 4

    init(style: Style) {
        self.style = style
        let titles = NSStackView(views: [headlineLabel, versionLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        header = NSStackView(views: [mark, titles])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = MacTheme.Spacing.s
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        wantsLayer = true
        if style == .standalone {
            layer?.cornerRadius = MacTheme.Radius.card
            layer?.borderWidth = 1
        }

        machineLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.isSelectable = false
        headlineLabel.setContentHuggingPriority(.required, for: .vertical)
        versionLabel.isSelectable = false
        versionLabel.setContentHuggingPriority(.required, for: .vertical)
        messageLabel.isSelectable = true
        header.setAccessibilityElement(true)
        header.setAccessibilityRole(.staticText)

        stepsStack.spacing = MacTheme.Spacing.s

        notesTitleLabel.lineBreakMode = .byTruncatingTail
        notesStack.spacing = MacTheme.Spacing.xs

        moreNotesButton.isBordered = false
        moreNotesButton.alignment = .left
        moreNotesButton.setContentHuggingPriority(.required, for: .horizontal)
        moreNotesButton.setAction { [weak self] in self?.toggleNotes() }

        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = MacTheme.Spacing.m

        automationCheckbox.target = self
        automationCheckbox.action = #selector(automationToggled)
        automationStatus.isSelectable = false
        automationRow.spacing = 2
        automationRow.addArrangedSubview(automationCheckbox)
        automationRow.addArrangedSubview(automationStatus)

        detailsButton.isBordered = false
        detailsButton.alignment = .left
        detailsButton.imagePosition = .imageTrailing
        detailsButton.imageHugsTitle = true
        detailsButton.setContentHuggingPriority(.required, for: .horizontal)
        detailsButton.setAction { [weak self] in self?.toggleDetails() }

        factsStack.spacing = MacTheme.Spacing.s

        footnoteLabel.lineBreakMode = .byTruncatingTail

        var rows: [NSView] = [machineLabel, header, messageLabel, stepsStack]
        rows += [notesTitleLabel, notesStack, moreNotesButton, actionsStack, automationRow]
        rows += [detailsButton, factsStack, footnoteLabel]
        for row in rows { column.addArrangedSubview(row) }
        column.setCustomSpacing(MacTheme.Spacing.xs, after: machineLabel)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: notesTitleLabel)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: notesStack)
        column.setCustomSpacing(MacTheme.Spacing.s, after: detailsButton)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let inset: CGFloat = style == .standalone ? MacTheme.Spacing.l : 0
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            column.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        applyTheme()
    }

    /// One answer painted into the card it belongs to.
    func apply(_ card: UpdateCard) {
        self.card = card
        let line = [card.machine, card.subtitle].compactMap { $0 }.joined(separator: " · ")
        machineLabel.stringValue = line.uppercased()
        machineLabel.isHidden = style == .embedded

        mark.apply(card.icon)
        headlineLabel.stringValue = card.headline
        headlineLabel.textColor = card.stage == .failed ? MacTheme.Color.danger : MacTheme.Color.label
        write(versionLabel, card.versionLine)
        header.setAccessibilityLabel(
            [card.headline, card.versionLine].compactMap { $0 }.joined(separator: ", "))

        write(messageLabel, card.message)

        renderSteps(card.steps)
        renderNotes(card)
        renderActions(card)
        renderAutomation(card.automation)
        renderFacts(card.facts)

        write(footnoteLabel, card.footnote)
        setAccessibilityLabel(card.accessibility)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        runClock()
    }

    private func renderSteps(_ steps: [UpdateCard.Step]) {
        stepsStack.isHidden = steps.isEmpty
        let shape = steps.map { StepShape(id: $0.id, title: $0.title, state: $0.state) }
        let drawn = drawnSteps.map { StepShape(id: $0.id, title: $0.title, state: $0.state) }
        if shape != drawn {
            for view in stepsStack.arrangedSubviews {
                stepsStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
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
        write(notesTitleLabel, card.notesTitle?.uppercased())
        notesStack.isHidden = lines.isEmpty
        if card.notes != drawnNotes {
            drawnNotes = card.notes
            notesExpanded = false
            rebuildNotes()
        }
        let hidden = lines.count - Self.noteLimit
        moreNotesButton.isHidden = hidden <= 0
        moreNotesButton.title =
            notesExpanded
            ? Localized.text("Show less") : Localized.text("Show all %@", String(lines.count))
    }

    private func rebuildNotes() {
        for view in notesStack.arrangedSubviews {
            notesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let lines = drawnNotes.flatMap(\.items)
        let shown = notesExpanded ? lines : Array(lines.prefix(Self.noteLimit))
        for line in shown { notesStack.addArrangedSubview(Bullet(text: line)) }
    }

    private func toggleNotes() {
        notesExpanded.toggle()
        rebuildNotes()
        if let card { renderNotes(card) }
    }

    private func renderActions(_ card: UpdateCard) {
        let actions = [card.primary].compactMap { $0 } + card.secondary
        let keys = actions.map(ActionKey.init)
        actionsStack.isHidden = actions.isEmpty
        guard keys != drawnActions else { return }
        drawnActions = keys
        for view in actionsStack.arrangedSubviews {
            actionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for action in actions { actionsStack.addArrangedSubview(button(for: action)) }
        actionsStack.addArrangedSubview(RowKit.spacer())
    }

    /// Every offer is drawn the same way on purpose: the primary press looks the part but claims no
    /// keyboard shortcut, because a board holding two servers' updates must never install whichever
    /// one AppKit last decided was the default the moment somebody hit Return.
    private func button(for action: UpdateCard.Action) -> NSButton {
        guard action.prominent else {
            let button = RowKit.linkButton(action.title, enabled: action.enabled) {
                [weak self] in self?.onAction?(action)
            }
            button.font = MacTheme.Ramp.font(.control)
            if case .setAside = action.kind { button.contentTintColor = MacTheme.Color.secondaryLabel }
            return button
        }
        let button = RowKit.ActionButton(title: action.title) { [weak self] in
            self?.onAction?(action)
        }
        button.bezelStyle = .rounded
        button.font = MacTheme.Ramp.font(.control)
        button.keyEquivalent = ""
        button.bezelColor = MacTheme.Color.accent
        button.isEnabled = action.enabled
        return button
    }

    private func renderAutomation(_ automation: UpdateCard.Automation?) {
        automationRow.isHidden = automation == nil
        guard let automation else { return }
        automationCheckbox.title = automation.title
        automationCheckbox.state = automation.isOn ? .on : .off
        automationCheckbox.isEnabled = true
        automationStatus.stringValue = automation.status
    }

    /// The machine did not change its policy; the checkbox goes back to what the machine last said.
    func restoreAutomation() {
        renderAutomation(card?.automation)
    }

    @objc private func automationToggled() {
        let wanted = automationCheckbox.state == .on
        automationCheckbox.isEnabled = false
        onAutomation?(wanted)
    }

    private func renderFacts(_ facts: [UpdateCard.Fact]) {
        detailsButton.isHidden = facts.isEmpty
        detailsButton.title = Localized.text("Details")
        detailsButton.image = NSImage(
            systemSymbolName: detailsExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil)
        factsStack.isHidden = facts.isEmpty || !detailsExpanded
        guard facts != drawnFacts else { return }
        drawnFacts = facts
        for view in factsStack.arrangedSubviews {
            factsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for fact in facts { factsStack.addArrangedSubview(FactRow(fact: fact)) }
    }

    private func toggleDetails() {
        detailsExpanded.toggle()
        renderFacts(drawnFacts)
    }

    /// A clock that ticks only while there is a step under way and somebody could see it.
    private func runClock() {
        guard window != nil, clockLabel != nil, clockSince != nil else {
            clock?.invalidate()
            clock = nil
            clockLabel?.stringValue = ""
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
        clockLabel.stringValue = RelativeWhen.clock(Date().timeIntervalSince(since))
    }

    private func write(_ label: NSTextField, _ text: String?) {
        label.isHidden = text == nil
        label.stringValue = text ?? ""
    }

    /// The tokens are values rather than dynamic colours and the fonts carry the type scale, so a
    /// theme or scale change has to reach every label of a card that is already on screen.
    func applyTheme() {
        if style == .standalone {
            layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
            layer?.borderColor = MacTheme.Color.separator.cgColor
        }
        machineLabel.font = MacTheme.Ramp.font(.sectionLabel)
        machineLabel.textColor = MacTheme.Color.secondaryLabel
        headlineLabel.font = MacTheme.Ramp.font(.cardTitle)
        headlineLabel.textColor = card?.stage == .failed ? MacTheme.Color.danger : MacTheme.Color.label
        versionLabel.font = MacTheme.Ramp.font(.panelLabel)
        versionLabel.textColor = MacTheme.Color.secondaryLabel
        messageLabel.font = MacTheme.Ramp.font(.panelDetail)
        messageLabel.textColor = MacTheme.Color.secondaryLabel
        notesTitleLabel.font = MacTheme.Ramp.font(.sectionLabel)
        notesTitleLabel.textColor = MacTheme.Color.secondaryLabel
        moreNotesButton.font = MacTheme.Ramp.font(.control)
        moreNotesButton.contentTintColor = MacTheme.Color.accent
        automationCheckbox.font = MacTheme.Ramp.font(.panelLabel)
        automationStatus.font = MacTheme.Ramp.font(.panelFootnote)
        automationStatus.textColor = MacTheme.Color.secondaryLabel
        detailsButton.font = MacTheme.Ramp.font(.control)
        detailsButton.contentTintColor = MacTheme.Color.secondaryLabel
        footnoteLabel.font = MacTheme.Ramp.font(.panelFootnote)
        footnoteLabel.textColor = MacTheme.Color.tertiaryLabel
        for view in stepsStack.arrangedSubviews.compactMap({ $0 as? StepRow }) { view.applyTheme() }
        for view in factsStack.arrangedSubviews.compactMap({ $0 as? FactRow }) { view.applyTheme() }
        for view in notesStack.arrangedSubviews.compactMap({ $0 as? Bullet }) { view.applyTheme() }
    }

    /// AppKit resolves a `CGColor` once, against the appearance in force when it was asked for, so
    /// the card's ground and hairline are the two things a light↔dark flip cannot reach on its own.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
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
private final class StepRow: NSView {
    let clock = NSTextField(labelWithString: "")
    private let title: NSTextField
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let glyph: NSView
    private let state: UpdateCard.Step.State

    init(step: UpdateCard.Step) {
        state = step.state
        switch step.state {
        case .active:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)
            glyph = spinner
        case .done, .pending, .failed:
            let image = NSImageView()
            image.image = NSImage(
                systemSymbolName: Self.symbol(step.state), accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            image.contentTintColor = Self.tint(step.state)
            image.translatesAutoresizingMaskIntoConstraints = false
            glyph = image
        }
        title = NSTextField(labelWithString: step.title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        clock.setContentHuggingPriority(.required, for: .horizontal)
        clock.translatesAutoresizingMaskIntoConstraints = false
        update(detail: step.detail)

        let line = NSStackView(views: [title, RowKit.spacer(), clock])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.translatesAutoresizingMaskIntoConstraints = false
        let text = FillingStack(views: [line, detail])
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [glyph, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(
            [step.title, Self.spoken(step.state), step.detail].compactMap { $0 }
                .joined(separator: ", "))
        applyTheme()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(detail text: String?) {
        detail.stringValue = text ?? ""
        detail.isHidden = text == nil
    }

    func applyTheme() {
        title.font = MacTheme.Ramp.font(state == .active ? .rowTitleStrong : .rowTitle)
        title.textColor =
            state == .pending
            ? MacTheme.Color.tertiaryLabel : state == .failed ? MacTheme.Color.danger : MacTheme.Color.label
        clock.font = MacTheme.Ramp.font(.rowStamp)
        clock.textColor = MacTheme.Color.secondaryLabel
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
    }

    private static func symbol(_ state: UpdateCard.Step.State) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending, .active: return "circle"
        }
    }

    private static func tint(_ state: UpdateCard.Step.State) -> NSColor {
        switch state {
        case .done: return MacTheme.Color.success
        case .failed: return MacTheme.Color.danger
        case .pending, .active: return MacTheme.Color.tertiaryLabel
        }
    }

    private static func spoken(_ state: UpdateCard.Step.State) -> String {
        switch state {
        case .done: return Localized.text("done")
        case .active: return Localized.text("under way")
        case .pending: return Localized.text("not started")
        case .failed: return Localized.text("failed")
        }
    }
}

/// One line of what is new.
@MainActor
private final class Bullet: NSView {
    private let dot = NSTextField(labelWithString: "•")
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(text)
        applyTheme()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        dot.font = MacTheme.Ramp.font(.panelDetail)
        dot.textColor = MacTheme.Color.accent
        label.font = MacTheme.Ramp.font(.panelDetail)
        label.textColor = MacTheme.Color.label
    }
}

/// A number the card rests on, with who said it. Selectable rather than menu-driven — this is an
/// ordinary `NSTextField`, and the system's own Copy already reaches selected text.
@MainActor
private final class FactRow: NSView {
    private let label: NSTextField
    private let value: NSTextField

    init(fact: UpdateCard.Fact) {
        label = NSTextField(labelWithString: fact.label)
        value = NSTextField(wrappingLabelWithString: fact.value)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        value.isSelectable = true
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = FillingStack(views: [label, value])
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("\(fact.label): \(fact.value)")
        applyTheme()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        label.font = MacTheme.Ramp.font(.panelFootnote)
        label.textColor = MacTheme.Color.tertiaryLabel
        value.font = MacTheme.Ramp.font(.panelFootnote)
        value.textColor = MacTheme.Color.secondaryLabel
    }
}

/// A state's symbol with the state's motion attached, which starts its own clock the moment it
/// lands in a window — a mark built before it is added to anything would otherwise never move,
/// and one taken off screen would keep a display link running for nobody.
///
/// A sweep is a rotation here rather than a cycle of glyphs, because this client draws pictures.
/// The symbol turns inside a holder this view frames by hand, the way every other sweeping badge
/// on this desk does: `frameCenterRotation` is about a view's centre and autolayout would undo it
/// on the next pass, so the thing that turns is never the thing autolayout places.
@MainActor
final class UpdateMarkView: NSView {
    private let holder = NSView()
    private let imageView = NSImageView()
    private lazy var pulse = ActivityPulse(view: holder)
    private let pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyDown
        holder.addSubview(imageView)
        addSubview(holder)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
        pulse.onTurn = { [weak self] degrees in self?.holder.frameCenterRotation = degrees }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A fixed square rather than the symbol's own size: a mark that re-measured when its state
    /// changed would move the title beside it, and a frame may change light, never layout.
    override var intrinsicContentSize: NSSize {
        NSSize(width: pointSize + 5, height: pointSize + 5)
    }

    override func layout() {
        super.layout()
        let rotation = holder.frameCenterRotation
        holder.frameCenterRotation = 0
        holder.frame = bounds
        imageView.frame = holder.bounds
        holder.frameCenterRotation = rotation
    }

    func apply(_ icon: ActivityIcon?) {
        guard let icon else {
            imageView.image = nil
            holder.frameCenterRotation = 0
            pulse.apply(nil)
            return
        }
        imageView.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        imageView.contentTintColor = icon.tone.color
        if !icon.motion.isAnimated { holder.frameCenterRotation = 0 }
        pulse.apply(icon)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pulse.windowChanged()
    }
}

/// The standing mark at the foot of the chat list: what every machine in the picture adds up to,
/// in one line that opens the Update Center.
///
/// It is drawn from `UpdateLedger`, which is why it is on screen before any check of this launch
/// has come back and why it survives a relaunch. It covers nothing, steals no focus, and there is
/// no gesture here that dismisses it: the row goes out when the rollup stops standing, and setting
/// an offer aside is a decision made in the Update Center against that exact offer.
@MainActor
final class UpdateFooterView: NSView {
    var onOpen: (() -> Void)?

    private let mark = UpdateMarkView(pointSize: 12)
    private let titleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [mark, titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        HoverPlate.attach(to: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: MacUpdateWatch.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: MacTheme.Chrome.didRepaint, object: nil)
        isHidden = true
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The type is read here rather than kept from `init`: the ramp is a live preference, and a row
    /// that took its size once would sit at 10 points between neighbours that had doubled.
    func render() {
        titleLabel.font = MacTheme.Ramp.font(.panelFootnote)
        let rollup = UpdateLedger.rollup()
        guard let chip = rollup.chip else {
            isHidden = true
            mark.apply(nil)
            return
        }
        isHidden = false
        mark.apply(ActivityIcon(symbol: chip.symbol, glyph: "•", tone: chip.tone, motion: chip.motion))
        titleLabel.stringValue = chip.title
        titleLabel.textColor = chip.tone.color
        toolTip = rollup.accessibilityLine()
        setAccessibilityLabel(rollup.accessibilityLine())
    }

    /// A row that calls itself a button has to answer a press that did not come from a mouse: the
    /// click gesture is the pointer's road in, and this is VoiceOver's.
    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func changed() {
        render()
    }

    @objc private func clicked() {
        onOpen?()
    }
}

/// A toolbar button wearing the standing mark: a small tinted dot in its corner, on the control
/// somebody already reaches for when something needs deciding.
///
/// A dot rather than a count — the toolbar must not re-measure when a number changes — and it
/// holds perfectly still whatever the rollup is doing. Six points of colour have no way to express
/// a sweep, and a display link running for a rotation nobody could see is worse than stillness:
/// what an update in flight looks like is the mark at the foot of the chat list turning, and what
/// it says here is in the tooltip.
@MainActor
final class UpdateMarkButton: NSButton {
    private let dot = NSView()
    private let tip: String

    init(symbol: String, label: String, tip: String, target: AnyObject?, action: Selector) {
        self.tip = tip
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        setButtonType(.momentaryPushIn)
        bezelStyle = .toolbar
        isBordered = true
        self.target = target
        self.action = action
        toolTip = tip
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The dot is the whole of what this button says about the mark, and a tooltip is not read
    /// aloud — so what it says goes into the label too, or a VoiceOver user is never told at all.
    func render() {
        guard let chip = UpdateLedger.rollup().chip else {
            dot.isHidden = true
            toolTip = tip
            setAccessibilityLabel(tip)
            return
        }
        dot.isHidden = false
        dot.layer?.backgroundColor = chip.tone.color.cgColor
        toolTip = Localized.text("%@ — %@", tip, chip.title)
        setAccessibilityLabel(toolTip)
    }

    /// Six points of `CGColor` resolved under the previous appearance is the one thing a flip to
    /// dark leaves behind here.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }
}

/// A card's press, carried out. Shared by the Software Updates window and a server's own row, so a
/// press drawn in two places is kept one way — and the question asked before a restart is Core's,
/// word for word, on every desk.
@MainActor
enum UpdatePress {
    static func perform(
        _ action: UpdateCard.Action, for reading: UpdateReading, from window: NSWindow?,
        status: (String) -> Void = { _ in }
    ) {
        switch action.kind {
        case .invitation(let invitation):
            take(invitation, action: action, reading: reading, from: window, status: status)
        case .setAside:
            UpdateLedger.acknowledge(reading)
        case .showLog:
            UpdateLogWindowController.present(title: reading.title, log: reading.log ?? "")
        case .checkNow:
            Task { await MacUpdateWatch.shared.check(reading.component) }
        }
    }

    private static func take(
        _ invitation: UpdateInvitation, action: UpdateCard.Action, reading: UpdateReading,
        from window: NSWindow?, status: (String) -> Void
    ) {
        switch invitation {
        case .installHere, .restartHere:
            guard let confirmation = action.confirmation else {
                start(reading)
                return
            }
            MacDialogs.confirm(
                on: window, title: confirmation.title, body: confirmation.message,
                confirmLabel: confirmation.confirm, destructive: false
            ) { start(reading) }
        case .openStore(let url), .openPage(let url):
            guard let target = URL(string: url) else { return }
            NSWorkspace.shared.open(target)
        case .copyCommand(let command):
            RowKit.copyToClipboard(command)
            status(
                [Localized.text("Command copied"), invitation.promise].compactMap { $0 }
                    .joined(separator: " — "))
        case .recheck:
            Task { await MacUpdateWatch.shared.check(reading.component) }
        }
    }

    private static func start(_ reading: UpdateReading) {
        Task { await MacUpdateWatch.shared.perform(reading.component) }
    }

    /// Turning a machine's own policy on or off. The card draws the checkbox from what the machine
    /// said; a refusal puts it back there and says why.
    static func setAutomation(_ enabled: Bool, for reading: UpdateReading, card: UpdateCardView) {
        Task {
            guard
                let failure = await MacUpdateWatch.shared.setAutoUpdate(reading.component, enabled)
            else { return }
            card.restoreAutomation()
            MacDialogs.confirm(
                on: card.window,
                title: Localized.text("%@ didn't change its update setting", reading.title),
                body: failure, confirmLabel: Localized.text("OK"), destructive: false
            ) {}
        }
    }
}

/// What a failed update printed, readable and copyable, in a window of its own — held statically
/// because a window presented from a local variable is dead on arrival, released while it is still
/// on screen.
@MainActor
final class UpdateLogWindowController: NSWindowController {
    private static var current: UpdateLogWindowController?

    static func present(title: String, log: String) {
        let controller = UpdateLogWindowController(title: title, log: log)
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(title: String, log: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
            defer: false)
        window.title = Localized.text("%@ — update log", title)
        window.isReleasedWhenClosed = false
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        window.contentView = Self.makeContent(log: log)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func makeContent(log: String) -> NSView {
        let textView = NSTextView()
        textView.string = log
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = MacTheme.Ramp.font(.code)
        textView.textColor = MacTheme.Color.label
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: MacTheme.Spacing.m, height: MacTheme.Spacing.m)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = MacTheme.Color.canvas
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copy = RowKit.ActionButton(title: Localized.text("Copy")) {
            RowKit.copyToClipboard(log)
        }
        copy.bezelStyle = .rounded
        let row = NSStackView(views: [RowKit.spacer(), copy])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(row)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -MacTheme.Spacing.s),
            row.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.m),
            row.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.m),
            row.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -MacTheme.Spacing.m),
        ])
        return container
    }
}
