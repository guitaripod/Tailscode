import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The one door into delegation on the Mac. The store build sells Pro and gates here; a copy
/// somebody installed themselves has no receipt and is simply whole.
@MainActor
enum MacDelegateGate {
    static let desk = DelegateDesk(secrets: KeychainSecretStore())
    nonisolated(unsafe) private static var noticeWatcher: NSObjectProtocol?

    /// A run this Mac follows taps its shoulder: a wait for a person under the approvals switch,
    /// an end nobody chose under the turn-complete switch, never while the app is in front.
    static func watchNotices() {
        guard noticeWatcher == nil else { return }
        noticeWatcher = NotificationCenter.default.addObserver(
            forName: DelegateDesk.didNotice, object: nil, queue: .main
        ) { note in
            guard let notice = note.userInfo?["notice"] as? DelegateNotice,
                let runID = note.userInfo?["runID"] as? String
            else { return }
            MainThread.call {
                MacNotifier.shared.raiseDelegate(notice, identifier: "delegate:\(runID):\(notice.kind)")
            }
        }
    }

    static var isOpen: Bool {
        DelegateProGate.allows(
            isPro: MacProStore.shared.isPro, sells: MacProStore.shared.sellsPro,
            demo: ServerDirectory.shared.isDemoMode)
    }
}

/// One window for every dispatcher this Mac talks to. It leads with the work: the machine and the
/// dispatcher's version under the title, New packet as the one prominent button, the ladder as a
/// row of rungs, and the runs grouped by what they ask of the reader — the run being read fills the
/// right. Every word is `DelegateBoard`'s and `DelegateRunReading`'s; this window draws boxes and
/// forwards presses to the desk.
@MainActor
final class DelegateWindowController: NSWindowController {
    private let desk = MacDelegateGate.desk
    private let serverPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let statusBadge = ActivityBadgeView()
    private let statusRow = NSStackView()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let passwordButton = RowKit.ActionButton(title: Localized.text("Password…"), action: {})
    private let newButton = RowKit.ActionButton(title: DelegateEntryPoint.newPacketTitle, action: {})
    private let boardColumn = NSStackView()
    private let setupColumn = NSStackView()
    private let ladderColumn = NSStackView()
    private let runsColumn = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let runView = DelegateRunView()
    private lazy var betaBadge = BetaBadge(feature: .delegate, reportLines: { [weak self] in self?.betaReportLines ?? [] })
    private var hosts: [(host: String, name: String)] = []
    private var selectedHost: String?
    private var selectedRun: String?
    private var wantsFirstRun = false
    private var wantsCompose = false
    private var pendingHandoff: DelegateHandoff?
    private var askedPatch: Set<String> = []
    private var diffWindows: [GitDiffWindowController] = []
    private var drawn: Drawn?
    /// Where the window reads this Mac's chats from — the sidebar's live listing — so the composer
    /// can offer their repositories and an apply can see a chat working under it.
    var chatSource: () -> [SessionEntry] = { [] }

    /// What each part of the board was last built from. A live run streams its story in as desk
    /// changes several times a second, and a part rebuilt from identical rows costs a layout pass
    /// and a flicker for nothing, so a part is rebuilt only when what it shows has changed — and
    /// every one of them when the theme or the type scale did, since both are baked into the rows.
    private struct Drawn: Equatable {
        var scale: CGFloat
        var setup: String?
        var rungs: [DelegateBoardRung]
        var promotions: [String]
        var sections: [DelegateRunSection]
        var selected: String?
        var empty: String
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = DelegateEntryPoint.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 540)
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        window.rememberFrame(as: "TailscodeDelegate")
        passwordButton.setAction { [weak self] in self?.askPassword() }
        newButton.setAction { [weak self] in self?.compose() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: DelegateDesk.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        runView.onAction = { [weak self] kind, runID in self?.perform(kind, runID: runID) }
        runView.onFile = { [weak self] path, runID in self?.openFile(path, runID: runID) }
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

    /// Why the feature wears its mark, opened as a press would open it.
    func revealBeta() { betaBadge.reveal() }

    /// What the dispatcher on this machine said last, for a report: where it is, what it answered and
    /// which version, and nothing the person typed.
    private var betaReportLines: [String] {
        guard let host = selectedHost else { return [] }
        let address = (DelegateAccessStore.access(host: host) ?? DelegateAccess(host: host)).address
        let reach = desk.reach[host] ?? .unknown
        var lines = ["Daemon: \(address)", "Daemon state: \(Self.betaReportState(reach))"]
        if case .answering(let version) = reach { lines.append("Daemon version: \(version)") }
        return lines
    }

    private static func betaReportState(_ reach: DelegateReach) -> String {
        switch reach {
        case .unknown: return "not checked"
        case .checking: return "checking"
        case .answering: return "answering"
        case .wantsPassword: return "wants a password"
        case .refused: return "password refused"
        case .unreachable(let why): return "not answering (\(why))"
        }
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
        var found: [(host: String, name: String)] = ServerDirectory.shared.profiles.compactMap { profile in
            guard let host = profile.baseURL.host, seen.insert(host).inserted else { return nil }
            return (host, profile.name)
        }
        for kept in hosts where seen.insert(kept.host).inserted { found.append(kept) }
        hosts = found
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

        let heading = NSTextField(labelWithString: DelegateEntryPoint.title)
        heading.font = MacTheme.Ramp.font(.panelTitle)
        heading.textColor = MacTheme.Color.label
        let titleRow = NSStackView(views: [heading, betaBadge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = MacTheme.Spacing.s
        titleRow.setHuggingPriority(.defaultHigh, for: .horizontal)
        subtitleLabel.font = MacTheme.Ramp.font(.panelDetail)
        subtitleLabel.textColor = MacTheme.Color.secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleBlock = NSStackView(views: [titleRow, subtitleLabel])
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = 2
        titleBlock.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleBlock.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        serverPopup.target = self
        serverPopup.action = #selector(serverChanged)
        serverPopup.toolTip = Localized.text("Machine")
        serverPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newButton.bezelColor = MacTheme.Color.accent
        newButton.controlSize = .large
        for button in [passwordButton, newButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let header = NSStackView(views: [titleBlock, serverPopup, passwordButton, newButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = MacTheme.Spacing.s
        header.setCustomSpacing(MacTheme.Spacing.l, after: titleBlock)
        header.setHuggingPriority(.required, for: .vertical)
        titleBlock.setHuggingPriority(.required, for: .vertical)

        noteLabel.font = MacTheme.Ramp.font(.rowNote)
        noteLabel.textColor = MacTheme.Color.mark
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [header, noteLabel])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = MacTheme.Spacing.xs
        top.setHuggingPriority(.required, for: .vertical)
        top.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        noteLabel.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        root.addSubview(top)

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rule)

        boardColumn.orientation = .vertical
        boardColumn.alignment = .leading
        boardColumn.spacing = MacTheme.Spacing.l
        boardColumn.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l, right: MacTheme.Spacing.l)

        statusRow.setViews([statusBadge, statusLabel], in: .leading)
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = MacTheme.Spacing.s
        statusLabel.font = MacTheme.Ramp.font(.panelLabel)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        boardColumn.addArrangedSubview(statusRow)

        setupColumn.orientation = .vertical
        setupColumn.alignment = .leading
        setupColumn.spacing = MacTheme.Spacing.xs
        boardColumn.addArrangedSubview(setupColumn)

        ladderColumn.orientation = .vertical
        ladderColumn.alignment = .leading
        ladderColumn.spacing = MacTheme.Spacing.s
        boardColumn.addArrangedSubview(ladderColumn)

        runsColumn.orientation = .vertical
        runsColumn.alignment = .leading
        runsColumn.spacing = MacTheme.Spacing.l
        emptyLabel.font = MacTheme.Ramp.font(.panelFootnote)
        emptyLabel.textColor = MacTheme.Color.secondaryLabel
        boardColumn.addArrangedSubview(runsColumn)

        for view in [statusRow, setupColumn, ladderColumn, runsColumn] {
            view.widthAnchor.constraint(equalTo: boardColumn.widthAnchor, constant: -2 * MacTheme.Spacing.l).isActive = true
        }
        let boardScroll = MacDialogs.scrollColumn(holding: boardColumn)
        root.addSubview(boardScroll)

        runView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(runView)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.setContentHuggingPriority(.init(1), for: .vertical)
        root.addSubview(divider)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: MacTheme.Spacing.m),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: MacTheme.Spacing.l),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -MacTheme.Spacing.l),
            rule.topAnchor.constraint(equalTo: top.bottomAnchor, constant: MacTheme.Spacing.m),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            boardScroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            boardScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            boardScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            boardScroll.widthAnchor.constraint(equalToConstant: 420),
            divider.leadingAnchor.constraint(equalTo: boardScroll.trailingAnchor),
            divider.topAnchor.constraint(equalTo: rule.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            runView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            runView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            runView.topAnchor.constraint(equalTo: rule.bottomAnchor),
            runView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    @objc private func serverChanged() {
        guard let picked = hosts.element(at: serverPopup.indexOfSelectedItem) else { return }
        select(host: picked.host)
    }

    private func select(host: String) {
        guard host != selectedHost || desk.boards[host] == nil else {
            render()
            return
        }
        selectedHost = host
        selectedRun = nil
        if let index = hosts.firstIndex(where: { $0.host == host }) { serverPopup.selectItem(at: index) }
        if desk.boards[host] == nil || desk.boards[host]?.phase == .idle { probe() }
        render()
    }

    private func probe() {
        guard let host = selectedHost else { return }
        desk.probe(host: host, serverName: serverName)
    }

    @objc private func deskChanged() {
        if wantsFirstRun, let first = firstRunWorthReading() {
            wantsFirstRun = false
            select(runID: first)
        }
        if let host = selectedHost, desk.boards[host]?.isReady == true {
            if let handoff = pendingHandoff, handoff.host == host {
                pendingHandoff = nil
                compose(draft: handoff.draft(capabilities: desk.boards[host]?.capabilities))
            } else if wantsCompose {
                wantsCompose = false
                compose()
            }
        }
        render()
    }

    @objc private func repaint() {
        drawn = nil
        runView.forget()
        render()
    }

    private func render() {
        guard let host = selectedHost else {
            statusLabel.stringValue = Localized.text("Add a server first.")
            statusRow.isHidden = false
            newButton.isEnabled = false
            passwordButton.isHidden = true
            noteLabel.isHidden = true
            runView.showNothing(Localized.text("Add a server first."))
            return
        }
        let board = desk.board(host: host, serverName: serverName)
        let reach = desk.reach[host] ?? .unknown
        subtitleLabel.stringValue = board.subtitle
        let answering = board.isReady && reach.isAnswering
        statusRow.isHidden = answering
        statusLabel.stringValue = reach.isAnswering || board.statusLine == reach.line
            ? board.statusLine : board.statusLine + "\n" + reach.line
        statusLabel.textColor = board.statusTone == .quiet ? MacTheme.Color.secondaryLabel : board.statusTone.color
        statusBadge.show(board.phase == .checking ? ActivityKind.connecting.icon : nil, spoken: nil)
        newButton.isEnabled = board.isReady
        noteLabel.stringValue = board.note ?? ""
        noteLabel.isHidden = board.note == nil
        passwordButton.isHidden = desk.isDemo(host: host) || !(reach.asksForPassword || desk.password(host: host) != nil)

        let next = Drawn(
            scale: MacTheme.UIScale.factor,
            setup: DelegateSetup.isWanted(board: board, known: desk.isKnown(host: host)) ? serverName : nil,
            rungs: board.isReady ? board.ladderRungs : [],
            promotions: board.isReady ? board.promotions : [],
            sections: board.sections(), selected: selectedRun,
            empty: board.isReady ? board.emptyLine : "")
        let last = drawn?.scale == next.scale ? drawn : nil
        drawn = next
        func changed<Part: Equatable>(_ part: KeyPath<Drawn, Part>) -> Bool {
            guard let last else { return true }
            return last[keyPath: part] != next[keyPath: part]
        }

        if changed(\.setup) {
            rebuildSetup(wanted: next.setup != nil)
        }
        if changed(\.rungs) || changed(\.promotions) {
            rebuildLadder(next)
        }
        if changed(\.sections) || changed(\.selected) || changed(\.empty) {
            rebuildRuns(next)
        }

        if let selectedRun, let reading = board.reading(for: selectedRun) {
            if board.story(for: selectedRun)?.status == .passed, board.patches[selectedRun] == nil,
                askedPatch.insert(selectedRun).inserted
            {
                let runID = selectedRun
                Task { [desk] in _ = try? await desk.patch(runID: runID, host: host) }
            }
            runView.show(reading, board: board)
        } else {
            runView.showNothing(board.isReady ? DelegateEntryPoint.subtitle : reach.line)
        }
    }

    private func rebuildSetup(wanted: Bool) {
        setupColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        setupColumn.isHidden = !wanted
        guard wanted else { return }
        setupColumn.addArrangedSubview(MacDialogs.sectionHeader(DelegateSetup.title.uppercased()))
        let lead = RowKit.wrapping(DelegateSetup.lead(serverName: serverName), font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.secondaryLabel)
        setupColumn.addArrangedSubview(lead)
        lead.widthAnchor.constraint(equalTo: setupColumn.widthAnchor).isActive = true
        for step in DelegateSetup.steps {
            let title = RowKit.label(step.title, font: MacTheme.Ramp.font(.rowTitle), color: MacTheme.Color.label)
            let copy = RowKit.ActionButton(title: Localized.text("Copy")) { [weak self] in self?.copySetupCommand(step) }
            let head = NSStackView(views: [title, copy])
            head.orientation = .horizontal
            head.alignment = .centerY
            head.distribution = .fill
            head.spacing = MacTheme.Spacing.s
            head.heightAnchor.constraint(equalToConstant: 22).isActive = true
            setupColumn.addArrangedSubview(head)
            let command = RowKit.wrapping(step.command, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.secondaryLabel)
            setupColumn.addArrangedSubview(command)
            command.widthAnchor.constraint(equalTo: setupColumn.widthAnchor).isActive = true
            let detail = RowKit.wrapping(step.detail, font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.tertiaryLabel)
            setupColumn.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: setupColumn.widthAnchor).isActive = true
        }
    }

    private func rebuildLadder(_ drawn: Drawn) {
        ladderColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        ladderColumn.isHidden = drawn.rungs.isEmpty
        guard !drawn.rungs.isEmpty else { return }
        ladderColumn.addArrangedSubview(MacDialogs.sectionHeader(DelegateComposerWords.ladderLabel.uppercased()))
        let row = DelegateRungCard.row(
            drawn.rungs.map { rung in
                DelegateRungCard(
                    title: rung.label.isEmpty ? rung.tier : "\(rung.tier) · \(rung.label)",
                    model: rung.model, fullModel: rung.fullModel,
                    notes: [(rung.health, rung.tone), (rung.record ?? Localized.text("untried"), .quiet)],
                    state: nil)
            })
        ladderColumn.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: ladderColumn.widthAnchor).isActive = true
        for hint in drawn.promotions {
            let label = RowKit.wrapping(hint, font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.mark)
            ladderColumn.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: ladderColumn.widthAnchor).isActive = true
        }
    }

    private func rebuildRuns(_ drawn: Drawn) {
        runsColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if drawn.sections.isEmpty {
            emptyLabel.stringValue = drawn.empty
            runsColumn.addArrangedSubview(emptyLabel)
            emptyLabel.widthAnchor.constraint(equalTo: runsColumn.widthAnchor).isActive = true
        }
        for section in drawn.sections {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            column.addArrangedSubview(MacDialogs.sectionHeader(section.title.uppercased()))
            for row in section.rows {
                let view = DelegateRunRowView(row: row, selected: row.runID == drawn.selected)
                view.onClick = { [weak self] in self?.select(runID: row.runID) }
                column.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            runsColumn.addArrangedSubview(column)
            column.widthAnchor.constraint(equalTo: runsColumn.widthAnchor).isActive = true
        }
    }

    private func select(runID: String) {
        guard let host = selectedHost else { return }
        selectedRun = runID
        Task { await desk.load(runID: runID, host: host) }
        render()
    }

    /// The run a pointer-free check should open: one waiting for a person first, then a settled
    /// one, then whatever the board lists.
    private func firstRunWorthReading() -> String? {
        guard let sections = board?.sections() else { return nil }
        let rows = sections.first { $0.kind == .needsYou }?.rows
            ?? sections.first { $0.kind == .earlier }?.rows ?? sections.first?.rows ?? []
        return rows.first?.runID
    }

    /// The first run worth reading, opened as a click would open it — the road `--open
    /// delegate-run` takes so the run view can be dumped and checked without a pointer.
    func selectFirstRun() {
        if let first = firstRunWorthReading() {
            select(runID: first)
            return
        }
        wantsFirstRun = true
    }

    /// The composer, opened once the board has its ladder — the road `--open delegate-compose`
    /// takes, since a sheet opened before the machine answered would draw no rungs.
    func composeWhenReady() {
        guard let host = selectedHost else { return }
        if desk.boards[host]?.isReady == true {
            compose()
            return
        }
        wantsCompose = true
    }

    /// A chat handed its task over: the composer opens on that chat's machine with its goal and
    /// repository, once the machine has answered.
    func compose(handoff: DelegateHandoff) {
        if !hosts.contains(where: { $0.host == handoff.host }) {
            hosts.append((handoff.host, handoff.serverName))
            serverPopup.addItem(withTitle: "\(handoff.serverName) · \(handoff.host)")
        }
        select(host: handoff.host)
        if desk.boards[handoff.host]?.isReady == true {
            compose(draft: handoff.draft(capabilities: desk.boards[handoff.host]?.capabilities))
        } else {
            pendingHandoff = handoff
        }
    }

    private var footprints: [DelegateChatFootprint] {
        guard let host = selectedHost else { return [] }
        return DelegateChatFootprint.from(chatSource(), host: host)
    }

    func compose(draft: DelegateDraft? = nil) {
        guard let host = selectedHost, let window else { return }
        let board = desk.board(host: host, serverName: serverName)
        let choices = DelegateRepoChoices.make(runs: board.runs, chats: footprints)
        let seed = draft ?? DelegateDraft(capabilities: board.capabilities, repo: choices.first?.path ?? "")
        DelegateComposerSheet.present(
            on: window, host: host, serverName: serverName, draft: seed, repoChoices: choices
        ) { [weak self] runID in
            self?.select(runID: runID)
        }
    }

    /// One command onto the pasteboard, and the status line says so for a moment.
    private func copySetupCommand(_ step: DelegateSetup.Step) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(step.command, forType: .string)
        let before = statusLabel.stringValue
        statusLabel.stringValue = DelegateSetup.copied + " · " + step.command
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.statusLabel.stringValue.hasPrefix(DelegateSetup.copied) else { return }
            self.statusLabel.stringValue = before
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

    private func perform(_ kind: DelegateRunAction.Kind, runID: String) {
        switch kind {
        case .approve: respondToApproval(runID: runID, approved: true)
        case .hold: respondToApproval(runID: runID, approved: false)
        case .cancel:
            MacDialogs.confirm(
                on: window, title: Localized.text("Cancel this run?"),
                body: Localized.text("The worker stops where it is and nothing it changed reaches the tree."),
                confirmLabel: Localized.text("Cancel run")
            ) { [weak self] in self?.cancelRun(runID) }
        case .apply: apply(runID)
        case .discard:
            MacDialogs.confirm(
                on: window, title: Localized.text("Discard this patch?"),
                body: Localized.text("The tree never sees it. The patch stays readable on this run."),
                confirmLabel: Localized.text("Discard")
            ) { [weak self] in self?.deliver(runID, apply: false) }
        case .replay(let tier): replayRun(runID, tier: tier)
        case .duplicate:
            guard let packet = board?.story(for: runID)?.packet else { return }
            compose(draft: DelegateDraft(packet: packet))
        }
    }

    /// Applying lands files in a tree a chat may be writing to right now; that chat is named before
    /// the press rather than discovered after it.
    private func apply(_ runID: String) {
        let repo = board?.reading(for: runID)?.repo ?? ""
        let cautions = DelegateApplyCheck.cautions(repo: repo, chats: footprints)
        guard cautions.isEmpty else {
            MacDialogs.confirm(
                on: window, title: DelegateApplyCheck.confirmTitle, body: cautions.joined(separator: "\n\n"),
                confirmLabel: DelegateApplyCheck.confirmAction, destructive: false
            ) { [weak self] in self?.deliver(runID, apply: true) }
            return
        }
        deliver(runID, apply: true)
    }

    private func deliver(_ runID: String, apply: Bool) {
        guard let host = selectedHost else { return }
        Task { [weak self, desk] in
            do {
                if apply {
                    try await desk.apply(runID: runID, host: host)
                } else {
                    try await desk.discard(runID: runID, host: host)
                }
            } catch {
                self?.presentRefusal(DelegateRefusal(error))
            }
        }
    }

    /// A refused apply says what refused it in the refuser's own words — git's, when the tree moved
    /// under the patch — and output is set as output, in a box that scrolls rather than an alert
    /// that grows past the screen.
    private func presentRefusal(_ refusal: DelegateRefusal) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = refusal.title
        if refusal.bodyIsOutput {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 140)
            scroll.borderType = .bezelBorder
            if let text = scroll.documentView as? NSTextView {
                text.isEditable = false
                text.string = refusal.body
                text.font = MacTheme.Ramp.font(.code)
                text.textColor = MacTheme.Color.label
                text.backgroundColor = MacTheme.Color.codeBackground
            }
            alert.accessoryView = scroll
        } else {
            alert.informativeText = refusal.body
        }
        alert.addButton(withTitle: Localized.text("OK"))
        guard let window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }

    /// A press that did not reach the dispatcher names what it was and says why in the transport's
    /// own words, as the phone's alert does — an Approve that went nowhere must never look like one
    /// that was taken.
    private func presentFailure(_ title: String, _ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: Localized.text("OK"))
        guard let window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }

    private func respondToApproval(runID: String, approved: Bool) {
        guard let host = selectedHost else { return }
        Task { [weak self, desk] in
            do {
                try await desk.approve(runID: runID, host: host, approved: approved)
            } catch {
                self?.presentFailure(Localized.text("The answer did not reach the dispatcher"), error)
            }
        }
    }

    private func cancelRun(_ runID: String) {
        guard let host = selectedHost else { return }
        Task { [weak self, desk] in
            do {
                try await desk.cancel(runID: runID, host: host)
            } catch {
                self?.presentFailure(Localized.text("The run did not cancel"), error)
            }
        }
    }

    private func replayRun(_ runID: String, tier: String) {
        guard let host = selectedHost else { return }
        Task { [weak self, desk] in
            do {
                let started = try await desk.replay(runID: runID, host: host, tier: tier, ceiling: nil)
                self?.select(runID: started)
            } catch {
                self?.presentFailure(Localized.text("The replay did not start"), error)
            }
        }
    }

    /// One file of the run's patch in the same window the repository surface opens a diff in, with
    /// the same gutter: the patch is read once and kept on the board, so every file after the first
    /// costs nothing.
    private func openFile(_ path: String, runID: String) {
        guard let host = selectedHost else { return }
        let desk = self.desk
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let diff = GitDiffWindowController(title: name, subtitle: path) {
            guard let patch = try? await desk.patch(runID: runID, host: host) else { return nil }
            return DelegatePatch.files(patch).first { $0.path == path }?.patch
        }
        diffWindows.append(diff)
        diff.onClose = { [weak self, weak diff] in
            self?.diffWindows.removeAll { $0 === diff }
        }
        diff.present()
    }
}

extension Collection where Index == Int {
    func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
