import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The one door into delegation on the Mac. The store build sells Pro and gates here; a copy
/// somebody installed themselves has no receipt and is simply whole.
@MainActor
enum MacDelegateGate {
    static let desk = DelegateDesk(secrets: KeychainSecretStore())

    static var isOpen: Bool {
        DelegateProGate.allows(
            isPro: MacProStore.shared.isPro, sells: MacProStore.shared.sellsPro,
            demo: ServerDirectory.shared.isDemoMode)
    }
}

/// One window for every dispatcher this Mac talks to: the machine on the left with its ladder and
/// its runs, the run being read on the right. Every word is `DelegateBoard`'s and
/// `DelegateRunStory`'s; this window draws rows and forwards clicks to the desk.
@MainActor
final class DelegateWindowController: NSWindowController {
    private let desk = MacDelegateGate.desk
    private let serverPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let statusBadge = ActivityBadgeView()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let passwordButton = RowKit.ActionButton(title: Localized.text("Password…"), action: {})
    private let newButton = RowKit.ActionButton(title: DelegateEntryPoint.newPacketTitle, action: {})
    private let tiersColumn = NSStackView()
    private let runsColumn = NSStackView()
    private let statsColumn = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let runView = DelegateRunView()
    private var hosts: [(host: String, name: String)] = []
    private var selectedHost: String?
    private var selectedRun: String?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = DelegateEntryPoint.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 520)
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        passwordButton.setAction { [weak self] in self?.askPassword() }
        newButton.setAction { [weak self] in self?.compose() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: DelegateDesk.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        runView.onSelectRun = { [weak self] runID in self?.select(runID: runID) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        reloadHosts()
        window?.makeKeyAndOrderFront(nil)
        if let host = selectedHost, desk.boards[host]?.phase == .idle || desk.boards[host] == nil {
            probe()
        }
        render()
    }

    private var board: DelegateBoard? {
        guard let host = selectedHost else { return nil }
        return desk.boards[host]
    }

    private var serverName: String {
        hosts.first { $0.host == selectedHost }?.name ?? selectedHost ?? ""
    }

    private func reloadHosts() {
        var seen: Set<String> = []
        hosts = ServerDirectory.shared.profiles.compactMap { profile in
            guard let host = profile.baseURL.host, seen.insert(host).inserted else { return nil }
            return (host, profile.name)
        }
        serverPopup.removeAllItems()
        serverPopup.addItems(withTitles: hosts.map { "\($0.name) · \($0.host)" })
        if selectedHost == nil || !hosts.contains(where: { $0.host == selectedHost }) {
            selectedHost = hosts.first?.host
        }
        if let index = hosts.firstIndex(where: { $0.host == selectedHost }) {
            serverPopup.selectItem(at: index)
        }
    }

    private func makeContent() -> NSView {
        let root = NSView()
        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = MacTheme.Spacing.s
        left.translatesAutoresizingMaskIntoConstraints = false

        serverPopup.target = self
        serverPopup.action = #selector(serverChanged)
        left.addArrangedSubview(serverPopup)

        let statusRow = NSStackView(views: [statusBadge, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = MacTheme.Spacing.s
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        left.addArrangedSubview(statusRow)

        let buttons = NSStackView(views: [newButton, passwordButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fill
        buttons.spacing = MacTheme.Spacing.s
        buttons.heightAnchor.constraint(equalToConstant: 26).isActive = true
        left.addArrangedSubview(buttons)

        noteLabel.font = MacTheme.Ramp.font(.rowNote)
        noteLabel.textColor = MacTheme.Color.mark
        left.addArrangedSubview(noteLabel)

        left.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("LADDER")))
        tiersColumn.orientation = .vertical
        tiersColumn.alignment = .leading
        tiersColumn.spacing = MacTheme.Spacing.xs
        left.addArrangedSubview(tiersColumn)

        left.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("RUNS")))
        runsColumn.orientation = .vertical
        runsColumn.alignment = .width
        runsColumn.spacing = MacTheme.Spacing.xs
        emptyLabel.font = MacTheme.Ramp.font(.panelFootnote)
        emptyLabel.textColor = MacTheme.Color.secondaryLabel
        let runsScroll = MacDialogs.scrollColumn(holding: runsColumn)
        left.addArrangedSubview(runsScroll)

        left.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("PASS RATES")))
        statsColumn.orientation = .vertical
        statsColumn.alignment = .leading
        statsColumn.spacing = MacTheme.Spacing.xs
        left.addArrangedSubview(statsColumn)

        for view in [serverPopup, statusRow, noteLabel, tiersColumn, runsScroll, statsColumn] {
            view.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        }
        runsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        runsScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        statusLabel.widthAnchor.constraint(equalTo: statusRow.widthAnchor, constant: -24).isActive = true

        runView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(left)
        root.addSubview(runView)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: root.topAnchor, constant: MacTheme.Spacing.l),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: MacTheme.Spacing.l),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -MacTheme.Spacing.l),
            left.widthAnchor.constraint(equalToConstant: 320),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: MacTheme.Spacing.l),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            runView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            runView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            runView.topAnchor.constraint(equalTo: root.topAnchor),
            runView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    @objc private func serverChanged() {
        guard let picked = hosts.element(at: serverPopup.indexOfSelectedItem) else { return }
        selectedHost = picked.host
        selectedRun = nil
        if desk.boards[picked.host] == nil || desk.boards[picked.host]?.phase == .idle { probe() }
        render()
    }

    private func probe() {
        guard let host = selectedHost else { return }
        desk.probe(host: host, serverName: serverName)
    }

    @objc private func deskChanged() { render() }

    @objc private func repaint() { render() }

    private func render() {
        guard let host = selectedHost else {
            statusLabel.stringValue = Localized.text("Add a server first.")
            return
        }
        let board = desk.board(host: host, serverName: serverName)
        let reach = desk.reach[host] ?? .unknown
        statusLabel.stringValue = reach.isAnswering || board.statusLine == reach.line
            ? board.statusLine : board.statusLine + "\n" + reach.line
        statusLabel.font = MacTheme.Ramp.font(.panelLabel)
        statusLabel.textColor = board.statusTone == .quiet ? MacTheme.Color.secondaryLabel : board.statusTone.color
        statusBadge.show(board.phase == .checking ? ActivityKind.connecting.icon : nil, spoken: nil)
        newButton.isEnabled = board.isReady
        noteLabel.stringValue = board.note ?? ""
        noteLabel.isHidden = board.note == nil
        passwordButton.isHidden = desk.isDemo(host: host)

        tiersColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in board.tierLines {
            let label = RowKit.label(
                "\(line.tier) · \(line.model)  \(line.detail)", font: MacTheme.Ramp.font(.rowDetail),
                color: line.tone == .quiet ? MacTheme.Color.secondaryLabel : line.tone.color)
            label.lineBreakMode = .byTruncatingMiddle
            tiersColumn.addArrangedSubview(label)
        }

        runsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let stories = board.runStories
        if stories.isEmpty {
            emptyLabel.stringValue = board.isReady ? board.emptyLine : ""
            runsColumn.addArrangedSubview(emptyLabel)
        }
        for story in stories {
            let row = DelegateRunRow(story: story, selected: story.runID == selectedRun)
            row.onClick = { [weak self] in self?.select(runID: story.runID) }
            runsColumn.addArrangedSubview(row)
        }

        statsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for stat in board.statRows {
            statsColumn.addArrangedSubview(
                RowKit.label(
                    "\(stat.taskClass) · \(stat.tier)  \(stat.rateText) · \(stat.line)",
                    font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.secondaryLabel))
        }
        for hint in board.promotions {
            let label = RowKit.wrapping(hint, font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.mark)
            statsColumn.addArrangedSubview(label)
        }

        if let selectedRun, let story = board.story(for: selectedRun) {
            runView.show(story, tiers: board.tierOrder, host: host, desk: desk)
        } else {
            runView.showNothing(board.isReady ? DelegateEntryPoint.subtitle : reach.line)
        }
    }

    private func select(runID: String) {
        guard let host = selectedHost else { return }
        selectedRun = runID
        Task { await desk.load(runID: runID, host: host) }
        render()
    }

    private func compose() {
        guard let host = selectedHost, let window else { return }
        DelegateComposerSheet.present(on: window, host: host, serverName: serverName) { [weak self] runID in
            self?.select(runID: runID)
        }
    }

    private func askPassword() {
        guard let host = selectedHost, let window else { return }
        let alert = NSAlert()
        alert.messageText = Localized.text("Dispatcher password")
        alert.informativeText = Localized.text("The DELEGATE_PASSWORD line in ~/.config/delegate/serve.env on %@.", serverName)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = Localized.text("Password")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: Localized.text("Save"))
        alert.addButton(withTitle: Localized.text("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, !field.stringValue.isEmpty, let self else { return }
            self.desk.remember(password: field.stringValue, host: host, serverName: self.serverName)
        }
    }
}

/// One run in the list: the goal, where it is or how it ended, its badge, and its motion.
@MainActor
final class DelegateRunRow: NSView {
    var onClick: (() -> Void)?
    private let ground = RowKit.Ground(frame: .zero)

    init(story: DelegateRunStory, selected: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ground.fill = selected ? MacTheme.Color.accent.withAlphaComponent(0.14) : MacTheme.Color.canvasRaised
        ground.radius = MacTheme.Radius.control
        addSubview(ground)
        let title = RowKit.label(story.headline, font: MacTheme.Ramp.font(.rowTitle), color: MacTheme.Color.label)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        let detail = RowKit.label(
            story.subtitle, font: MacTheme.Ramp.font(.rowDetail),
            color: story.tone == .quiet ? MacTheme.Color.secondaryLabel : story.tone.color)
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 2
        let lines = NSStackView(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        let badge = ActivityBadgeView()
        badge.show(story.activity?.icon, spoken: nil)
        let mark = RowKit.label(story.badge ?? "", font: MacTheme.Ramp.font(.badge), color: story.tone.color)
        let row = NSStackView(views: [lines, mark, badge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(story.headline). \(story.subtitle)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick?() }
}

/// The ladder as rungs in a row. Reading, each wears its state; composing, a click is the start
/// rung and a shift-click is the ceiling, and a click on the start rung again unsets it.
@MainActor
final class MacLadderView: NSView {
    var compose = false
    var rungs: [DelegateRung] = [] { didSet { rebuild() } }
    private(set) var start: String?
    private(set) var ceiling: String?
    var onChange: ((String?, String?) -> Void)?
    private let row = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(start: String?, ceiling: String?) {
        self.start = start
        self.ceiling = ceiling
        rebuild()
    }

    private func index(of tier: String) -> Int { rungs.firstIndex { $0.tier == tier } ?? 0 }

    private func rebuild() {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let startIndex = start.map(index(of:))
        let ceilingIndex = ceiling.map(index(of:))
        for (offset, rung) in rungs.enumerated() {
            let state: DelegateRungState
            if compose {
                if let startIndex, offset < startIndex {
                    state = .belowStart
                } else if let ceilingIndex, offset > ceilingIndex {
                    state = .beyondCeiling
                } else if let startIndex, offset == startIndex {
                    state = .current
                } else {
                    state = .pending
                }
            } else {
                state = rung.state
            }
            let box = RungBox(rung: rung, state: state, cap: compose && ceilingIndex == offset)
            box.onClick = { [weak self] shift in self?.clicked(rung.tier, shift: shift) }
            row.addArrangedSubview(box)
        }
    }

    private func clicked(_ tier: String, shift: Bool) {
        guard compose else { return }
        if shift {
            ceiling = tier
            if let start, index(of: tier) < index(of: start) { self.start = tier }
        } else {
            start = start == tier ? nil : tier
            if let start, let ceiling, index(of: ceiling) < index(of: start) { self.ceiling = start }
        }
        rebuild()
        onChange?(start, ceiling)
    }

    @MainActor
    private final class RungBox: NSView {
        var onClick: ((Bool) -> Void)?

        init(rung: DelegateRung, state: DelegateRungState, cap: Bool) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            let ground = RowKit.Ground(frame: .zero)
            let ink: NSColor
            switch state {
            case .current, .passed:
                ground.fill = state.tone.color
                ink = MacTheme.Color.onAccent
            case .failed:
                ground.fill = MacTheme.Color.danger.withAlphaComponent(0.14)
                ground.stroke = MacTheme.Color.danger
                ink = MacTheme.Color.danger
            case .held:
                ground.fill = MacTheme.Color.warning.withAlphaComponent(0.16)
                ground.stroke = MacTheme.Color.warning
                ink = MacTheme.Color.warning
            case .pending:
                ground.fill = MacTheme.Color.accent.withAlphaComponent(0.10)
                ground.stroke = MacTheme.Color.accent.withAlphaComponent(0.5)
                ink = MacTheme.Color.label
            case .skipped, .belowStart, .beyondCeiling:
                ground.fill = MacTheme.Color.canvasRaised
                ink = MacTheme.Color.tertiaryLabel
            }
            ground.radius = MacTheme.Radius.control
            addSubview(ground)
            let mark: String
            switch state {
            case .passed: mark = " ✓"
            case .failed: mark = " ✗"
            case .held: mark = " ⏸"
            default: mark = ""
            }
            let title = RowKit.label(rung.tier + mark + (cap ? " ⌃" : ""), font: MacTheme.Ramp.font(.rowTitleStrong), color: ink)
            title.alignment = .center
            let detailText = [rung.label, rung.model?.split(separator: "/").last.map(String.init)].compactMap { $0 }.filter { !$0.isEmpty }
            let detail = RowKit.label(detailText.joined(separator: "\n"), font: MacTheme.Ramp.font(.rowMeta), color: ink.withAlphaComponent(0.8))
            detail.alignment = .center
            detail.maximumNumberOfLines = 2
            let lines = NSStackView(views: [title, detail])
            lines.orientation = .vertical
            lines.alignment = .centerX
            lines.spacing = 2
            lines.translatesAutoresizingMaskIntoConstraints = false
            addSubview(lines)
            NSLayoutConstraint.activate([
                ground.topAnchor.constraint(equalTo: topAnchor),
                ground.bottomAnchor.constraint(equalTo: bottomAnchor),
                ground.leadingAnchor.constraint(equalTo: leadingAnchor),
                ground.trailingAnchor.constraint(equalTo: trailingAnchor),
                lines.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
                lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
                lines.centerXAnchor.constraint(equalTo: centerXAnchor),
                lines.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -MacTheme.Spacing.s),
            ])
            toolTip = "\(rung.tier) \(DelegateLadder.word(state))"
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("\(rung.tier) \(rung.label) \(DelegateLadder.word(state))")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) {
            onClick?(event.modifierFlags.contains(.shift))
        }
    }
}

/// One run read on the right: its ladder, the gate it waits at, its story, its attempts, and the
/// two actions a run has.
@MainActor
final class DelegateRunView: NSView {
    var onSelectRun: ((String) -> Void)?
    private let column = NSStackView()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let ladder = MacLadderView()
    private let approval = DelegateApprovalBar()
    private let storyColumn = NSStackView()
    private let attemptsColumn = NSStackView()
    private let applied = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = RowKit.ActionButton(title: Localized.text("Cancel run"), action: {})
    private let replayPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let nothing = NSTextField(wrappingLabelWithString: "")
    private var scroll: NSScrollView!
    private var runID: String?
    private var host: String?
    private weak var desk: DelegateDesk?
    private var lastLineCount = 0

    init() {
        super.init(frame: .zero)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l, right: MacTheme.Spacing.l)
        heading.font = MacTheme.Ramp.font(.paneHeadline)
        heading.textColor = MacTheme.Color.label
        status.font = MacTheme.Ramp.font(.badge)
        column.addArrangedSubview(heading)
        column.addArrangedSubview(status)
        column.addArrangedSubview(ladder)
        column.addArrangedSubview(approval)
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("STORY")))
        storyColumn.orientation = .vertical
        storyColumn.alignment = .leading
        storyColumn.spacing = 2
        column.addArrangedSubview(storyColumn)
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("ATTEMPTS")))
        attemptsColumn.orientation = .vertical
        attemptsColumn.alignment = .leading
        attemptsColumn.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(attemptsColumn)
        applied.font = MacTheme.Ramp.font(.rowDetail)
        applied.textColor = MacTheme.Color.success
        column.addArrangedSubview(applied)
        replayPopup.addItem(withTitle: Localized.text("Replay on…"))
        let actions = NSStackView(views: [cancelButton, replayPopup])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.distribution = .fill
        actions.spacing = MacTheme.Spacing.s
        actions.heightAnchor.constraint(equalToConstant: 26).isActive = true
        column.addArrangedSubview(actions)
        for view in [heading, ladder, approval, storyColumn, attemptsColumn, applied] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.l).isActive = true
        }
        scroll = MacDialogs.scrollColumn(holding: column)
        addSubview(scroll)
        nothing.font = MacTheme.Ramp.font(.panelLabel)
        nothing.textColor = MacTheme.Color.secondaryLabel
        nothing.alignment = .center
        nothing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nothing)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            nothing.centerXAnchor.constraint(equalTo: centerXAnchor),
            nothing.centerYAnchor.constraint(equalTo: centerYAnchor),
            nothing.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        cancelButton.setAction { [weak self] in self?.cancel() }
        replayPopup.target = self
        replayPopup.action = #selector(replayPicked)
        approval.onDecision = { [weak self] approved in self?.decide(approved) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showNothing(_ text: String) {
        scroll.isHidden = true
        nothing.isHidden = false
        nothing.stringValue = text
        runID = nil
    }

    func show(_ story: DelegateRunStory, tiers: [String], host: String, desk: DelegateDesk) {
        scroll.isHidden = false
        nothing.isHidden = true
        self.host = host
        self.desk = desk
        let sameRun = runID == story.runID
        runID = story.runID
        heading.stringValue = story.headline
        status.stringValue = DelegateWords.status(story.status).uppercased()
        status.textColor = story.tone.color
        ladder.rungs = story.ladder.rungs
        approval.isHidden = !story.needsApproval
        if let pending = story.pendingApproval { approval.show(tier: pending.tier, reason: pending.reason) }
        if !sameRun || story.lines.count != lastLineCount {
            storyColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for line in story.lines {
                let label = RowKit.wrapping(
                    (line.isProgress ? "    " : "") + line.text,
                    font: MacTheme.Ramp.font(line.isProgress ? .rowMeta : .code),
                    color: line.isProgress ? MacTheme.Color.tertiaryLabel : (line.tone == .quiet ? MacTheme.Color.label : line.tone.color))
                storyColumn.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: storyColumn.widthAnchor).isActive = true
            }
            lastLineCount = story.lines.count
        }
        attemptsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attempt in story.attempts {
            let title = RowKit.label(
                DelegateRunStory.attemptLine(attempt), font: MacTheme.Ramp.font(.rowTitle),
                color: DelegateWords.tone(attempt.status) == .quiet ? MacTheme.Color.label : DelegateWords.tone(attempt.status).color)
            attemptsColumn.addArrangedSubview(title)
            var lines: [String] = []
            if let model = story.currentModel[attempt.tier] { lines.append(model) }
            lines.append(Localized.text("%@ in · %@ out", DelegateWords.tokens(attempt.tokensIn), DelegateWords.tokens(attempt.tokensOut)))
            if !attempt.changedFiles.isEmpty { lines.append(attempt.changedFiles.joined(separator: ", ")) }
            if attempt.status != .pass, !attempt.verifyTail.isEmpty {
                lines.append(attempt.verifyTail.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").suffix(8).joined(separator: "\n"))
            }
            if attempt.status == .pass, !attempt.workerSummary.isEmpty { lines.append(String(attempt.workerSummary.prefix(400))) }
            let detail = RowKit.wrapping(lines.joined(separator: "\n"), font: MacTheme.Ramp.font(.code), color: MacTheme.Color.secondaryLabel)
            attemptsColumn.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: attemptsColumn.widthAnchor).isActive = true
        }
        applied.isHidden = story.appliedFiles.isEmpty
        applied.stringValue = Localized.text("Applied %@ to the working tree, unstaged: %@", DelegateWords.files(story.appliedFiles.count), story.appliedFiles.joined(separator: ", "))
        cancelButton.isHidden = !story.isLive
        replayPopup.isHidden = story.isLive
        replayPopup.removeAllItems()
        replayPopup.addItem(withTitle: Localized.text("Replay on…"))
        replayPopup.addItems(withTitles: tiers)
    }

    @objc private func replayPicked() {
        guard replayPopup.indexOfSelectedItem > 0, let runID, let host, let desk else { return }
        let tier = replayPopup.titleOfSelectedItem ?? ""
        Task { [weak self] in
            if let started = try? await desk.replay(runID: runID, host: host, tier: tier, ceiling: nil) {
                self?.onSelectRun?(started)
            }
        }
    }

    private func cancel() {
        guard let runID, let host, let desk else { return }
        Task { try? await desk.cancel(runID: runID, host: host) }
    }

    private func decide(_ approved: Bool) {
        guard let runID, let host, let desk else { return }
        Task { try? await desk.approve(runID: runID, host: host, approved: approved) }
    }
}

/// The two answers a gated rung waits for. Approve climbs; hold ends the run as held.
@MainActor
final class DelegateApprovalBar: NSView {
    var onDecision: ((Bool) -> Void)?
    private let title = NSTextField(wrappingLabelWithString: "")
    private let reason = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let ground = RowKit.Ground(frame: .zero)
        ground.fill = MacTheme.Color.warning.withAlphaComponent(0.12)
        ground.stroke = MacTheme.Color.warning
        ground.radius = MacTheme.Radius.card
        addSubview(ground)
        title.font = MacTheme.Ramp.font(.rowTitleStrong)
        reason.font = MacTheme.Ramp.font(.rowDetail)
        reason.textColor = MacTheme.Color.secondaryLabel
        let approve = RowKit.ActionButton(title: Localized.text("Approve")) { [weak self] in self?.onDecision?(true) }
        approve.keyEquivalent = "\r"
        let hold = RowKit.ActionButton(title: Localized.text("Hold")) { [weak self] in self?.onDecision?(false) }
        let buttons = NSStackView(views: [approve, hold])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fill
        buttons.spacing = MacTheme.Spacing.s
        buttons.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let column = NSStackView(views: [title, reason, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
            title.widthAnchor.constraint(equalTo: column.widthAnchor),
            reason.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(tier: String, reason: String) {
        title.stringValue = Localized.text("Climb to %@?", tier)
        self.reason.stringValue = reason
    }
}

/// The packet form as a sheet over the delegate window.
@MainActor
final class DelegateComposerSheet: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    private static var active: DelegateComposerSheet?

    private let sheet: NSWindow
    private let host: String
    private let serverName: String
    private let desk = MacDelegateGate.desk
    private var draft: DelegateDraft
    private let onStarted: (String) -> Void
    private let classPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let repoField = NSTextField()
    private let goalView = NSTextView.scrollableTextView()
    private let pathsView = NSTextView.scrollableTextView()
    private let verifyField = NSTextField()
    private let suggestionRow = NSStackView()
    private let readField = NSTextField()
    private let notesView = NSTextView.scrollableTextView()
    private let ladder = MacLadderView()
    private let modeControl = NSSegmentedControl(labels: DelegateMode.allCases.map(DelegateWords.mode), trackingMode: .selectOne, target: nil, action: nil)
    private let effortControl = NSSegmentedControl(labels: [DelegateComposerWords.effortDefault] + DelegateEffort.allCases.map(DelegateWords.effort), trackingMode: .selectOne, target: nil, action: nil)
    private let problems = NSTextField(wrappingLabelWithString: "")
    private let cautions = NSTextField(wrappingLabelWithString: "")
    private let sendButton = RowKit.ActionButton(title: DelegateComposerWords.sendTitle, action: {})
    private var sending = false

    static func present(on window: NSWindow, host: String, serverName: String, onStarted: @escaping (String) -> Void) {
        let made = DelegateComposerSheet(host: host, serverName: serverName, onStarted: onStarted)
        active = made
        window.beginSheet(made.sheet) { _ in Self.active = nil }
    }

    private init(host: String, serverName: String, onStarted: @escaping (String) -> Void) {
        self.host = host
        self.serverName = serverName
        self.onStarted = onStarted
        let board = MacDelegateGate.desk.board(host: host, serverName: serverName)
        draft = DelegateDraft(capabilities: board.capabilities, repo: board.runs.first?.repo ?? "")
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.title = DelegateComposerWords.title
        sheet.isReleasedWhenClosed = false
        super.init()
        sheet.contentView = makeContent(board: board)
        render()
    }

    private func textView(_ scroll: NSScrollView, height: CGFloat, mono: Bool = false) -> NSScrollView {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.font = MacTheme.Ramp.font(mono ? .code : .answer)
            view.delegate = self
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scroll
    }

    private func labelled(_ title: String, _ view: NSView, help: String? = nil) -> NSStackView {
        let label = MacDialogs.sectionHeader(title.uppercased())
        var views: [NSView] = [label, view]
        if let help { views.append(MacDialogs.detailLabel(help, wraps: true)) }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.xs
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func makeContent(board: DelegateBoard) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l, right: MacTheme.Spacing.l)

        classPopup.addItems(withTitles: board.classes.isEmpty ? [draft.taskClass] : board.classes)
        classPopup.selectItem(withTitle: draft.taskClass)
        classPopup.target = self
        classPopup.action = #selector(fieldChanged)
        column.addArrangedSubview(labelled(DelegateComposerWords.classLabel, classPopup))

        repoField.stringValue = draft.repo
        repoField.placeholderString = DelegateComposerWords.repoPlaceholder
        repoField.font = MacTheme.Ramp.font(.code)
        repoField.delegate = self
        column.addArrangedSubview(labelled(DelegateComposerWords.repoLabel, repoField))

        column.addArrangedSubview(labelled(DelegateComposerWords.goalLabel, textView(goalView, height: 110), help: DelegateComposerWords.goalPlaceholder))
        column.addArrangedSubview(labelled(DelegateComposerWords.pathsLabel, textView(pathsView, height: 60, mono: true), help: DelegateComposerWords.pathsHelp))

        verifyField.placeholderString = DelegateComposerWords.verifyPlaceholder
        verifyField.font = MacTheme.Ramp.font(.code)
        verifyField.delegate = self
        suggestionRow.orientation = .horizontal
        suggestionRow.spacing = MacTheme.Spacing.xs
        let verifyColumn = NSStackView(views: [verifyField, suggestionRow])
        verifyColumn.orientation = .vertical
        verifyColumn.alignment = .leading
        verifyColumn.spacing = MacTheme.Spacing.xs
        verifyField.widthAnchor.constraint(equalTo: verifyColumn.widthAnchor).isActive = true
        column.addArrangedSubview(labelled(DelegateComposerWords.verifyLabel, verifyColumn, help: DelegateComposerWords.verifyHelp))

        readField.placeholderString = "README.md"
        readField.font = MacTheme.Ramp.font(.code)
        readField.delegate = self
        column.addArrangedSubview(labelled(DelegateComposerWords.readLabel, readField))
        column.addArrangedSubview(labelled(DelegateComposerWords.notesLabel, textView(notesView, height: 50)))

        ladder.compose = true
        ladder.rungs = board.tiers.map { DelegateRung(tier: $0.tier, label: $0.label, model: $0.activeEntry?.model, state: .pending) }
        ladder.onChange = { [weak self] start, ceiling in
            self?.draft.tier = start
            self?.draft.ceiling = ceiling
            self?.render()
        }
        ladder.heightAnchor.constraint(equalToConstant: 56).isActive = true
        column.addArrangedSubview(labelled(DelegateComposerWords.ladderLabel, ladder, help: Localized.text("Click a rung to start there; shift-click sets how far the run may climb. Unset means the class decides.")))

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(fieldChanged)
        column.addArrangedSubview(labelled(DelegateComposerWords.modeLabel, modeControl))
        effortControl.selectedSegment = 0
        effortControl.target = self
        effortControl.action = #selector(fieldChanged)
        column.addArrangedSubview(labelled(DelegateComposerWords.effortLabel, effortControl))

        cautions.font = MacTheme.Ramp.font(.rowNote)
        cautions.textColor = MacTheme.Color.warning
        problems.font = MacTheme.Ramp.font(.rowNote)
        problems.textColor = MacTheme.Color.danger
        column.addArrangedSubview(cautions)
        column.addArrangedSubview(problems)
        let cancel = RowKit.ActionButton(title: Localized.text("Cancel")) { [weak self] in self?.close() }
        sendButton.setAction { [weak self] in self?.send() }
        sendButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, sendButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fill
        buttons.spacing = MacTheme.Spacing.s
        buttons.heightAnchor.constraint(equalToConstant: 26).isActive = true
        column.addArrangedSubview(buttons)
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.l).isActive = true
        }
        let scroll = MacDialogs.scrollColumn(holding: column)
        let root = NSView()
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return root
    }

    func textDidChange(_ notification: Notification) { fieldChanged() }

    func controlTextDidChange(_ obj: Notification) { fieldChanged() }

    @objc private func fieldChanged() {
        draft.taskClass = classPopup.titleOfSelectedItem ?? draft.taskClass
        draft.repo = repoField.stringValue
        draft.goal = (goalView.documentView as? NSTextView)?.string ?? ""
        draft.paths = (pathsView.documentView as? NSTextView)?.string ?? ""
        draft.verify = verifyField.stringValue
        draft.read = readField.stringValue
        draft.notes = (notesView.documentView as? NSTextView)?.string ?? ""
        draft.mode = DelegateMode.allCases.element(at: modeControl.selectedSegment) ?? .normal
        draft.effort = effortControl.selectedSegment == 0 ? nil : DelegateEffort.allCases.element(at: effortControl.selectedSegment - 1)
        render()
    }

    private func render() {
        let problems = draft.problems
        self.problems.stringValue = problems.joined(separator: "\n")
        self.problems.isHidden = problems.isEmpty
        let cautions = draft.cautions
        self.cautions.stringValue = cautions.isEmpty ? "" : DelegateComposerWords.cautionsTitle + ": " + cautions.joined(separator: " ")
        self.cautions.isHidden = cautions.isEmpty
        sendButton.isEnabled = draft.canSend && !sending
        sendButton.title = sending ? DelegateComposerWords.sendingTitle : DelegateComposerWords.sendTitle
        suggestionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for suggestion in DelegateDraft.verifySuggestions(paths: draft.pathList, repo: draft.repo) where suggestion != draft.verify {
            suggestionRow.addArrangedSubview(RowKit.ActionButton(title: suggestion) { [weak self] in
                self?.verifyField.stringValue = suggestion
                self?.fieldChanged()
            })
        }
    }

    private func send() {
        guard draft.canSend, !sending else { return }
        sending = true
        render()
        let draft = draft
        Task { [weak self] in
            guard let self else { return }
            do {
                let runID = try await self.desk.start(draft, host: self.host)
                self.close()
                self.onStarted(runID)
            } catch {
                self.sending = false
                self.render()
                self.problems.stringValue = error.localizedDescription
                self.problems.isHidden = false
            }
        }
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
    }
}

extension Collection where Index == Int {
    fileprivate func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
