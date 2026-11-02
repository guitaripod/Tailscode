import AppKit
import CodingAgentKit
import TailscodeCore

/// The sidebar's way to the schedules every machine keeps: "Scheduled" under Agents, wearing the
/// one line Home wears on the phone — what asks next, when and where — so a question left for the
/// morning is in view without opening anything. It is there only while some machine keeps
/// schedules, and a press opens the Scheduled window.
@MainActor
final class ScheduledSidebarEntry: NSControl {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: ScheduleWords.title)
    private let line = NSTextField(labelWithString: "")
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?
    var onOpen: (() -> Void)?

    /// What the entry says under its title, for a harness.
    var lineText: String { line.isHidden ? "" : line.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        icon.contentTintColor = MacTheme.Color.secondaryLabel
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        title.textColor = MacTheme.Color.label
        title.translatesAutoresizingMaskIntoConstraints = false
        line.font = MacTheme.Ramp.font(.panelFootnote)
        line.textColor = MacTheme.Color.secondaryLabel
        line.lineBreakMode = .byTruncatingTail
        line.translatesAutoresizingMaskIntoConstraints = false
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, title, line] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: MacTheme.Spacing.s),
            title.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs + 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            line.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            line.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        setContentHuggingPriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        render()
        NotificationCenter.default.addObserver(
            forName: MachineDesk.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let lineHeight = line.isHidden ? 0 : line.intrinsicContentSize.height + 1
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(32, title.intrinsicContentSize.height + lineHeight + 2 * (MacTheme.Spacing.xs + 2)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onOpen?() }

    override func keyDown(with event: NSEvent) {
        guard event.characters == " " || event.characters == "\r" else {
            super.keyDown(with: event)
            return
        }
        onOpen?()
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        MacTheme.Color.label.withAlphaComponent(0.06).setFill()
        NSBezierPath(
            roundedRect: bounds, xRadius: MacTheme.Radius.control, yRadius: MacTheme.Radius.control
        ).fill()
    }

    /// Shown while any machine keeps schedules; the line is Home's, or nothing to say yet.
    func render() {
        let desk = MachineDesk.shared
        isHidden = !desk.anyKeepsSchedules && desk.board.isEmpty
        let home = desk.board.homeLine()
        line.stringValue = home ?? ScheduleWords.empty
        line.isHidden = false
        setAccessibilityLabel(ScheduleWords.title + ", " + (home ?? ScheduleWords.empty))
        invalidateIntrinsicContentSize()
    }
}

/// Agents a machine has that nobody was told about, said once under the sidebar's entries: the
/// machine, the agents, and the two answers — add them to the model pill, or not now. Either answer
/// is remembered, so it is never said twice about the same agent.
@MainActor
final class AgentNewsView: NSView {
    private let headline = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let add = NSButton()
    private let later = NSButton()
    private var showing: (profileID: String, agents: [MachineAgent])?
    var onAdded: ((String) -> Void)?

    var headlineText: String { isHidden ? "" : headline.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = MacTheme.Radius.control
        headline.font = MacTheme.Ramp.font(.rowTitleStrong)
        headline.textColor = MacTheme.Color.label
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = MacTheme.Ramp.font(.rowMeta)
        detail.textColor = MacTheme.Color.secondaryLabel
        add.title = Localized.text("Add")
        add.bezelStyle = .push
        add.controlSize = .small
        add.keyEquivalent = ""
        add.target = self
        add.action = #selector(addTapped)
        later.title = Localized.text("Not now")
        later.bezelStyle = .push
        later.controlSize = .small
        later.target = self
        later.action = #selector(laterTapped)
        let buttons = NSStackView(views: [add, later])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.xs
        buttons.setHuggingPriority(.required, for: .horizontal)
        let column = NSStackView(views: [headline, detail, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s, right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            headline.widthAnchor.constraint(
                lessThanOrEqualTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.m),
        ])
        isHidden = true
        paint()
        NotificationCenter.default.addObserver(
            forName: MachineDesk.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        layer?.backgroundColor = MacTheme.Color.accent.withAlphaComponent(0.10).cgColor
    }

    func render() {
        guard let news = MachineDesk.shared.news(),
            let words = MachineAgentReading.news([(news.machine, news.agents)])
        else {
            showing = nil
            isHidden = true
            return
        }
        showing = (news.profileID, news.agents)
        headline.stringValue = words.title
        detail.stringValue = words.detail
        add.title = news.agents.count > 1 ? Localized.text("Add both") : Localized.text("Add")
        if news.agents.count > 2 { add.title = Localized.text("Add them") }
        isHidden = false
    }

    @objc private func addTapped() {
        guard let showing else { return }
        AgentNewsStore.markSeen(showing.agents, profileID: showing.profileID)
        isHidden = true
        let profileID = showing.profileID
        let ids = showing.agents.map(\.id)
        onAdded?(profileID)
        Task {
            guard let hosting = MachineDesk.shared.hosting(for: profileID) else { return }
            for id in ids { _ = try? await hosting.addAgent(id) }
            await MachineDesk.shared.refreshAgents(profileID: profileID)
        }
    }

    @objc private func laterTapped() {
        guard let showing else { return }
        AgentNewsStore.markSeen(showing.agents, profileID: showing.profileID)
        render()
    }
}
