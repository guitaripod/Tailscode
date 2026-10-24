import AppKit
import CodingAgentKit
import TailscodeCore

/// What an agent asks and the answer in place: the command or the question word for word in a
/// monospaced block that wraps and can be selected, then Deny and Approve, or one button per
/// option. The card in the list and the peek in the inspector both hold one, so the two always
/// agree about what has been pressed.
@MainActor
final class AgentsAskBlockView: NSView {
    var onDecide: ((Bool) -> Void)?
    var onOption: ((String) -> Void)?

    private let column = FillingStack(topDown: false, stretches: true)
    private let commandBox = NSView()
    private let command = NSTextField(wrappingLabelWithString: "")
    private let commandScroll = NSScrollView()
    /// How tall the command may stand before it scrolls inside the card instead of pushing it down.
    static let commandCeiling: CGFloat = 220
    private let deny = NSButton(title: "", target: nil, action: nil)
    private let approve = NSButton(title: "", target: nil, action: nil)
    private let decisions = NSStackView()
    private let options = FillingStack(topDown: false, stretches: true)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var optionButtons: [AgentsOptionButton] = []
    private(set) var ask: AgentAsk?

    var buttons: [NSControl] {
        optionButtons.isEmpty ? [deny, approve] : optionButtons
    }

    var statusText: String { status.isHidden ? "" : status.stringValue }
    var commandText: String { command.stringValue }
    var commandHeight: CGFloat { command.frame.height }
    var commandBoxHeight: CGFloat { commandBox.frame.height }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        command.font = MacTheme.Ramp.font(.code)
        command.textColor = MacTheme.Color.label
        command.isSelectable = true
        command.lineBreakMode = .byWordWrapping
        command.maximumNumberOfLines = 0
        command.translatesAutoresizingMaskIntoConstraints = false
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandBox.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(command)
        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        commandScroll.contentView = clip
        commandScroll.documentView = document
        commandScroll.drawsBackground = false
        commandScroll.hasVerticalScroller = true
        commandScroll.scrollerStyle = .overlay
        commandScroll.autohidesScrollers = true
        commandScroll.translatesAutoresizingMaskIntoConstraints = false
        commandBox.addSubview(commandScroll)
        RowKit.ground(
            behind: commandBox, fill: MacTheme.Color.codeBackground, stroke: nil,
            radius: MacTheme.Radius.control)
        let inset = MacTheme.Spacing.s
        let fits = commandScroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        fits.priority = NSLayoutConstraint.Priority(749)
        command.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            command.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset),
            command.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -inset),
            command.topAnchor.constraint(equalTo: document.topAnchor, constant: inset),
            command.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -inset),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            commandScroll.leadingAnchor.constraint(equalTo: commandBox.leadingAnchor),
            commandScroll.trailingAnchor.constraint(equalTo: commandBox.trailingAnchor),
            commandScroll.topAnchor.constraint(equalTo: commandBox.topAnchor),
            commandScroll.bottomAnchor.constraint(equalTo: commandBox.bottomAnchor),
            commandScroll.heightAnchor.constraint(lessThanOrEqualToConstant: Self.commandCeiling),
            fits,
        ])

        for (button, action) in [(deny, #selector(denied)), (approve, #selector(approved))] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        approve.bezelColor = MacTheme.Color.accent
        approve.tintProminence = .primary
        decisions.orientation = .horizontal
        decisions.distribution = .fillEqually
        decisions.spacing = MacTheme.Spacing.s
        decisions.translatesAutoresizingMaskIntoConstraints = false
        decisions.addArrangedSubview(deny)
        decisions.addArrangedSubview(approve)

        options.spacing = MacTheme.Spacing.xs
        status.font = MacTheme.Ramp.font(.panelFootnote)
        status.isSelectable = true
        status.translatesAutoresizingMaskIntoConstraints = false
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        column.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(commandBox)
        column.addArrangedSubview(decisions)
        column.addArrangedSubview(options)
        column.addArrangedSubview(status)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// - Parameters:
    ///   - away: the machine stopped answering, so no button may be pressed.
    ///   - note: the line that says why, when it is `away`.
    func configure(ask: AgentAsk, phase: AgentsActions.Phase, away: Bool, note: String?) {
        self.ask = ask
        if command.stringValue != (ask.object ?? "") { command.stringValue = ask.object ?? "" }
        commandBox.isHidden = (ask.object ?? "").isEmpty
        let isApproval = ask.isApproval
        decisions.isHidden = !isApproval
        options.isHidden = isApproval || ask.options.isEmpty
        if !isApproval { syncOptions(ask.options) }
        let busy: Bool
        switch phase {
        case .inFlight, .sent: busy = true
        case .idle, .failed: busy = false
        }
        let live = !busy && !away
        deny.isEnabled = live
        approve.isEnabled = live
        for button in optionButtons { button.isEnabled = live }
        deny.title = title(for: .deny, phase: phase, rest: Localized.text("Deny"))
        approve.title = title(for: .approve, phase: phase, rest: Localized.text("Approve"))
        for button in optionButtons {
            let verb = AgentsActions.Verb.option(button.title)
            button.chosen = phase == .inFlight(verb) || phase == .sent(verb)
        }
        var line: String?
        var tint = MacTheme.Color.secondaryLabel
        switch phase {
        case .failed(let why):
            line = Localized.text("Could not send it: %@", why)
            tint = MacTheme.Color.danger
        case .inFlight(.option):
            line = Localized.text("Sending…")
        case .sent(.option):
            line = Localized.text("Sent")
        default:
            break
        }
        if away, let note { line = note }
        status.stringValue = line ?? ""
        status.textColor = tint
        status.isHidden = line == nil
    }

    private func title(for verb: AgentsActions.Verb, phase: AgentsActions.Phase, rest: String) -> String {
        switch phase {
        case .inFlight(verb):
            return verb == .approve ? Localized.text("Approving…") : Localized.text("Denying…")
        case .sent(verb):
            return verb == .approve ? Localized.text("Approved") : Localized.text("Denied")
        default:
            return rest
        }
    }

    private func syncOptions(_ titles: [String]) {
        guard optionButtons.map(\.title) != titles else { return }
        for button in optionButtons {
            options.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        optionButtons = titles.map { title in
            let button = AgentsOptionButton(title: title)
            button.target = self
            button.action = #selector(optionPressed(_:))
            options.addArrangedSubview(button)
            return button
        }
    }

    @objc private func denied() { onDecide?(false) }
    @objc private func approved() { onDecide?(true) }

    @objc private func optionPressed(_ sender: AgentsOptionButton) {
        onOption?(sender.title)
    }
}

/// A session waiting on a person: why, which chat and machine, how long, and the ask in place.
@MainActor
final class AgentsAskCardView: NSView {
    private let glyph = NSImageView()
    private let lead = NSTextField(wrappingLabelWithString: "")
    private let wait = NSTextField(labelWithString: "")
    private let subject = NSTextField(wrappingLabelWithString: "")
    let block = AgentsAskBlockView(frame: .zero)
    private let column = FillingStack(topDown: false, stretches: true)
    private var since: Date?
    private(set) var card: AgentAskCard?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var waitText: String { wait.stringValue }
    var leadText: String { lead.stringValue }

    private func build() {
        glyph.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        glyph.contentTintColor = MacTheme.Color.warning
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        lead.font = MacTheme.Ramp.font(.cardTitle)
        lead.textColor = MacTheme.Color.warning
        lead.maximumNumberOfLines = 0
        lead.translatesAutoresizingMaskIntoConstraints = false
        lead.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wait.font = .monospacedDigitSystemFont(
            ofSize: MacTheme.Ramp.font(.rowStamp).pointSize, weight: .medium)
        wait.textColor = MacTheme.Color.warning
        wait.translatesAutoresizingMaskIntoConstraints = false
        wait.setContentHuggingPriority(.required, for: .horizontal)
        wait.setContentCompressionResistancePriority(.required, for: .horizontal)
        subject.font = MacTheme.Ramp.font(.rowDetail)
        subject.textColor = MacTheme.Color.secondaryLabel
        subject.isSelectable = true
        subject.maximumNumberOfLines = 0
        subject.translatesAutoresizingMaskIntoConstraints = false
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let head = NSStackView(views: [glyph, lead, wait])
        head.orientation = .horizontal
        head.distribution = .fill
        head.alignment = .top
        head.spacing = MacTheme.Spacing.s
        head.translatesAutoresizingMaskIntoConstraints = false

        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        column.addArrangedSubview(head)
        column.addArrangedSubview(subject)
        column.addArrangedSubview(block)
        RowKit.ground(
            behind: column, fill: MacTheme.Color.canvasRaised, stroke: MacTheme.Color.separator,
            radius: MacTheme.Radius.card)
        addSubview(column)
        let gutter = MacTheme.Spacing.m
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.xs),
        ])
        setAccessibilityElement(false)
    }

    func configure(
        _ card: AgentAskCard, phase: AgentsActions.Phase, showsMachine: Bool, context: AgentsContext
    ) {
        self.card = card
        since = card.ask.since
        lead.stringValue = card.ask.lead
        subject.stringValue = [card.title, showsMachine ? card.machine : nil]
            .compactMap { $0 }.joined(separator: " · ")
        block.configure(
            ask: card.ask, phase: phase, away: card.isAway,
            note: card.isAway
                ? AgentsWords.lastSeen(
                    context.lastHeard(card.profileID), now: context.now()) : nil)
        column.alphaValue = card.isAway ? 0.6 : 1
        tick(now: context.now())
        let spoken = [
            card.ask.lead, card.title, card.machine,
            card.ask.object ?? "",
        ].filter { !$0.isEmpty }.joined(separator: ", ")
        setAccessibilityLabel(spoken)
    }

    func tick(now: Date) {
        guard let since else {
            wait.stringValue = ""
            return
        }
        let text = AgentsWords.waiting(AgentsWords.elapsed(now.timeIntervalSince(since)))
        guard text != wait.stringValue else { return }
        wait.stringValue = text
    }
}
