import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// A machine's Agents section and its Scheduled line, inside its row of the Servers window: the
/// machine's own agent first, built in, then every agent the machine knows in one line each
/// (`MachineAgentReading`), Add on one found and never added, a press on any other opening its
/// card, and More agents… for the ACP registry. Drawn only for a machine that answers — a machine
/// that hosts no other agents and keeps no schedules shows nothing here rather than an empty list.
@MainActor
final class MachineAgentsSection: NSView {
    let profile: ConnectionProfile
    private let column = FillingStack(views: [])
    private let agentsHeader = MacDialogs.sectionHeader(MachineAgentReading.section.uppercased())
    private let rowsColumn = NSStackView()
    private let more = NSButton()
    private let moreRow = NSStackView()
    private let note = MacDialogs.detailLabel(MachineAgentReading.permissionNote, wraps: true)
    private let scheduledHeader = MacDialogs.sectionHeader(ScheduleWords.title.uppercased())
    private let scheduledLine = MacDialogs.detailLabel("")
    private let scheduledOpen = NSButton()
    private let scheduledRow = NSStackView()
    var onOpenAgent: ((ConnectionProfile, String) -> Void)?
    var onOpenRegistry: ((ConnectionProfile) -> Void)?
    var onOpenScheduled: ((String) -> Void)?
    var onToast: ((String) -> Void)?

    /// The rows as drawn, for a harness: the title and the words under it.
    var rowTexts: [(String, String)] {
        rowsColumn.arrangedSubviews.compactMap { ($0 as? AgentLineView).map { ($0.titleText, $0.subtitleText) } }
    }
    var showsAgents: Bool { !agentsHeader.isHidden }

    init(profile: ConnectionProfile) {
        self.profile = profile
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rowsColumn.orientation = .vertical
        rowsColumn.alignment = .leading
        rowsColumn.spacing = 2
        more.title = MachineAgentReading.moreAgents
        more.bezelStyle = .inline
        more.target = self
        more.action = #selector(moreTapped)
        scheduledOpen.title = Localized.text("Open")
        scheduledOpen.bezelStyle = .inline
        scheduledOpen.target = self
        scheduledOpen.action = #selector(scheduledTapped)
        scheduledLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scheduledRow.setViews([scheduledLine, scheduledOpen], in: .leading)
        scheduledRow.orientation = .horizontal
        scheduledRow.spacing = MacTheme.Spacing.s
        column.spacing = MacTheme.Spacing.xs
        column.edgeInsets = NSEdgeInsets(top: MacTheme.Spacing.s, left: 0, bottom: 0, right: 0)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        moreRow.setViews([more, spacer], in: .leading)
        moreRow.orientation = .horizontal
        for view in [agentsHeader, rowsColumn, moreRow, note, scheduledHeader, scheduledRow] {
            column.addArrangedSubview(view)
        }
        column.setCustomSpacing(MacTheme.Spacing.m, after: note)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        render()
        NotificationCenter.default.addObserver(
            forName: MachineDesk.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render() {
        let desk = MachineDesk.shared
        let report = desk.reports[profile.id]
        let showsAgents = report != nil
        for view in [agentsHeader, rowsColumn, moreRow, note] { view.isHidden = !showsAgents }
        rowsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if showsAgents {
            let builtIn: AgentType? = profile.backend == .omp ? nil : profile.backend
            for row in MachineAgentReading.rows(report, machine: profile.name, builtIn: builtIn) {
                let line = AgentLineView(row: row) { [weak self] press in self?.pressed(row, press) }
                rowsColumn.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: rowsColumn.widthAnchor).isActive = true
            }
        }
        let keeps = desk.keepsSchedules(profile.id)
        scheduledHeader.isHidden = !keeps
        scheduledRow.isHidden = !keeps
        if keeps {
            let mine = desk.board.rows.filter { $0.profileID == profile.id }
            if mine.isEmpty {
                scheduledLine.stringValue = ScheduleWords.empty
            } else {
                let mineBoard = ScheduleBoard(rows: mine)
                let count = Localized.text("%d scheduled", mine.count)
                scheduledLine.stringValue = [count, mineBoard.homeLine() ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            }
        }
        isHidden = !showsAgents && !keeps
    }

    private func pressed(_ row: AgentRowReading, _ press: AgentPress?) {
        guard !row.isBuiltIn else { return }
        guard let press, press == .add else {
            onOpenAgent?(profile, row.id)
            return
        }
        guard let hosting = MachineDesk.shared.hosting(for: profile.id) else { return }
        let profileID = profile.id
        let name = row.title
        onToast?(Localized.text("Adding %@…", name))
        Task { [weak self] in
            do {
                let agent = try await hosting.addAgent(row.id)
                AgentNewsStore.markSeen([agent], profileID: profileID)
                await MachineDesk.shared.refreshAgents(profileID: profileID)
                let state = MachineAgentReading.state(agent, machine: self?.profile.name ?? "")
                self?.onToast?("\(name): \(state.0)")
            } catch {
                self?.onToast?(AgentErrorText.readable(error))
                await MachineDesk.shared.refreshAgents(profileID: profileID)
            }
        }
    }

    @objc private func moreTapped() { onOpenRegistry?(profile) }
    @objc private func scheduledTapped() { onOpenScheduled?(profile.id) }
}

/// One agent in a machine's section: its initial, its name and state in words, and the one press
/// its row offers — Add for one found and never added, Open for the rest.
@MainActor
final class AgentLineView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let onPress: (AgentPress?) -> Void
    private let press: AgentPress?

    var titleText: String { title.stringValue }
    var subtitleText: String { subtitle.stringValue }

    init(row: AgentRowReading, onPress: @escaping (AgentPress?) -> Void) {
        self.onPress = onPress
        press = row.press
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let mark = NSTextField(labelWithString: row.initial)
        mark.font = .systemFont(ofSize: 12 * MacTheme.UIScale.factor, weight: .bold)
        mark.alignment = .center
        mark.textColor = MacTheme.Color.onAccent
        mark.wantsLayer = true
        mark.drawsBackground = true
        mark.backgroundColor = Self.markColor(row)
        mark.layer?.cornerRadius = 5
        mark.translatesAutoresizingMaskIntoConstraints = false
        let side = (22 * MacTheme.UIScale.factor).rounded()
        mark.widthAnchor.constraint(equalToConstant: side).isActive = true
        mark.heightAnchor.constraint(equalToConstant: side).isActive = true
        title.stringValue = row.title
        title.font = MacTheme.Ramp.font(.rowTitle)
        subtitle.stringValue = row.subtitle
        subtitle.font = MacTheme.Ramp.font(.panelFootnote)
        subtitle.textColor = Self.toneColor(row.tone)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lines = NSStackView(views: [title, subtitle])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 0
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var views: [NSView] = [mark, lines, spacer]
        if !row.isBuiltIn {
            let button = RowKit.ActionButton(title: row.pressTitle ?? Localized.text("Open…")) {
                [weak self] in self?.onPress(self?.press)
            }
            button.bezelStyle = .inline
            button.controlSize = .small
            button.setAccessibilityLabel((row.pressTitle ?? Localized.text("Open…")) + " " + row.title)
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = MacTheme.Spacing.s
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(row.title + ", " + row.subtitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func toneColor(_ tone: AgentTone) -> NSColor {
        switch tone {
        case .ready: return MacTheme.Color.success
        case .attention: return MacTheme.Color.warning
        case .working: return MacTheme.Color.accent
        case .failed: return MacTheme.Color.danger
        case .neutral: return MacTheme.Color.secondaryLabel
        }
    }

    /// The initial's ground: the brand of the machine's own agent, the tone for the others, so a
    /// row that needs something reads as such before its words are.
    static func markColor(_ row: AgentRowReading) -> NSColor {
        if row.isBuiltIn { return MacTheme.Color.claude }
        switch row.tone {
        case .ready: return MacTheme.Color.accent
        case .attention: return MacTheme.Color.warning
        case .failed: return MacTheme.Color.danger
        case .working, .neutral: return .systemGray
        }
    }
}
