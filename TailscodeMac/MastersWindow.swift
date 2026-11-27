import AppKit
import CodingAgentKit
import CodingAgentKitApple
import MidgarCore
import TailscodeCore

/// Every machine's masters in one window: the shelf on the left — each master's mark, name, the one
/// state line and the notes waiting — and the chosen master's page on the right. New master at the
/// shelf's foot starts one from a skill on a machine or blank. The machine keeps the masters, so
/// the window draws what the desk last read and reads every ten seconds while it is open.
@MainActor
final class MastersWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let listScroll = NSScrollView()
    let page = MasterPageView()
    private let empty = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: MasterWords.empty)
    private let emptyDetail = NSTextField(wrappingLabelWithString: MasterWords.emptyDetail)
    private let emptyNew = NSButton()
    private let newButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let silent = NSTextField(wrappingLabelWithString: "")
    private var rows: [MasterRow] = []
    private var selectedID: String?
    private var skills: [String: [ExpertSkill]] = [:]
    private var skillMenus: [String: NSMenu] = [:]
    private var readingSkills: Set<String> = []
    private var proveClock: Timer?

    var onNewTask: ((MasterRow) -> Void)?
    var onEdit: ((MasterRow) -> Void)?
    var onCreateBlank: ((ConnectionProfile) -> Void)?
    var onCreateFromSkill: ((ConnectionProfile, ExpertSkill) -> Void)?
    var onOpenChat: ((String, String) -> Void)?
    var onOpenSchedule: ((String) -> Void)?
    var onHandFailure: ((MasterRow, ExpertGuard) -> Void)?
    var onToast: ((String) -> Void)?

    /// What the window lists, for a harness.
    var shownRows: [MasterRow] { rows }
    var selectedRow: MasterRow? { rows.first { $0.id == selectedID } }
    var newMenu: NSMenu? { newButton.menu }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 740),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.title = MasterWords.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.titlebarAppearsTransparent = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        window.setFrameAutosaveName("TailscodeMasters")
        for name in [MasterDesk.didChange, MachineDesk.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadIfShown() }
            }
        }
        page.onNewTask = { [weak self] row in self?.onNewTask?(row) }
        page.onEdit = { [weak self] row in self?.onEdit?(row) }
        page.onDelete = { [weak self] row in self?.confirmDelete(row) }
        page.onOpenChat = { [weak self] profileID, session in self?.onOpenChat?(profileID, session) }
        page.onOpenSchedule = { [weak self] id in self?.onOpenSchedule?(id) }
        page.onHandFailure = { [weak self] row, item in self?.onHandFailure?(row, item) }
        page.onShowBrief = { [weak self] row in self?.showBrief(row) }
        page.onToast = { [weak self] text in self?.onToast?(text) }
        reload()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        MidgarSignals.noteScreen("masters", feature: true)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Opens the window on a master. A page that opens is proved, so a bench unplugged while the
    /// window was closed never reads as it was when it closed.
    func present(selecting id: String? = nil) {
        let previous = page.row?.id
        if let id { selectedID = MasterDesk.shared.row(id: id)?.id ?? id }
        reload()
        if page.row?.id == previous { page.prove() }
        window?.makeKeyAndOrderFront(nil)
        startWatching()
        Task { await MasterDesk.shared.refresh() }
    }

    func windowWillClose(_ notification: Notification) { stopWatching() }
    func windowDidMiniaturize(_ notification: Notification) { stopWatching() }

    func windowDidDeminiaturize(_ notification: Notification) {
        startWatching()
        page.prove()
    }

    /// While the window is shown the desk reads every machine often and the page's bench is
    /// proved every five minutes; a closed or minimised window asks nothing of any machine.
    private func startWatching() {
        MasterDesk.shared.watch(self)
        guard proveClock == nil else { return }
        proveClock = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.page.prove() }
        }
    }

    private func stopWatching() {
        MasterDesk.shared.unwatch(self)
        proveClock?.invalidate()
        proveClock = nil
    }

    var isWatching: Bool { proveClock != nil }

    /// A window nobody sees is not redrawn; `present` draws it afresh when it opens.
    private func reloadIfShown() {
        guard window?.isVisible == true else { return }
        reload()
    }

    private func makeContent() -> NSView {
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.menu = NSMenu()
        table.menu?.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("master"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        newButton.bezelStyle = .push
        newButton.controlSize = .small
        newButton.addItem(withTitle: MasterWords.newMaster)
        newButton.menu?.delegate = self
        newButton.translatesAutoresizingMaskIntoConstraints = false

        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(listScroll)
        side.addSubview(newButton)
        silent.font = MacTheme.Ramp.font(.panelFootnote)
        silent.textColor = MacTheme.Color.secondaryLabel
        silent.isHidden = true
        silent.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(silent)

        emptyTitle.font = MacTheme.Ramp.font(.cardTitle)
        emptyDetail.font = MacTheme.Ramp.font(.panelDetail)
        emptyDetail.textColor = MacTheme.Color.secondaryLabel
        emptyDetail.alignment = .center
        emptyDetail.preferredMaxLayoutWidth = 420
        emptyNew.title = MasterWords.newMaster + "…"
        emptyNew.bezelStyle = .push
        emptyNew.target = self
        emptyNew.action = #selector(emptyNewTapped)
        let symbol = NSImageView(
            image: NSImage(systemSymbolName: "person.crop.rectangle.stack", accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        symbol.contentTintColor = MacTheme.Color.tertiaryLabel
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = MacTheme.Spacing.s
        for view in [symbol, emptyTitle, emptyDetail, emptyNew] { empty.addArrangedSubview(view) }
        empty.setCustomSpacing(MacTheme.Spacing.l, after: emptyDetail)
        empty.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(side)
        root.addSubview(page)
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 280),
            listScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: side.safeAreaLayoutGuide.topAnchor, constant: MacTheme.Spacing.s),
            listScroll.bottomAnchor.constraint(equalTo: silent.topAnchor, constant: -MacTheme.Spacing.xs),
            silent.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: MacTheme.Spacing.m),
            silent.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -MacTheme.Spacing.m),
            silent.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -MacTheme.Spacing.s),
            newButton.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: MacTheme.Spacing.m),
            newButton.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -MacTheme.Spacing.m),
            page.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            page.topAnchor.constraint(equalTo: root.topAnchor),
            page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -48),
        ])
        return root
    }

    /// The shelf is redrawn in place when the same masters are listed in the same order, so the
    /// selection and the keyboard's place in it live through a read; a list that changed is reloaded.
    func reload() {
        let fresh = MasterDesk.shared.board.rows
        if fresh.map(\.id) == rows.map(\.id) {
            rows = fresh
            for index in rows.indices {
                (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MasterShelfCell)?.configure(rows[index])
            }
        } else {
            rows = fresh
            table.reloadData()
        }
        if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id
        }
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        let row = rows.first { $0.id == selectedID }
        page.isHidden = row == nil
        empty.isHidden = row != nil
        emptyNew.isEnabled = !MasterDesk.shared.makers.isEmpty
        let desk = MasterDesk.shared
        if desk.board.machines.isEmpty, let silent = desk.silentLine {
            emptyDetail.stringValue = silent
        } else if !desk.anyKeepsMasters, desk.loadedOnce {
            emptyDetail.stringValue = MasterWords.cannotKeep(
                MachineDesk.shared.servers().first?.profile.name ?? Localized.text("This machine"))
        } else {
            emptyDetail.stringValue = MasterWords.emptyDetail
        }
        silent.stringValue = desk.silentLine ?? ""
        silent.isHidden = desk.silentLine == nil || rows.isEmpty
        if let row { page.show(row) }
    }

    func select(id: String) {
        selectedID = MasterDesk.shared.row(id: id)?.id ?? id
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = MasterShelfCell()
        cell.configure(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = table.selectedRow
        guard rows.indices.contains(index), rows[index].id != selectedID else { return }
        selectedID = rows[index].id
        page.show(rows[index])
        page.isHidden = false
        empty.isHidden = true
    }

    @objc private func doubleClicked() {
        let index = table.clickedRow
        guard rows.indices.contains(index) else { return }
        onNewTask?(rows[index])
    }

    @objc private func emptyNewTapped(_ sender: NSButton) {
        let menu = NSMenu()
        fillNewMenu(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// New master: for every machine that keeps masters, its skills and a blank start.
    private func fillNewMenu(_ menu: NSMenu) {
        skillMenus = [:]
        let makers = MasterDesk.shared.makers
        guard !makers.isEmpty else {
            let none = NSMenuItem(title: MasterWords.cannotKeep(Localized.text("No machine")), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for (index, profile) in makers.enumerated() {
            if makers.count > 1 {
                if index > 0 { menu.addItem(.separator()) }
                let header = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            let skillItem = NSMenuItem(title: MasterWords.makeFromSkill, action: nil, keyEquivalent: "")
            let skillMenu = NSMenu()
            skillMenus[profile.id] = skillMenu
            fillSkillMenu(skillMenu, for: profile)
            if skills[profile.id] == nil { loadSkills(profile) }
            skillItem.submenu = skillMenu
            menu.addItem(skillItem)
            let blank = NSMenuItem(title: MasterWords.makeBlank + "…", action: #selector(blankChosen(_:)), keyEquivalent: "")
            blank.representedObject = profile.id
            blank.target = self
            menu.addItem(blank)
        }
    }

    /// A machine's skills, a line saying they are being read, or — read and none — a line that
    /// says so; filled again in place when the read lands, even while the menu is open.
    private func fillSkillMenu(_ menu: NSMenu, for profile: ConnectionProfile) {
        menu.removeAllItems()
        guard let known = skills[profile.id] else {
            let reading = NSMenuItem(title: Localized.text("Reading the machine's skills…"), action: nil, keyEquivalent: "")
            reading.isEnabled = false
            menu.addItem(reading)
            return
        }
        guard !known.isEmpty else {
            let none = NSMenuItem(title: Localized.text("No skills on %@", profile.name), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for skill in known {
            let item = NSMenuItem(title: skill.name, action: #selector(skillChosen(_:)), keyEquivalent: "")
            item.toolTip = skill.description
            item.representedObject = (profile.id, skill.name)
            item.target = self
            menu.addItem(item)
        }
    }

    /// A read that fails leaves nothing cached, so the next open asks again instead of saying the
    /// machine has no skills.
    private func loadSkills(_ profile: ConnectionProfile) {
        guard let keeping = MasterDesk.shared.keeping(for: profile.id), !readingSkills.contains(profile.id) else { return }
        readingSkills.insert(profile.id)
        Task { [weak self] in
            let found = try? await keeping.expertSkills()
            guard let self else { return }
            self.readingSkills.remove(profile.id)
            guard let found else { return }
            self.skills[profile.id] = found
            if let menu = self.skillMenus[profile.id] { self.fillSkillMenu(menu, for: profile) }
        }
    }

    @objc private func skillChosen(_ sender: NSMenuItem) {
        guard let (profileID, name) = sender.representedObject as? (String, String),
            let profile = MasterDesk.shared.profile(profileID),
            let skill = skills[profileID]?.first(where: { $0.name == name })
        else { return }
        onCreateFromSkill?(profile, skill)
    }

    @objc private func blankChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let profile = MasterDesk.shared.profile(id) else { return }
        onCreateBlank?(profile)
    }

    private func confirmDelete(_ row: MasterRow) {
        MacDialogs.confirm(
            on: window, title: Localized.text("Delete %@?", row.master.name), body: MasterWords.deleteDetail,
            confirmLabel: MasterWords.delete
        ) { [weak self] in
            guard let keeping = MasterDesk.shared.keeping(for: row.profileID) else { return }
            Task {
                do {
                    try await keeping.deleteExpert(row.master.id)
                    MasterDesk.shared.forget(profileID: row.profileID, expertID: row.master.id)
                    self?.onToast?(Localized.text("Deleted %@", row.master.name))
                    await MasterDesk.shared.refresh()
                } catch {
                    self?.onToast?(AgentErrorText.readable(error))
                }
            }
        }
    }

    /// The brief a task of this master would start with now, read from the machine.
    func showBrief(_ row: MasterRow) {
        guard let window, let keeping = MasterDesk.shared.keeping(for: row.profileID) else { return }
        Task {
            let preview = try? await keeping.expertBrief(row.master.id)
            MasterBriefSheet.present(
                on: window, title: Localized.text("The brief %@ starts with", row.master.name),
                text: preview?.text ?? Localized.text("The machine did not answer."), tokens: preview?.tokens)
        }
    }
}

extension MastersWindow: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === newButton.menu {
            while menu.items.count > 1 { menu.removeItem(at: 1) }
            fillNewMenu(menu)
            return
        }
        menu.removeAllItems()
        let index = table.clickedRow
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        let task = NSMenuItem(title: MasterWords.newTask + "…", action: #selector(menuNewTask(_:)), keyEquivalent: "")
        task.representedObject = row.id
        task.target = self
        menu.addItem(task)
        let edit = NSMenuItem(title: MasterWords.edit + "…", action: #selector(menuEdit(_:)), keyEquivalent: "")
        edit.representedObject = row.id
        edit.target = self
        menu.addItem(edit)
        let brief = NSMenuItem(title: MasterWords.showBrief, action: #selector(menuBrief(_:)), keyEquivalent: "")
        brief.representedObject = row.id
        brief.target = self
        menu.addItem(brief)
        menu.addItem(.separator())
        let delete = NSMenuItem(title: MasterWords.delete + "…", action: #selector(menuDelete(_:)), keyEquivalent: "")
        delete.representedObject = row.id
        delete.target = self
        menu.addItem(delete)
    }

    private func chosen(_ sender: NSMenuItem) -> MasterRow? {
        guard let id = sender.representedObject as? String else { return nil }
        return rows.first { $0.id == id }
    }

    @objc private func menuNewTask(_ sender: NSMenuItem) { if let row = chosen(sender) { onNewTask?(row) } }
    @objc private func menuEdit(_ sender: NSMenuItem) { if let row = chosen(sender) { onEdit?(row) } }
    @objc private func menuBrief(_ sender: NSMenuItem) { if let row = chosen(sender) { showBrief(row) } }
    @objc private func menuDelete(_ sender: NSMenuItem) { if let row = chosen(sender) { confirmDelete(row) } }
}

/// One master on the window's shelf: mark, name, state line in its tone, and the notes waiting.
@MainActor
final class MasterShelfCell: NSTableCellView {
    private let mark = MasterMarkView(glyph: "", hue: .blue, side: 30)
    private let name = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let badge = MasterBadgeView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.font = MacTheme.Ramp.font(.rowTitleStrong)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.font = MacTheme.Ramp.font(.panelFootnote)
        state.lineBreakMode = .byTruncatingTail
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lines = NSStackView(views: [name, state])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = masterSpacer()
        let row = NSStackView(views: [mark, lines, spacer, badge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s + 2
        row.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s, right: MacTheme.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: MasterRow) {
        mark.show(row)
        name.stringValue = row.master.name
        let line = row.state()
        state.stringValue = line.text
        state.textColor = MasterInk.color(line.tone)
        badge.show(MasterReading.badge(row.master))
        toolTip = [row.master.purpose, row.machine].filter { !$0.isEmpty }.joined(separator: " · ")
        setAccessibilityLabel([row.master.name, line.text].joined(separator: ", "))
    }
}

/// A brief, whole, in a sheet: monospaced, selectable, with its size in tokens.
@MainActor
enum MasterBriefSheet {
    static func present(on host: NSWindow, title: String, text: String, tokens: Int?) {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        sheet.title = title
        let heading = NSTextField(labelWithString: title)
        heading.font = MacTheme.Ramp.font(.cardTitle)
        let size = NSTextField(labelWithString: tokens.map(MasterWords.tokens) ?? "")
        size.font = MacTheme.Ramp.font(.panelFootnote)
        size.textColor = MacTheme.Color.secondaryLabel
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = MacTheme.Ramp.font(.code)
        textView.string = text
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        let done = NSButton(title: Localized.text("Done"), target: nil, action: nil)
        done.bezelStyle = .push
        done.keyEquivalent = "\r"
        let copy = NSButton(title: Localized.text("Copy"), target: nil, action: nil)
        copy.bezelStyle = .push
        let buttons = NSStackView(views: [copy, NSView(), done])
        buttons.orientation = .horizontal
        let root = NSView()
        for view in [heading, size, scroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            size.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            size.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: size.bottomAnchor, constant: MacTheme.Spacing.s),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: MacTheme.Spacing.m),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        sheet.contentView = root
        let actions = MasterSheetActions(
            done: { [weak host, weak sheet] in if let sheet { host?.endSheet(sheet) } },
            copy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
        done.target = actions
        done.action = #selector(MasterSheetActions.doneTapped)
        copy.target = actions
        copy.action = #selector(MasterSheetActions.copyTapped)
        objc_setAssociatedObject(sheet, &MasterSheetActions.key, actions, .OBJC_ASSOCIATION_RETAIN)
        host.beginSheet(sheet)
    }
}

/// The two presses a read-only sheet carries, kept alive by the sheet itself.
@MainActor
final class MasterSheetActions: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    private let done: () -> Void
    private let copy: () -> Void

    init(done: @escaping () -> Void, copy: @escaping () -> Void) {
        self.done = done
        self.copy = copy
    }

    @objc func doneTapped() { done() }
    @objc func copyTapped() { copy() }
}
