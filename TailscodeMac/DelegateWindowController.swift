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
            MainActor.assumeIsolated {
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
    private let betaBadge = DelegateBetaBadge()
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

    private func respondToApproval(runID: String, approved: Bool) {
        guard let host = selectedHost else { return }
        Task { [desk] in try? await desk.approve(runID: runID, host: host, approved: approved) }
    }

    private func cancelRun(_ runID: String) {
        guard let host = selectedHost else { return }
        Task { [desk] in try? await desk.cancel(runID: runID, host: host) }
    }

    private func replayRun(_ runID: String, tier: String) {
        guard let host = selectedHost else { return }
        Task { [weak self, desk] in
            if let started = try? await desk.replay(runID: runID, host: host, tier: tier, ceiling: nil) {
                self?.select(runID: started)
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

/// One run in the board's list: its motion, the goal and the pill saying where it stands, the line
/// under it, and the run's ladder at the size of a row beside the repository and the age.
@MainActor
final class DelegateRunRowView: NSView {
    var onClick: (() -> Void)?
    private let ground = RowKit.Ground(frame: .zero)

    init(row: DelegateRunRow, selected: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ground.fill = selected ? MacTheme.Color.accent.withAlphaComponent(0.14) : nil
        ground.radius = MacTheme.Radius.control
        addSubview(ground)

        let glyph = Self.glyph(row)
        let title = RowKit.label(row.headline, font: MacTheme.Ramp.font(.rowTitle), color: MacTheme.Color.label)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var head: [NSView] = [title]
        if let badge = row.badge { head.append(DelegatePill(badge, tone: row.tone)) }
        let titleRow = NSStackView(views: head)
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        titleRow.alignment = .centerY
        titleRow.spacing = MacTheme.Spacing.s
        let detail = RowKit.label(row.detail, font: MacTheme.Ramp.font(.rowDetail), color: MacTheme.Color.secondaryLabel)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var meta: [NSView] = [DelegatePipsView(row.rungs)]
        let facts = [row.repo, row.age].filter { !$0.isEmpty }.joined(separator: " · ")
        if !facts.isEmpty {
            let label = RowKit.label(facts, font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.tertiaryLabel)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            meta.append(label)
        }
        let metaRow = NSStackView(views: meta)
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.setHuggingPriority(.defaultHigh, for: .horizontal)
        metaRow.spacing = MacTheme.Spacing.s
        let lines = NSStackView(views: [titleRow, detail, metaRow])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 3
        for line in [titleRow, detail, metaRow] {
            line.widthAnchor.constraint(lessThanOrEqualTo: lines.widthAnchor).isActive = true
        }
        titleRow.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
        let line = NSStackView(views: [glyph, lines])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = MacTheme.Spacing.s
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        toolTip = row.spoken
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.spoken)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The row's state in its own motion while it works or waits; a settled run holds still as a
    /// dot in its tone, because stillness is how a reader tells an ending from a slow run.
    private static func glyph(_ row: DelegateRunRow) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        let size = MacTheme.Ramp.font(.rowTitle).pointSize + 4
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: size),
            slot.heightAnchor.constraint(equalToConstant: size),
        ])
        let mark: NSView
        if let activity = row.activity {
            let badge = ActivityBadgeView(pointSize: size - 5)
            badge.show(activity.icon, spoken: activity.spoken)
            mark = badge
        } else {
            mark = DelegateDot(color: row.tone.color, diameter: 7)
        }
        mark.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
        ])
        return slot
    }

    @objc private func clicked() { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// A word in a capsule of its tone — a run's Review, Applied or Failed.
@MainActor
final class DelegatePill: NSView {
    private let tone: ActivityTone

    init(_ text: String, tone: ActivityTone) {
        self.tone = tone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.pill)
        label.textColor = Self.ink(tone)
        label.translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func ink(_ tone: ActivityTone) -> NSColor {
        tone == .quiet ? MacTheme.Color.secondaryLabel : tone.color
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.ink(tone).withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// A still mark in one colour.
@MainActor
final class DelegateDot: NSView {
    private let color: NSColor
    private let diameter: CGFloat

    init(color: NSColor, diameter: CGFloat) {
        self.color = color
        self.diameter = diameter
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// A run's ladder at the size of a row: one pip per rung, cheapest first, lit where it passed or is
/// working, marked where it failed or was held, faint where the run could never go.
@MainActor
final class DelegatePipsView: NSView {
    private let states: [DelegateRungState]
    private static let pip: CGFloat = 6
    private static let gap: CGFloat = 3

    init(_ states: [DelegateRungState]) {
        self.states = states
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(states.count)
        return NSSize(width: max(0, count * Self.pip + (count - 1) * Self.gap), height: Self.pip)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, state) in states.enumerated() {
            let rect = NSRect(
                x: CGFloat(index) * (Self.pip + Self.gap), y: (bounds.height - Self.pip) / 2,
                width: Self.pip, height: Self.pip)
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            switch state {
            case .current, .passed, .failed, .held:
                state.tone.color.setFill()
                path.fill()
            case .pending:
                MacTheme.Color.tertiaryLabel.setStroke()
                path.lineWidth = 1
                path.stroke()
            case .belowStart, .beyondCeiling, .skipped:
                MacTheme.Color.tertiaryLabel.withAlphaComponent(0.35).setFill()
                path.fill()
            }
        }
    }
}

/// One rung as a card: its tier and label, the model answering there, and a line or two of what
/// matters about it here — health and record on the board, where it stands on a run, the numbers
/// for the class in the composer. A run's state decides the card's ground; the board's cards have
/// no state and stand plain.
@MainActor
final class DelegateRungCard: NSView {
    var onClick: ((Bool) -> Void)?

    init(title: String, model: String?, fullModel: String?, notes: [(String?, ActivityTone)], state: DelegateRungState?, cap: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let ground = RowKit.Ground(frame: .zero)
        let ink: NSColor
        let quiet: NSColor
        var toned = true
        switch state {
        case .current, .passed:
            ground.fill = MacTheme.Color.success
            ink = MacTheme.Color.onAccent
            quiet = MacTheme.Color.onAccent.withAlphaComponent(0.85)
            toned = false
        case .failed:
            ground.fill = MacTheme.Color.danger.withAlphaComponent(0.10)
            ground.stroke = MacTheme.Color.danger
            ink = MacTheme.Color.label
            quiet = MacTheme.Color.secondaryLabel
        case .held:
            ground.fill = MacTheme.Color.warning.withAlphaComponent(0.12)
            ground.stroke = MacTheme.Color.warning
            ink = MacTheme.Color.label
            quiet = MacTheme.Color.secondaryLabel
        case .pending:
            ground.fill = MacTheme.Color.canvasRaised
            ground.stroke = MacTheme.Color.accent.withAlphaComponent(0.5)
            ink = MacTheme.Color.label
            quiet = MacTheme.Color.secondaryLabel
        case .skipped, .belowStart, .beyondCeiling:
            ground.fill = MacTheme.Color.canvasRaised.withAlphaComponent(0.5)
            ink = MacTheme.Color.tertiaryLabel
            quiet = MacTheme.Color.tertiaryLabel
            toned = false
        case nil:
            ground.fill = MacTheme.Color.canvasRaised
            ground.stroke = MacTheme.Color.separator
            ink = MacTheme.Color.label
            quiet = MacTheme.Color.secondaryLabel
        }
        ground.radius = MacTheme.Radius.control
        addSubview(ground)
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        hug.isActive = true
        var views: [NSView] = [
            RowKit.label(title + (cap ? " ⌃" : ""), font: MacTheme.Ramp.font(.rowTitleStrong), color: ink)
        ]
        if let model, !model.isEmpty {
            let label = RowKit.label(model, font: MacTheme.Ramp.font(.code), color: quiet)
            label.toolTip = fullModel
            views.append(label)
        }
        for (text, tone) in notes {
            guard let text, !text.isEmpty else { continue }
            let color = toned && tone != .quiet ? tone.color : quiet
            views.append(RowKit.label(text, font: MacTheme.Ramp.font(.rowMeta), color: color))
        }
        for view in views {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let lines = NSStackView(views: views)
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            lines.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -MacTheme.Spacing.s),
        ])
        for view in views {
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * MacTheme.Spacing.s).isActive = true
        }
        let said = ([title, model] + notes.map { $0.0 }).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        toolTip = said
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(said)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Cards side by side, each as wide as the next and joined by a chevron, cheapest first.
    static func row(_ cards: [DelegateRungCard]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        for (index, card) in cards.enumerated() {
            if index > 0 {
                let link = RowKit.label("›", font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.tertiaryLabel)
                link.setContentHuggingPriority(.required, for: .horizontal)
                link.setContentCompressionResistancePriority(.required, for: .horizontal)
                row.addArrangedSubview(link)
            }
            card.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(card)
            if index > 0 {
                card.widthAnchor.constraint(equalTo: cards[0].widthAnchor).isActive = true
                card.heightAnchor.constraint(equalTo: cards[0].heightAnchor).isActive = true
            }
        }
        return row
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        onClick(event.modifierFlags.contains(.shift))
    }

    /// A rung the composer lets a person pick is a stop in the Tab loop with Full Keyboard
    /// Access on: Space or Return picks it the way a click does, and with Shift the way a
    /// Shift-click does. The ladder was the one part of a packet only a mouse could set.
    override var acceptsFirstResponder: Bool {
        onClick != nil && NSApp.isFullKeyboardAccessEnabled
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: MacTheme.Radius.control,
            yRadius: MacTheme.Radius.control
        ).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard let onClick, [49, 36, 76].contains(event.keyCode) else {
            return super.keyDown(with: event)
        }
        onClick(event.modifierFlags.contains(.shift))
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(false)
        return onClick != nil
    }
}

/// The ladder as rungs in a row. Reading, each wears its state and the run's word for it;
/// composing, a click is the start rung and a shift-click is the ceiling, and a click on the start
/// rung again unsets it.
@MainActor
final class MacLadderView: NSView {
    var compose = false
    var rungs: [DelegateRung] = [] { didSet { rebuild() } }
    private(set) var start: String?
    private(set) var ceiling: String?
    /// Where the run will start and stop when nothing is set — the class's own range, drawn so
    /// "the class decides" is a picture rather than a shrug.
    private var impliedStart: String?
    private var impliedCeiling: String?
    private var ladder: DelegateLadder?
    var onChange: ((String?, String?) -> Void)?
    private var row: NSStackView?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        hug.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A run's ladder, each rung saying where it stands in the run's own words.
    func show(_ ladder: DelegateLadder) {
        self.ladder = ladder
        toolTip = ladder.spoken
        rungs = ladder.rungs
    }

    func set(start: String?, ceiling: String?) {
        self.start = start
        self.ceiling = ceiling
        rebuild()
    }

    func setImplied(start: String?, ceiling: String?) {
        guard impliedStart != start || impliedCeiling != ceiling else { return }
        impliedStart = start
        impliedCeiling = ceiling
        rebuild()
    }

    private func index(of tier: String) -> Int { rungs.firstIndex { $0.tier == tier } ?? 0 }

    private func rebuild() {
        row?.removeFromSuperview()
        let chosenStart = start.map(index(of:))
        let startIndex = chosenStart ?? impliedStart.map(index(of:))
        let ceilingIndex = (ceiling ?? impliedCeiling).map(index(of:))
        var cards: [DelegateRungCard] = []
        for (offset, rung) in rungs.enumerated() {
            let state: DelegateRungState
            if compose {
                if let startIndex, offset < startIndex {
                    state = .belowStart
                } else if let ceilingIndex, offset > ceilingIndex {
                    state = .beyondCeiling
                } else if let chosenStart, offset == chosenStart {
                    state = .current
                } else {
                    state = .pending
                }
            } else {
                state = rung.state
            }
            let word = compose ? rung.note : (ladder?.word(for: rung) ?? DelegateLadder.word(state))
            let card = DelegateRungCard(
                title: rung.label.isEmpty ? rung.tier : "\(rung.tier) · \(rung.label)",
                model: rung.model.map(DelegateWords.shortModel), fullModel: rung.model,
                notes: [(word, compose ? .quiet : state.tone)], state: state,
                cap: compose && ceilingIndex == offset)
            if compose {
                card.onClick = { [weak self] shift in self?.clicked(rung.tier, shift: shift) }
            }
            cards.append(card)
        }
        let row = DelegateRungCard.row(cards)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.row = row
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
}

/// The one thing that matters about a run right now, in a card tinted by what it means: why it
/// stopped with the verifier's own last lines, the rung waiting for you, the patch to review.
@MainActor
final class DelegateLeadCard: NSView {
    init(_ lead: DelegateRunReading.Lead) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let tint = lead.tone == .quiet ? MacTheme.Color.secondaryLabel : lead.tone.color
        let ground = RowKit.Ground(frame: .zero)
        ground.fill = tint.withAlphaComponent(0.08)
        ground.radius = MacTheme.Radius.card
        addSubview(ground)
        let bar = RowKit.Ground(frame: .zero)
        bar.fill = tint
        bar.radius = 1.5
        addSubview(bar)

        let title = RowKit.label(lead.title, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var top: [NSView] = [title]
        if let caption = lead.caption {
            let label = RowKit.label(caption, font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.secondaryLabel)
            label.alignment = .right
            label.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            top.append(label)
        }
        let topRow = NSStackView(views: top)
        topRow.orientation = .horizontal
        topRow.distribution = .fill
        topRow.alignment = .firstBaseline
        topRow.spacing = MacTheme.Spacing.m
        var views: [NSView] = [topRow]
        if let body = lead.body, !body.isEmpty {
            if lead.bodyIsOutput {
                let text = RowKit.wrapping(body, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.label)
                let box = NSView()
                box.translatesAutoresizingMaskIntoConstraints = false
                RowKit.ground(behind: box, fill: MacTheme.Color.codeBackground, radius: MacTheme.Radius.control)
                box.addSubview(text)
                NSLayoutConstraint.activate([
                    text.topAnchor.constraint(equalTo: box.topAnchor, constant: MacTheme.Spacing.s),
                    text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -MacTheme.Spacing.s),
                    text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: MacTheme.Spacing.s),
                    text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -MacTheme.Spacing.s),
                ])
                views.append(box)
            } else {
                views.append(RowKit.wrapping(body, font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.secondaryLabel))
            }
        }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        for view in views {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.s),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.s),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.xs),
            bar.widthAnchor.constraint(equalToConstant: 3),
            column.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -MacTheme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: MacTheme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.m),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// One file of a run's patch: its name, its folder faint beside it, and how much it changes.
@MainActor
final class DelegateFileRowView: NSView {
    var onClick: (() -> Void)?
    private let ground = RowKit.Ground(frame: .zero)

    init(_ file: DelegateFileRow) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ground.radius = MacTheme.Radius.control
        addSubview(ground)
        let name = RowKit.label(file.name, font: MacTheme.Ramp.font(.rowTitle), color: MacTheme.Color.label)
        name.setContentHuggingPriority(.required, for: .horizontal)
        var views: [NSView] = [name]
        if !file.folder.isEmpty {
            let folder = RowKit.label(file.folder, font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.tertiaryLabel)
            folder.lineBreakMode = .byTruncatingHead
            folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(folder)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        if let added = file.added, let removed = file.removed, added + removed > 0 {
            if added > 0 { views.append(Self.count("+\(added)", MacTheme.Color.success)) }
            if removed > 0 { views.append(Self.count("−\(removed)", MacTheme.Color.danger)) }
        } else if let counts = file.counts {
            views.append(Self.count(counts, MacTheme.Color.tertiaryLabel))
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = MacTheme.Spacing.s
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            ground.topAnchor.constraint(equalTo: topAnchor),
            ground.bottomAnchor.constraint(equalTo: bottomAnchor),
            ground.leadingAnchor.constraint(equalTo: leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor, constant: MacTheme.Spacing.xs + 1),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(MacTheme.Spacing.xs + 1)),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MacTheme.Spacing.s),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MacTheme.Spacing.s),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        toolTip = file.path
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([file.path, file.counts].compactMap { $0 }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func count(_ text: String, _ color: NSColor) -> NSTextField {
        let label = RowKit.label(text, font: MacTheme.Ramp.font(.code), color: color)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    override func mouseEntered(with event: NSEvent) {
        ground.fill = MacTheme.Color.canvasRaised
        ground.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        ground.fill = nil
        ground.needsDisplay = true
    }

    @objc private func clicked() { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// One run read on the right, drawn from its `DelegateRunReading`: the headline and its facts, the
/// one thing that matters now, the ladder, exactly one primary action beside the rest, the patch's
/// files, and one timeline. Each part is rebuilt only when its own slice of the reading changed, so
/// a run streaming its story in grows its timeline without redrawing the screen above it.
@MainActor
final class DelegateRunView: NSView {
    var onAction: ((DelegateRunAction.Kind, String) -> Void)?
    var onFile: ((String, String) -> Void)?
    private let column = NSStackView()
    private let headerSlot = NSStackView()
    private let leadSlot = NSStackView()
    private let ladder = MacLadderView()
    private let actionsSlot = NSStackView()
    private let filesSlot = NSStackView()
    private let timelineSlot = NSStackView()
    private let nothing = NSTextField(wrappingLabelWithString: "")
    private var scroll: NSScrollView!
    private var drawn: Drawn?
    private var replayTiers: [String] = []

    private struct Drawn: Equatable {
        var scale: CGFloat
        var runID: String
        var header: [String?]
        var tone: ActivityTone
        var lead: DelegateRunReading.Lead?
        var ladder: DelegateLadder
        var primary: DelegateRunAction?
        var secondary: [DelegateRunAction]
        var replay: [String]
        var filesTitle: String?
        var files: [DelegateFileRow]
        var timeline: [DelegateStoryLine]
    }

    init() {
        super.init(frame: .zero)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.l
        column.edgeInsets = NSEdgeInsets(top: MacTheme.Spacing.l, left: MacTheme.Spacing.xl, bottom: MacTheme.Spacing.xl, right: MacTheme.Spacing.xl)
        for slot in [headerSlot, leadSlot, actionsSlot, filesSlot, timelineSlot] {
            slot.orientation = .vertical
            slot.alignment = .leading
            slot.spacing = 2
            slot.isHidden = true
        }
        actionsSlot.orientation = .horizontal
        actionsSlot.alignment = .centerY
        actionsSlot.spacing = MacTheme.Spacing.s
        headerSlot.spacing = MacTheme.Spacing.xs
        timelineSlot.spacing = 3
        for view in [headerSlot, leadSlot, ladder, actionsSlot, filesSlot, timelineSlot] {
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.xl).isActive = true
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Drops what was drawn, so the next reading rebuilds every part in the new theme or scale.
    func forget() { drawn = nil }

    func showNothing(_ text: String) {
        scroll.isHidden = true
        nothing.isHidden = false
        nothing.stringValue = text
        drawn = nil
    }

    func show(_ reading: DelegateRunReading, board: DelegateBoard) {
        scroll.isHidden = false
        nothing.isHidden = true
        let labels = board.tiers.reduce(into: [String: String]()) { $0[$1.tier] = $1.label }
        let next = Drawn(
            scale: MacTheme.UIScale.factor, runID: reading.runID,
            header: [reading.headline, reading.badge, reading.facts], tone: reading.tone,
            lead: reading.lead, ladder: reading.ladder, primary: reading.primary,
            secondary: reading.secondary, replay: reading.replayTiers.map { tier in
                labels[tier].flatMap { $0.isEmpty ? nil : "\(tier) · \($0)" } ?? tier
            },
            filesTitle: reading.filesTitle, files: reading.files, timeline: reading.timeline)
        let last = drawn?.scale == next.scale && drawn?.runID == next.runID ? drawn : nil
        drawn = next
        replayTiers = reading.replayTiers
        func changed<Part: Equatable>(_ part: KeyPath<Drawn, Part>) -> Bool {
            guard let last else { return true }
            return last[keyPath: part] != next[keyPath: part]
        }
        if changed(\.header) || changed(\.tone) { drawHeader(reading) }
        if changed(\.lead) { drawLead(reading.lead) }
        if changed(\.ladder) { ladder.show(reading.ladder) }
        if changed(\.primary) || changed(\.secondary) || changed(\.replay) {
            drawActions(reading, replayTitles: next.replay)
        }
        if changed(\.filesTitle) || changed(\.files) { drawFiles(reading) }
        if changed(\.timeline) { drawTimeline(reading.timeline) }
        if last == nil { scroll.contentView.scroll(to: .zero) }
    }

    private func refill(_ slot: NSStackView, with views: [NSView], fill: Bool = true) {
        slot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            slot.addArrangedSubview(view)
            if fill { view.widthAnchor.constraint(equalTo: slot.widthAnchor).isActive = true }
        }
        slot.isHidden = views.isEmpty
    }

    private func drawHeader(_ reading: DelegateRunReading) {
        let headline = NSTextField(wrappingLabelWithString: reading.headline)
        headline.font = MacTheme.Ramp.font(.paneHeadline)
        headline.textColor = MacTheme.Color.label
        headline.isSelectable = false
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var top: [NSView] = [headline]
        if let badge = reading.badge { top.append(DelegatePill(badge, tone: reading.tone)) }
        let titleRow = NSStackView(views: top)
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        titleRow.alignment = .top
        titleRow.spacing = MacTheme.Spacing.m
        var views: [NSView] = [titleRow]
        if !reading.facts.isEmpty {
            views.append(RowKit.wrapping(reading.facts, font: MacTheme.Ramp.font(.rowMeta), color: MacTheme.Color.secondaryLabel))
        }
        refill(headerSlot, with: views)
    }

    private func drawLead(_ lead: DelegateRunReading.Lead?) {
        refill(leadSlot, with: lead.map { [DelegateLeadCard($0)] } ?? [])
    }

    private func drawActions(_ reading: DelegateRunReading, replayTitles: [String]) {
        var views: [NSView] = []
        let runID = reading.runID
        if let primary = reading.primary { views.append(button(primary, runID: runID)) }
        for action in reading.secondary { views.append(button(action, runID: runID)) }
        if !replayTitles.isEmpty {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.addItem(withTitle: DelegateRunReading.replayMenuTitle)
            popup.addItems(withTitles: replayTitles)
            popup.target = self
            popup.action = #selector(replayPicked(_:))
            popup.setContentHuggingPriority(.required, for: .horizontal)
            views.append(popup)
        }
        refill(actionsSlot, with: views, fill: false)
        if !views.isEmpty {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            actionsSlot.addArrangedSubview(spacer)
        }
    }

    private func button(_ action: DelegateRunAction, runID: String) -> NSButton {
        let kind = action.kind
        let button = RowKit.ActionButton(title: action.title) { [weak self] in self?.onAction?(kind, runID) }
        switch action.role {
        case .primary:
            button.bezelColor = MacTheme.Color.accent
            button.keyEquivalent = "\r"
        case .normal:
            break
        case .destructive:
            button.hasDestructiveAction = true
            button.contentTintColor = MacTheme.Color.danger
        }
        button.toolTip = action.detail
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func replayPicked(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard let runID = drawn?.runID, let tier = replayTiers.element(at: index) else { return }
        onAction?(.replay(tier: tier), runID)
    }

    private func drawFiles(_ reading: DelegateRunReading) {
        guard let title = reading.filesTitle, !reading.files.isEmpty else {
            refill(filesSlot, with: [])
            return
        }
        let runID = reading.runID
        var views: [NSView] = [MacDialogs.sectionHeader(title.uppercased())]
        for file in reading.files {
            let row = DelegateFileRowView(file)
            let path = file.path
            row.onClick = { [weak self] in self?.onFile?(path, runID) }
            views.append(row)
        }
        refill(filesSlot, with: views)
    }

    private func drawTimeline(_ lines: [DelegateStoryLine]) {
        var views: [NSView] = [MacDialogs.sectionHeader(DelegateRunReading.timelineTitle.uppercased())]
        if lines.isEmpty {
            views.append(RowKit.wrapping(Localized.text("Nothing yet."), font: MacTheme.Ramp.font(.rowNote), color: MacTheme.Color.tertiaryLabel))
        }
        for line in lines {
            let label = RowKit.wrapping(
                line.text, font: MacTheme.Ramp.font(line.isProgress ? .rowMeta : .rowDetail),
                color: line.isProgress || line.tone == .quiet ? MacTheme.Color.secondaryLabel : line.tone.color)
            views.append(line.isProgress ? Self.indented(label, rule: false) : label)
            if let detail = line.detail, !detail.isEmpty {
                let tail = RowKit.wrapping(detail, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.secondaryLabel)
                views.append(Self.indented(tail, rule: true))
            }
        }
        refill(timelineSlot, with: views)
    }

    /// A line set in under the one it belongs to — a worker's progress, or a failed attempt's own
    /// output behind a faint rule.
    private static func indented(_ view: NSView, rule: Bool) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        var constraints = [
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: rule ? 2 : 0),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: rule ? -4 : 0),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: MacTheme.Spacing.l + (rule ? MacTheme.Spacing.s : 0)),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ]
        if rule {
            let bar = RowKit.Ground(frame: .zero)
            bar.fill = MacTheme.Color.separator
            box.addSubview(bar)
            constraints += [
                bar.topAnchor.constraint(equalTo: view.topAnchor),
                bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                bar.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: MacTheme.Spacing.l),
                bar.widthAnchor.constraint(equalToConstant: 2),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return box
    }
}

/// The packet form as a sheet over the delegate window. It asks first for what only the person
/// knows — the goal, the repository (one click from where this machine's chats and runs work), the
/// paths, and whether the patch waits to be read — and folds everything the class already decides
/// into one Plan line that opens on demand. `DelegateDraft` decides every word and every rule.
@MainActor
final class DelegateComposerSheet: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    /// Every composer on screen, each kept alive by this list until its sheet ends. One slot held
    /// only the newest, so a second composer queued behind the first left the first one with
    /// nothing keeping it.
    private static var active: [DelegateComposerSheet] = []

    private let sheet: NSWindow
    private let host: String
    private let serverName: String
    private let desk = MacDelegateGate.desk
    private var draft: DelegateDraft
    private let repoChoices: [DelegateRepoChoice]
    private let onStarted: (String) -> Void
    private let classPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let repoField = NSTextField()
    private let repoPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let goalView = NSTextView.scrollableTextView()
    private let pathsView = NSTextView.scrollableTextView()
    private let reviewSwitch = NSSwitch()
    private let planToggle = NSButton()
    private let planSummary = NSTextField(labelWithString: "")
    private let planBody = NSStackView()
    private let verifyField = NSTextField()
    private let suggestionRow = NSStackView()
    private let readField = NSTextField()
    private let notesView = NSTextView.scrollableTextView()
    private let ladder = MacLadderView()
    private let legendLabel = NSTextField(wrappingLabelWithString: "")
    private let modeControl = NSSegmentedControl(labels: DelegateMode.allCases.map(DelegateWords.mode), trackingMode: .selectOne, target: nil, action: nil)
    private let effortControl = NSSegmentedControl(labels: [DelegateComposerWords.effortDefault] + DelegateEffort.allCases.map(DelegateWords.effort), trackingMode: .selectOne, target: nil, action: nil)
    private let problems = NSTextField(wrappingLabelWithString: "")
    private let cautions = NSTextField(wrappingLabelWithString: "")
    private let sendButton = RowKit.ActionButton(title: DelegateComposerWords.sendTitle, action: {})
    private var sending = false

    static func present(
        on window: NSWindow, host: String, serverName: String, draft: DelegateDraft? = nil,
        repoChoices: [DelegateRepoChoice] = [], onStarted: @escaping (String) -> Void
    ) {
        let made = DelegateComposerSheet(host: host, serverName: serverName, draft: draft, repoChoices: repoChoices, onStarted: onStarted)
        active.append(made)
        window.beginSheet(made.sheet) { _ in Self.active.removeAll { $0 === made } }
        made.sheet.makeFirstResponder(made.goalView.documentView)
    }

    private var board: DelegateBoard { desk.board(host: host, serverName: serverName) }

    private init(host: String, serverName: String, draft: DelegateDraft?, repoChoices: [DelegateRepoChoice], onStarted: @escaping (String) -> Void) {
        self.host = host
        self.serverName = serverName
        self.onStarted = onStarted
        self.repoChoices = repoChoices
        let board = MacDelegateGate.desk.board(host: host, serverName: serverName)
        self.draft = draft ?? DelegateDraft(capabilities: board.capabilities, repo: repoChoices.first?.path ?? "")
        sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.title = DelegateComposerWords.title
        sheet.isReleasedWhenClosed = false
        sheet.contentMinSize = NSSize(width: 540, height: 520)
        MacTheme.Chrome.adopt(sheet)
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
        let label = RowKit.label(title, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        var views: [NSView] = [label, view]
        if let help { views.append(MacDialogs.detailLabel(help, wraps: true)) }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.xs
        for view in views.dropFirst() {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return column
    }

    private func makeContent(board: DelegateBoard) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.l
        column.edgeInsets = NSEdgeInsets(top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l, right: MacTheme.Spacing.l)

        let heading = RowKit.label(DelegateComposerWords.title, font: MacTheme.Ramp.font(.panelTitle), color: MacTheme.Color.label)
        let machine = RowKit.label(serverName, font: MacTheme.Ramp.font(.panelDetail), color: MacTheme.Color.secondaryLabel)
        let titleRow = NSStackView(views: [heading, machine])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(titleRow)

        (goalView.documentView as? NSTextView)?.string = draft.goal
        column.addArrangedSubview(labelled(DelegateComposerWords.goalLabel, textView(goalView, height: 120), help: DelegateComposerWords.goalPlaceholder))

        repoField.stringValue = draft.repo
        repoField.placeholderString = DelegateComposerWords.repoPlaceholder
        repoField.font = MacTheme.Ramp.font(.code)
        repoField.delegate = self
        repoField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        repoField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var repoViews: [NSView] = [repoField]
        if !repoChoices.isEmpty {
            repoPopup.addItem(withTitle: DelegateComposerWords.repoChoicesLabel)
            for choice in repoChoices {
                let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
                item.subtitle = choice.detail
                item.toolTip = choice.path
                item.representedObject = choice.path
                repoPopup.menu?.addItem(item)
            }
            repoPopup.target = self
            repoPopup.action = #selector(repoPicked)
            repoPopup.setContentHuggingPriority(.required, for: .horizontal)
            repoPopup.setContentCompressionResistancePriority(.required, for: .horizontal)
            repoViews.append(repoPopup)
        }
        let repoRow = NSStackView(views: repoViews)
        repoRow.orientation = .horizontal
        repoRow.distribution = .fill
        repoRow.alignment = .centerY
        repoRow.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(labelled(DelegateComposerWords.repoLabel, repoRow))

        (pathsView.documentView as? NSTextView)?.string = draft.paths
        column.addArrangedSubview(
            labelled(
                DelegateComposerWords.pathsLabel, textView(pathsView, height: 60, mono: true),
                help: DelegateComposerWords.pathsHelp + " " + DelegateComposerWords.pathsOptional))

        column.addArrangedSubview(reviewRow(board: board))
        column.addArrangedSubview(planHeader())
        buildPlanBody(board: board)
        column.addArrangedSubview(planBody)

        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * MacTheme.Spacing.l).isActive = true
        }
        let scroll = MacDialogs.scrollColumn(holding: column)

        cautions.font = MacTheme.Ramp.font(.rowNote)
        cautions.textColor = MacTheme.Color.warning
        problems.font = MacTheme.Ramp.font(.rowNote)
        problems.textColor = MacTheme.Color.danger
        let cancel = RowKit.ActionButton(title: Localized.text("Cancel")) { [weak self] in self?.close() }
        cancel.keyEquivalent = "\u{1b}"
        sendButton.setAction { [weak self] in self?.send() }
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = .command
        sendButton.bezelColor = MacTheme.Color.accent
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, sendButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .fill
        buttons.spacing = MacTheme.Spacing.s
        let footer = NSStackView(views: [cautions, problems, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = MacTheme.Spacing.xs
        footer.edgeInsets = NSEdgeInsets(top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l, right: MacTheme.Spacing.l)
        footer.translatesAutoresizingMaskIntoConstraints = false
        for view in footer.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -2 * MacTheme.Spacing.l).isActive = true
        }
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(rule)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: rule.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Whether the patch waits to be read: on by default wherever the dispatcher can hold one, and
    /// saying plainly where it cannot.
    private func reviewRow(board: DelegateBoard) -> NSView {
        let supported = board.supportsReview
        let title = RowKit.label(DelegateComposerWords.reviewLabel, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        let help = MacDialogs.detailLabel(
            supported ? DelegateComposerWords.reviewHelp : DelegateComposerWords.reviewUnsupported, wraps: true)
        let words = NSStackView(views: [title, help])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        help.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        reviewSwitch.state = supported && draft.review ? .on : .off
        reviewSwitch.isEnabled = supported
        reviewSwitch.target = self
        reviewSwitch.action = #selector(reviewChanged)
        reviewSwitch.setAccessibilityLabel(DelegateComposerWords.reviewLabel)
        reviewSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [words, reviewSwitch])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = MacTheme.Spacing.m
        return row
    }

    /// The Plan line: everything the class already decides, summed up in one line and opened on
    /// demand.
    private func planHeader() -> NSView {
        planToggle.bezelStyle = .disclosure
        planToggle.setButtonType(.pushOnPushOff)
        planToggle.title = ""
        planToggle.state = .off
        planToggle.target = self
        planToggle.action = #selector(planToggled)
        planToggle.setAccessibilityLabel(DelegateComposerWords.planLabel)
        planToggle.setContentHuggingPriority(.required, for: .horizontal)
        let title = RowKit.label(DelegateComposerWords.planLabel, font: MacTheme.Ramp.font(.rowTitleStrong), color: MacTheme.Color.label)
        planSummary.font = MacTheme.Ramp.font(.rowMeta)
        planSummary.textColor = MacTheme.Color.secondaryLabel
        planSummary.lineBreakMode = .byTruncatingTail
        planSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let words = NSStackView(views: [title, planSummary])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [planToggle, words])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .top
        row.spacing = MacTheme.Spacing.xs
        row.toolTip = DelegateComposerWords.planHelp
        words.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(planHeaderClicked)))
        return row
    }

    private func buildPlanBody(board: DelegateBoard) {
        planBody.orientation = .vertical
        planBody.alignment = .leading
        planBody.spacing = MacTheme.Spacing.l
        planBody.edgeInsets = NSEdgeInsets(top: 0, left: MacTheme.Spacing.l, bottom: 0, right: 0)
        planBody.isHidden = true

        classPopup.addItems(withTitles: board.classes.isEmpty ? [draft.taskClass] : board.classes)
        classPopup.selectItem(withTitle: draft.taskClass)
        classPopup.target = self
        classPopup.action = #selector(classChanged)
        planBody.addArrangedSubview(labelled(DelegateComposerWords.classLabel, classPopup, help: DelegateComposerWords.classHelp))

        verifyField.stringValue = draft.verify
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
        planBody.addArrangedSubview(labelled(DelegateComposerWords.verifyLabel, verifyColumn, help: DelegateComposerWords.verifyHelp))

        ladder.compose = true
        ladder.rungs = board.composerRungs(taskClass: draft.taskClass)
        ladder.set(start: draft.tier, ceiling: draft.ceiling)
        ladder.onChange = { [weak self] start, ceiling in
            self?.draft.tier = start
            self?.draft.ceiling = ceiling
            self?.render()
        }
        legendLabel.font = MacTheme.Ramp.font(.rowNote)
        legendLabel.textColor = MacTheme.Color.success
        let ladderBlock = labelled(DelegateComposerWords.ladderLabel, ladder, help: Localized.text("Click a rung to start there; shift-click sets how far the run may climb. Unset means the class decides."))
        ladderBlock.insertArrangedSubview(legendLabel, at: 2)
        legendLabel.widthAnchor.constraint(equalTo: ladderBlock.widthAnchor).isActive = true
        planBody.addArrangedSubview(ladderBlock)

        modeControl.selectedSegment = DelegateMode.allCases.firstIndex(of: draft.mode) ?? 0
        modeControl.target = self
        modeControl.action = #selector(fieldChanged)
        planBody.addArrangedSubview(labelled(DelegateComposerWords.modeLabel, modeControl))
        effortControl.selectedSegment = draft.effort.flatMap { DelegateEffort.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        effortControl.target = self
        effortControl.action = #selector(fieldChanged)
        planBody.addArrangedSubview(labelled(DelegateComposerWords.effortLabel, effortControl))

        readField.stringValue = draft.read
        readField.placeholderString = "README.md"
        readField.font = MacTheme.Ramp.font(.code)
        readField.delegate = self
        planBody.addArrangedSubview(labelled(DelegateComposerWords.readLabel, readField))
        (notesView.documentView as? NSTextView)?.string = draft.notes
        planBody.addArrangedSubview(labelled(DelegateComposerWords.notesLabel, textView(notesView, height: 50)))
        for view in planBody.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: planBody.widthAnchor, constant: -MacTheme.Spacing.l).isActive = true
        }
    }

    @objc private func planHeaderClicked() {
        planToggle.state = planToggle.state == .on ? .off : .on
        planToggled()
    }

    @objc private func planToggled() {
        planBody.isHidden = planToggle.state != .on
    }

    @objc private func reviewChanged() {
        draft.review = reviewSwitch.state == .on
    }

    @objc private func repoPicked() {
        guard let path = repoPopup.selectedItem?.representedObject as? String else { return }
        repoField.stringValue = path
        fieldChanged()
    }

    func textDidChange(_ notification: Notification) { fieldChanged() }

    @objc private func classChanged() {
        guard let name = classPopup.titleOfSelectedItem else { return }
        draft.choose(taskClass: name, capabilities: board.capabilities)
        verifyField.stringValue = draft.verify
        ladder.rungs = board.composerRungs(taskClass: name)
        ladder.set(start: draft.tier, ceiling: draft.ceiling)
        fieldChanged()
    }

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
        self.cautions.stringValue = cautions.joined(separator: "\n")
        self.cautions.isHidden = cautions.isEmpty
        sendButton.isEnabled = draft.canSend && !sending
        sendButton.title = sending ? DelegateComposerWords.sendingTitle : DelegateComposerWords.sendTitle
        renderLegend()
        suggestionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for suggestion in DelegateDraft.verifySuggestions(paths: draft.pathList, repo: draft.repo) where suggestion != draft.verify {
            suggestionRow.addArrangedSubview(RowKit.ActionButton(title: suggestion) { [weak self] in
                self?.verifyField.stringValue = suggestion
                self?.fieldChanged()
            })
        }
        suggestionRow.isHidden = suggestionRow.arrangedSubviews.isEmpty
    }

    /// The one sentence that resolves the ladder the way the daemon will, the implied range drawn
    /// on the rungs so an unset ladder is still a picture, and the Plan line that sums it all up.
    private func renderLegend() {
        let plan = draft.plan(capabilities: board.capabilities, tierOrder: board.tierOrder)
        legendLabel.stringValue = plan.legend
        ladder.setImplied(start: plan.start, ceiling: plan.ceiling)
        planSummary.stringValue = draft.planSummary(capabilities: board.capabilities, tierOrder: board.tierOrder)
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
