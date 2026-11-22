import AppKit
import CodingAgentKit
import TailscodeCore

/// The sidebar's way to the schedules every machine keeps: the Scheduled tile beside Agents, whose
/// tooltip is the one line Home wears on the phone — what asks next, when and where. It is there
/// only while some machine keeps schedules, and a press opens the Scheduled window.
@MainActor
final class ScheduledSidebarEntry: SidebarPlaceTile {
    private var line = ""
    var onOpen: (() -> Void)?

    /// What the entry says about the next schedule, for a harness.
    var lineText: String { line }

    init() {
        super.init(symbol: "clock", caption: ScheduleWords.title)
        onPress = { [weak self] in self?.onOpen?() }
        render()
        NotificationCenter.default.addObserver(
            forName: MachineDesk.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    /// Shown while any machine keeps schedules; the line is Home's, or nothing to say yet.
    func render() {
        let desk = MachineDesk.shared
        isHidden = !desk.anyKeepsSchedules && desk.board.isEmpty
        line = desk.board.homeLine() ?? ScheduleWords.empty
        toolTip = line
        setAccessibilityLabel(ScheduleWords.title + ", " + line)
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
