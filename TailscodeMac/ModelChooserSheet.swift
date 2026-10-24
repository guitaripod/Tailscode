import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// Every model the fleet offers, one machine at a time, as one list.
///
/// The pill's menu holds what this person actually works with; a catalog of two hundred entries
/// needs a surface you can search, and one that is organised by something a reader recognises. The
/// shared `ModelChooser` decides all of it — which machine is showing, the folding of the same
/// model offered by two providers, the family sections, the ranking, the cursor and the keys — and
/// this sheet draws its answer, so the Mac and the phone are the same list rendered twice.
@MainActor
final class ModelChooserSheet: NSObject {
    private enum Entry {
        case header(ModelChooserSection)
        case row(ModelChooserRow, index: Int)
    }

    private static var active: [ModelChooserSheet] = []

    private let sheet: NSWindow
    private var chooser: ModelChooser
    private let context: ChooserContext
    private let onPick: @MainActor (ModelPick) -> Void
    private var quotas: [UsageQuota]
    private let summary = FittedWrapLabel()
    private let field = NSSearchField()
    private let table = ModelChooserTable()
    private let scroll = NSScrollView()
    private let empty = FittedWrapLabel()
    private let fold = NSButton()
    private let machineStrip = ChipFlow()
    private let doorStrip = ChipFlow()
    private let consequence = FittedWrapLabel()
    private let hint = FittedWrapLabel()
    private var entries: [Entry] = []
    private var monitor: Any?
    private let onAddToParty: (@MainActor (ModelPick) -> String?)?
    /// Told once the sheet has gone, however it went, for a caller that has something to open in
    /// the sheet's place and cannot while it is still sliding away.
    var onEnded: (@MainActor () -> Void)?

    /// Every server the app knows, as the one list a chooser is built from — this conversation's
    /// own machine first. The pattern is Linux's chat pane's: catalogs come from the fleet's own
    /// memory, so the list can name what another server runs without this chat ever having talked
    /// to it, and a machine that did not answer reads as a state rather than as no models.
    static func fleetSources(
        profiles: [ConnectionProfile], current: String?, currentModels: [ModelInfo],
        backend: AgentType?, allowsServerDefault: Bool, reachable: Bool?
    ) -> [ModelSource] {
        var reachability: [String: Bool] = [:]
        if let current, let reachable { reachability[current] = reachable }
        let sources = ModelFleet.sources(
            profiles: profiles, current: current, currentModels: currentModels,
            allowsServerDefault: allowsServerDefault, reachability: reachability)
        guard sources.isEmpty else { return sources }
        let agent = backend ?? .openCode
        return [
            ModelSource(
                profileID: current ?? "", name: "", backend: agent, models: currentModels,
                isCurrent: true, allowsServerDefault: allowsServerDefault,
                acceptsAnyModelID: agent == .claudeCode, isReachable: reachable)
        ]
    }

    @discardableResult
    static func present(
        on host: NSWindow, sources: [ModelSource], selected: ModelSelection?,
        quotas: [UsageQuota] = [], context: ChooserContext = .chat,
        onAddToParty: (@MainActor (ModelPick) -> String?)? = nil,
        onPick: @escaping @MainActor (ModelPick) -> Void
    ) -> ModelChooserSheet {
        let controller = ModelChooserSheet(
            sources: sources, selected: selected, quotas: quotas, context: context,
            onAddToParty: onAddToParty, onPick: onPick)
        active.append(controller)
        host.beginSheet(controller.sheet) { _ in
            controller.teardown()
            active.removeAll { $0 === controller }
            controller.onEnded?()
        }
        controller.sheet.makeFirstResponder(controller.field)
        controller.revealCursor()
        return controller
    }

    private init(
        sources: [ModelSource], selected: ModelSelection?, quotas: [UsageQuota],
        context: ChooserContext, onAddToParty: (@MainActor (ModelPick) -> String?)?,
        onPick: @escaping @MainActor (ModelPick) -> Void
    ) {
        self.quotas = quotas
        self.context = context
        self.onAddToParty = onAddToParty
        chooser = ModelChooser(sources: sources, selected: selected, quotas: quotas)
        self.onPick = onPick
        sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.rememberedSize),
            styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered,
            defer: false)
        sheet.contentMinSize = Self.smallest
        super.init()

        let content = NSView()
        sheet.contentView = content

        summary.font = MacTheme.Ramp.font(.toolOutput)
        summary.textColor = MacTheme.Color.secondaryLabel
        summary.alignment = .left
        summary.maximumNumberOfLines = 2
        summary.cell?.truncatesLastVisibleLine = true
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.init(249), for: .horizontal)

        field.placeholderString = Localized.text("Search models, providers, ids")
        field.delegate = self

        consequence.font = MacTheme.Ramp.font(.rowNote)
        consequence.textColor = MacTheme.Color.warning
        consequence.isSelectable = false
        consequence.maximumNumberOfLines = 2

        fold.bezelStyle = .accessoryBarAction
        fold.controlSize = .small
        fold.target = self
        fold.action = #selector(foldAll)
        fold.setContentHuggingPriority(.required, for: .horizontal)

        let band = NSStackView(views: [summary, fold])
        band.orientation = .horizontal
        band.alignment = .firstBaseline
        band.spacing = MacTheme.Spacing.s

        let top = NSStackView(views: [field, machineStrip, doorStrip, consequence, band])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = MacTheme.Spacing.s
        top.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(top)

        table.headerView = nil
        table.rowSizeStyle = .custom
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.refusesFirstResponder = true
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.menuForRow = { [weak self] row in self?.partyMenu(entry: row) }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        empty.font = MacTheme.Ramp.font(.panelLabel)
        empty.textColor = MacTheme.Color.secondaryLabel
        empty.alignment = .center
        empty.isSelectable = false
        empty.maximumNumberOfLines = 0
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty)

        hint.stringValue = chooser.hint
        hint.font = MacTheme.Ramp.font(.rowNote)
        hint.textColor = MacTheme.Color.tertiaryLabel
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        let inset = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            field.widthAnchor.constraint(equalTo: top.widthAnchor),
            band.widthAnchor.constraint(equalTo: top.widthAnchor),
            consequence.widthAnchor.constraint(equalTo: top.widthAnchor),
            machineStrip.widthAnchor.constraint(equalTo: top.widthAnchor),
            doorStrip.widthAnchor.constraint(equalTo: top.widthAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: MacTheme.Spacing.s),
            scroll.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            empty.leadingAnchor.constraint(
                equalTo: scroll.leadingAnchor, constant: MacTheme.Spacing.l),
            empty.trailingAnchor.constraint(
                equalTo: scroll.trailingAnchor, constant: -MacTheme.Spacing.l),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: MacTheme.Spacing.xl),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: MacTheme.Spacing.s),
            hint.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])

        rebuildMachines()
        rebuild()
        installMonitor()
    }

    private func teardown() {
        briefingPopover?.close()
        briefingPopover = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let size = sheet.contentView?.frame.size {
            UserDefaults.standard.set(NSStringFromSize(size), forKey: Self.sizeKey)
        }
    }

    private static let sizeKey = "tailscode.mac.modelChooser.size"
    /// The narrowest sheet a row still reads whole in — name, wall with its reset, marks, star —
    /// at the type size in force, so a larger scale widens the floor rather than crushing the name.
    private static var smallest: NSSize {
        let room = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1_600, height: 1_000)
        let scale = MacTheme.UIScale.factor
        return NSSize(
            width: min(520 * scale, max(room.width - 80, 520)),
            height: min(420 * scale, max(room.height - 80, 420)))
    }

    /// Two hundred models read better on a tall sheet, so the sheet can be dragged bigger and
    /// opens next time at the size it was left.
    private static var rememberedSize: NSSize {
        guard let saved = UserDefaults.standard.string(forKey: sizeKey) else {
            return NSSize(width: 620, height: 620)
        }
        let size = NSSizeFromString(saved)
        let room = NSScreen.main?.visibleFrame.size ?? size
        return NSSize(
            width: min(max(size.width, smallest.width), max(room.width - 80, smallest.width)),
            height: min(max(size.height, smallest.height), max(room.height - 80, smallest.height)))
    }

    /// Closes the sheet without a pick.
    func dismiss() {
        sheet.sheetParent?.endSheet(sheet)
    }

    /// A catalog that arrived while the sheet is open: the list, the summary and the machine strip
    /// are re-answered from it, and what the reader was doing — the query, the tab — survives the
    /// answer. A server that comes back from a restart reaches the open sheet this way.
    func update(sources: [ModelSource], quotas: [UsageQuota]? = nil) {
        if let quotas { self.quotas = quotas }
        let query = chooser.query
        let machine = chooser.machine
        let door = chooser.door
        chooser = ModelChooser(sources: sources, selected: chooser.selected, quotas: self.quotas)
        chooser.search(query)
        chooser.setMachine(machine)
        chooser.setDoor(door)
        rebuildMachines()
        rebuild()
        revealCursor()
    }

    /// ⌃→ / ⌃← open and close a folded row, and ⌃1–9 take a machine's tab. ⌘P puts the model under
    /// the cursor in the party. AppKit hands ⌃N/⌃P
    /// to the field as `moveDown:`/`moveUp:` already, but the arrows and the digits with a
    /// modifier never reach `doCommandBy`. ⌘S stars whatever row the cursor is on — a chord,
    /// because a star is a decision made from the keyboard while the hand is already there.
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.sheet else { return event }
            if event.modifierFlags.contains(.command),
                event.charactersIgnoringModifiers?.lowercased() == "s"
            {
                guard let selection = self.chooser.focused?.selection else { return event }
                self.chooser.togglePin(selection)
                return self.refreshed()
            }
            if event.modifierFlags.contains(.command),
                event.charactersIgnoringModifiers?.lowercased() == "p"
            {
                guard let row = self.chooser.focused, self.addToParty(row) else { return event }
                return nil
            }
            if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control) {
                guard let digit = self.digit(of: event), self.handled(.door(digit == 0 ? nil : digit - 1))
                else { return event }
                self.machineChanged()
                return nil
            }
            guard event.modifierFlags.contains(.control) else { return event }
            let all = event.modifierFlags.contains(.shift)
            switch (event.keyCode, all) {
            case (124, true): return self.chooser.setAllCollapsed(false) ? self.refreshed() : event
            case (123, true): return self.chooser.setAllCollapsed(true) ? self.refreshed() : event
            case (124, false): return self.handled(.expand) ? self.refreshed() : event
            case (123, false): return self.handled(.collapse) ? self.refreshed() : event
            default: break
            }
            guard let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), digit > 0,
                self.handled(.machine(digit - 1))
            else { return event }
            self.machineChanged()
            return nil
        }
    }

    /// A state reached by hand, reached from the command line instead — `--open models:<steps>` —
    /// so a tab, a door, a search, an open row or a folded catalog can be measured with nobody at
    /// the keyboard. Steps are comma separated: `machine=N`, `door=N` (0 is every door),
    /// `search=text`, `expand`, `fold`.
    func demonstrate(_ script: String) {
        for step in script.split(separator: ",").map(String.init) {
            let parts = step.split(separator: "=", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts.first ?? "" {
            case "machine":
                if let index = Int(value), chooser.machines.indices.contains(index) {
                    _ = chooser.setMachine(chooser.machines[index].profileID)
                }
            case "door":
                if let index = Int(value) {
                    let doors = chooser.doors
                    _ = chooser.setDoor(index > 0 && index <= doors.count ? doors[index - 1].providerID : nil)
                }
            case "search":
                field.stringValue = value
                chooser.search(value)
            case "expand":
                if let index = chooser.rows.firstIndex(where: \.canExpand) {
                    chooser.focus(index)
                    _ = chooser.setExpanded(true, at: index)
                }
            case "fold":
                _ = chooser.setAllCollapsed(true)
            default:
                break
            }
        }
        rebuildMachines()
        rebuild()
        revealCursor()
    }

    private func handled(_ command: ModelChooserCommand) -> Bool {
        chooser.handle(command).handled
    }

    /// The digit under ⌥, read off the key rather than the character — with Option down the
    /// character is whatever the layout puts there, and on a Finnish keyboard ⌥2 is “@”.
    private func digit(of event: NSEvent) -> Int? {
        let keys: [UInt16: Int] = [
            29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        ]
        return keys[event.keyCode]
    }

    private func refreshed() -> NSEvent? {
        rebuildKeepingScroll()
        revealCursor()
        return nil
    }

    /// Reloading a table whose row count just changed clamps the clip view, and the reveal that
    /// follows then aims at a cursor that was never on screen — which is how opening one family
    /// threw the whole catalog past the place it was being read. Opening or shutting a fold is
    /// still the same list, so it is rebuilt around the position rather than over it.
    private func rebuildKeepingScroll() {
        let held = scroll.contentView.bounds.origin
        rebuild()
        scroll.contentView.scroll(to: held)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// One chip per machine, the tab under the cursor in accent. Drawn only past one machine: a
    /// tab bar with one tab is chrome pretending to be a control.
    private func rebuildMachines() {
        briefingPopover?.close()
        briefingPopover = nil
        machineStrip.isHidden = !chooser.showsMachines
        var chips: [NSView] = []
        if chooser.showsMachines {
            for (index, machine) in chooser.machines.enumerated() {
                chips.append(
                    MachineChip(
                        title: machine.title, count: machine.count, detail: machine.detail,
                        dot: Self.dot(machine.state), selected: index == chooser.machineIndex,
                        onInfo: { [weak self] anchor in
                            guard let self, let card = self.chooser.briefing(machine: machine.profileID)
                            else { return }
                            self.presentBriefing(card, from: anchor)
                        }
                    ) { [weak self] in
                        guard let self, self.chooser.setMachine(machine.profileID) else { return }
                        self.machineChanged()
                    })
            }
        }
        machineStrip.setChips(chips)
        rebuildDoors()
    }

    /// The doors under the tab — every door first, then each provider the machine reaches its
    /// models through, biggest first (⌥0–9). Drawn only past one door, and wrapped onto as many
    /// lines as the sheet's width asks for: a machine with a dozen providers is ordinary, and a
    /// strip that kept them on one line held the sheet twice as wide as anybody dragged it.
    private func rebuildDoors() {
        doorStrip.isHidden = !chooser.showsDoors
        guard chooser.showsDoors else {
            doorStrip.setChips([])
            return
        }
        var chips: [NSView] = []
        chips.append(
            MachineChip(
                title: Localized.text("All"), count: chooser.allDoorsCount,
                detail: Localized.text("Every provider this server reaches"), dot: nil,
                selected: chooser.doorIndex == 0
            ) { [weak self] in
                guard let self, self.chooser.setDoor(nil) else { return }
                self.machineChanged()
            })
        for (index, door) in chooser.doors.enumerated() {
            chips.append(
                MachineChip(
                    title: door.title, count: door.count, detail: door.detail,
                    dot: door.kind == .local ? MacTheme.Color.info : nil,
                    selected: index + 1 == chooser.doorIndex,
                    onInfo: { [weak self] anchor in
                        guard let self, let card = self.chooser.briefing(door: door.providerID)
                        else { return }
                        self.presentBriefing(card, from: anchor)
                    }
                ) { [weak self] in
                    guard let self, self.chooser.setDoor(door.providerID) else { return }
                    self.machineChanged()
                })
        }
        doorStrip.setChips(chips)
    }

    private static func dot(_ state: ModelMachineState) -> NSColor? {
        guard state.wearsDot else { return nil }
        return BriefingPanelViewController.colour(state.tone)
    }

    private var briefingPopover: NSPopover?

    /// The card behind a chip, in a popover off the chip itself.
    private func presentBriefing(_ card: ChooserBriefing, from anchor: NSView) {
        briefingPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.ground(BriefingPanelViewController(briefing: card))
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        briefingPopover = popover
    }

    private func machineChanged() {
        rebuildMachines()
        rebuild()
        scroll.contentView.scroll(to: .zero)
        revealCursor()
    }

    private func rebuild() {
        entries = []
        var index = 0
        for section in chooser.sections {
            if !section.title.isEmpty { entries.append(.header(section)) }
            for row in section.rows {
                entries.append(.row(row, index: index))
                index += 1
            }
        }
        summary.stringValue = chooser.summary
        hint.stringValue = chooser.hint
        summary.toolTip = chooser.summary
        empty.stringValue = chooser.emptyResult ?? ""
        empty.isHidden = chooser.emptyResult == nil
        let line = chooser.shownMachine?.consequence(for: context)
        consequence.textColor = MacTheme.Color.warning
        consequence.stringValue = line ?? ""
        consequence.isHidden = line == nil
        if let action = chooser.foldAction {
            fold.title = action.title
            fold.isHidden = false
        } else {
            fold.isHidden = true
        }
        table.reloadData()
        syncSelection()
    }

    private func syncSelection() {
        guard
            let target = entries.firstIndex(where: {
                if case .row(_, let index) = $0 { return index == chooser.cursor }
                return false
            })
        else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
    }

    private func revealCursor() {
        guard table.selectedRow >= 0 else { return }
        table.scrollRowToVisible(table.selectedRow)
    }

    private func move(by delta: Int) {
        chooser.move(by: delta)
        syncSelection()
        revealCursor()
    }

    @objc private func clicked() {
        let clicked = table.clickedRow
        guard entries.indices.contains(clicked) else { return }
        switch entries[clicked] {
        case .header(let section):
            guard chooser.toggleSection(section.id) else { return }
            rebuildKeepingScroll()
        case .row(let row, let index):
            chooser.focus(index)
            pick(row)
        }
    }

    @objc private func foldAll() {
        guard let action = chooser.foldAction, chooser.setAllCollapsed(action.collapses) else {
            return
        }
        rebuildKeepingScroll()
        revealCursor()
    }

    private func pick(_ row: ModelChooserRow) {
        let handler = onPick
        sheet.sheetParent?.endSheet(sheet)
        handler(row.pick)
    }

    /// Puts a row's model in the party and says where it went, in the line the sheet keeps for
    /// what a pick will do. A row that is not a model — the server's own choice — has nothing to
    /// put there.
    @discardableResult
    private func addToParty(_ row: ModelChooserRow) -> Bool {
        guard let onAddToParty, row.selection != nil else { return false }
        if let said = onAddToParty(row.pick) {
            consequence.stringValue = said
            consequence.textColor = MacTheme.Color.success
            consequence.isHidden = false
        }
        return true
    }

    private func partyMenu(entry index: Int) -> NSMenu? {
        guard onAddToParty != nil, entries.indices.contains(index),
            case .row(let row, let cursor) = entries[index], row.selection != nil
        else { return nil }
        chooser.focus(cursor)
        syncSelection()
        let menu = NSMenu()
        let item = NSMenuItem(
            title: Localized.text("Add to party"), action: #selector(addToPartyFromMenu(_:)),
            keyEquivalent: "p")
        item.keyEquivalentModifierMask = .command
        item.target = self
        item.tag = index
        menu.addItem(item)
        return menu
    }

    @objc private func addToPartyFromMenu(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag), case .row(let row, _) = entries[sender.tag]
        else { return }
        addToParty(row)
    }

    private func toggle(_ index: Int) {
        chooser.focus(index)
        guard chooser.setExpanded(!(chooser.focused?.isExpanded ?? false), at: index) else {
            return
        }
        rebuildKeepingScroll()
    }

    fileprivate func expandAction(_ index: Int) -> () -> Void {
        { [weak self] in self?.toggle(index) }
    }

    fileprivate func togglePinAction(_ index: Int) -> () -> Void {
        { [weak self] in self?.togglePin(at: index) }
    }

    private func togglePin(at index: Int) {
        guard entries.indices.contains(index), case .row(let row, _) = entries[index] else {
            return
        }
        chooser.focus(index)
        guard let selection = row.selection else { return }
        chooser.togglePin(selection)
        rebuildKeepingScroll()
    }
}

extension ModelChooserSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard entries.indices.contains(row) else { return 24 }
        switch entries[row] {
        case .header: return 26 * MacTheme.UIScale.factor
        case .row(let value, _): return (value.detail.isEmpty ? 26 : 40) * MacTheme.UIScale.factor
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard entries.indices.contains(row) else { return false }
        if case .header = entries[row] { return false }
        return true
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        switch entries[row] {
        case .header(let section):
            return ModelChooserHeaderView(section: section)
        case .row(let value, let index):
            return ModelChooserRowView(
                row: value, slots: chooser.policy.capabilitySlots,
                onExpand: expandAction(index), onTogglePin: togglePinAction(index))
        }
    }
}

extension ModelChooserSheet: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        chooser.search(field.stringValue)
        rebuild()
        revealCursor()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard let focused = chooser.focused else { return true }
            pick(focused)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            sheet.sheetParent?.endSheet(sheet)
            return true
        default:
            return false
        }
    }
}

/// The chooser's table, which asks the sheet for a row's context menu rather than keeping one of
/// its own: a row's menu depends on what the row is.
@MainActor
private final class ModelChooserTable: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return menuForRow?(row) ?? super.menu(for: event)
    }
}
