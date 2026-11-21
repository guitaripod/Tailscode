import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// One master's page: its head with New task, then the bench, guards, tasks, watches, charter and
/// skills down one column and the notebook and journal down the other — one column when the window
/// is narrow. Everything on it is the machine's answer: the bench is proved when the page opens,
/// the notebook and journal are read from the machine, and every press goes to the machine and is
/// drawn from what it answers next.
@MainActor
final class MasterPageView: NSView, NSSearchFieldDelegate {
    private let scroll = NSScrollView()
    private let page = FillingStack(topDown: true)
    private let head = MasterHeadView()
    private lazy var columns = MasterColumns(left: left, right: right, gap: MacTheme.Spacing.l + 4)
    private let left = FillingStack(topDown: false)
    private let right = FillingStack(topDown: false)
    private let bench = MasterSection(title: MasterWords.bench)
    private let guards = MasterSection(title: MasterWords.guards)
    private let tasks = MasterSection(title: MasterWords.tasks)
    private let watches = MasterSection(title: MasterWords.watches)
    private let charter = MasterSection(title: MasterWords.charter)
    private let skills = MasterSection(title: MasterWords.skills)
    private let notebook = MasterSection(title: MasterWords.notebook)
    private let journal = MasterSection(title: MasterWords.journal)
    private let guardsLine = NSTextField(wrappingLabelWithString: "")
    private let noteSearch = NSSearchField()
    private let notebookLine = NSTextField(labelWithString: "")
    private let charterText = NSTextField(wrappingLabelWithString: "")
    private var showsRetired = false
    private(set) var row: MasterRow?
    private(set) var notes: [ExpertNote] = []
    private(set) var retiredNotes: [ExpertNote] = []
    private(set) var entries: [ExpertJournalEntry] = []
    private var loadedFor: String?
    private var loadedCounts: (notes: Int, retired: Int, journal: String?)?
    private var notePopover: NSPopover?
    private var narrow = false

    var onNewTask: ((MasterRow) -> Void)?
    var onEdit: ((MasterRow) -> Void)?
    var onDelete: ((MasterRow) -> Void)?
    var onOpenChat: ((String, String) -> Void)?
    var onOpenSchedule: ((String) -> Void)?
    var onHandFailure: ((MasterRow, ExpertGuard) -> Void)?
    var onShowBrief: ((MasterRow) -> Void)?
    var onToast: ((String) -> Void)?

    /// What the page shows, for a harness.
    var sectionTitles: [String] {
        [bench, guards, tasks, watches, charter, skills, notebook, journal].filter { !$0.isHidden }.map(\.sectionTitle)
    }
    var benchLines: [String] { rowsText(bench) }
    var guardLines: [String] { rowsText(guards) }
    var noteTitles: [String] { (notebook.body.arrangedSubviews.compactMap { $0 as? MasterLineRow }).map(\.titleText) }
    var headName: String { head.nameText }
    var isTwoColumns: Bool { !narrow }
    var headButtonsUnder: Bool { head.buttonsUnder }
    var headWordsWidth: CGFloat { head.wordsWidth }
    var benchCardFill: CGColor? { bench.cardFill }
    var drawnRows: [ObjectIdentifier] {
        [ObjectIdentifier(charterText)]
            + [bench, guards, tasks, watches, skills, notebook, journal].flatMap {
                $0.body.arrangedSubviews.map(ObjectIdentifier.init)
            }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        page.spacing = MacTheme.Spacing.l + 4
        page.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.xl, left: MacTheme.Spacing.xl, bottom: MacTheme.Spacing.xl, right: MacTheme.Spacing.xl)
        left.spacing = MacTheme.Spacing.l + 2
        right.spacing = MacTheme.Spacing.l + 2
        for stack in [left, right] { stack.setHuggingPriority(.required, for: .vertical) }
        for section in [bench, guards, tasks, watches, charter, skills] { left.addArrangedSubview(section) }
        for section in [notebook, journal] { right.addArrangedSubview(section) }
        page.addArrangedSubview(head)
        page.addArrangedSubview(columns)

        head.onNewTask = { [weak self] in self?.newTask() }
        head.onEdit = { [weak self] in if let row = self?.row { self?.onEdit?(row) } }
        head.menuItems = { [weak self] in self?.headMenu() ?? [] }

        guardsLine.font = MacTheme.Ramp.font(.panelFootnote)
        guardsLine.textColor = MacTheme.Color.secondaryLabel
        guardsLine.isSelectable = false
        noteSearch.placeholderString = Localized.text("Search notes")
        noteSearch.controlSize = .small
        noteSearch.delegate = self
        noteSearch.sendsSearchStringImmediately = true
        noteSearch.widthAnchor.constraint(equalToConstant: 170).isActive = true
        notebook.setAccessories([noteSearch])
        notebookLine.font = MacTheme.Ramp.font(.panelFootnote)
        notebookLine.textColor = MacTheme.Color.secondaryLabel
        notebookLine.lineBreakMode = .byTruncatingMiddle
        notebookLine.setContentCompressionResistancePriority(MacTheme.Layout.belowWindowSize, for: .horizontal)
        charterText.font = MacTheme.Ramp.font(.cardBody)
        charterText.isSelectable = true
        charterText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        charter.setRows([masterInset(charterText, top: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m)])

        let clip = MasterFlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = page
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = MacTheme.Color.canvas
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            page.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            page.topAnchor.constraint(equalTo: clip.topAnchor),
            page.widthAnchor.constraint(equalTo: clip.widthAnchor),
            columns.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -2 * MacTheme.Spacing.xl),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Narrower than two readable columns, the sections stack in one.
    override func layout() {
        super.layout()
        let wantsNarrow = bounds.width < 760
        guard wantsNarrow != narrow else { return }
        narrow = wantsNarrow
        columns.stacked = narrow
    }

    func show(_ row: MasterRow) {
        let changedMaster = self.row?.id != row.id
        self.row = row
        if changedMaster {
            notes = []
            retiredNotes = []
            entries = []
            loadedFor = nil
            loadedCounts = nil
            showsRetired = false
            noteSearch.stringValue = ""
        }
        render()
        if changedMaster {
            scrollToTop()
            prove()
        }
        let counts = (row.master.notebook.notes, row.master.notebook.retired, row.master.journal.first?.id)
        if loadedFor != row.id || loadedCounts.map({ $0 != counts }) ?? true {
            loadedCounts = counts
            loadNotebook()
        }
    }

    /// The head under the titlebar's inset, never behind it.
    private func scrollToTop() {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
        scroll.reflectScrolledClipView(clip)
    }

    /// The machine proves the bench again, and the page draws what it found.
    func prove() {
        guard let row, let keeping = MasterDesk.shared.keeping(for: row.profileID) else { return }
        let id = row.master.id
        let profileID = row.profileID
        Task {
            guard let fresh = try? await keeping.machineExpert(id, prove: true) else { return }
            MasterDesk.shared.adopt(fresh, profileID: profileID)
        }
    }

    private func loadNotebook() {
        guard let row, let keeping = MasterDesk.shared.keeping(for: row.profileID) else { return }
        let id = row.master.id
        loadedFor = row.id
        Task { [weak self] in
            async let live = try? keeping.expertNotes(id, retired: false)
            async let gone = try? keeping.expertNotes(id, retired: true)
            async let written = try? keeping.expertJournal(id)
            let (notes, retired, journal) = await (live, gone, written)
            guard let self, self.row?.master.id == id else { return }
            self.notes = notes ?? []
            self.retiredNotes = retired ?? []
            self.entries = journal ?? self.row?.master.journal ?? []
            self.renderNotebook()
            self.renderJournal()
        }
    }

    private func render() {
        guard let row else { return }
        let master = row.master
        head.show(
            row, meta: MasterReading.meta(
                master, machine: row.machine,
                modelWord: MasterDesk.shared.modelWord(master.model, profileID: row.profileID)))
        renderBench()
        renderGuards()
        renderTasks()
        renderWatches()
        renderCharter()
        renderNotebook()
        renderJournal()
    }

    private func renderBench() {
        guard let row else { return }
        let items = row.master.bench
        let lines = items.map { MasterReading.benchLine($0, machine: row.machine) }
        guard bench.redraws(for: [row.id, items, lines]) else { return }
        bench.setAccessories([masterSmallButton(Localized.text("Check"), target: self, action: #selector(proveTapped))])
        guard !items.isEmpty else {
            bench.setRows([MasterLineRow(MasterRowReading(title: MasterWords.noBench, detail: MasterLine("")))])
            return
        }
        bench.setRows(
            zip(items, lines).map { item, line in
                let lamp = LampView(color: MasterInk.color(line.tone), filled: item.state != nil && item.state != .unknown)
                let view = MasterLineRow(MasterRowReading(title: item.name, detail: line), leading: lamp)
                view.contextMenu = { [weak self] in self?.benchMenu(item) }
                if let session = item.holder?.sessionID {
                    view.onPress = { [weak self] in self?.onOpenChat?(row.profileID, session) }
                }
                view.toolTip = [item.identifier, item.command, item.lock].compactMap { $0 }.joined(separator: "\n")
                return view
            })
    }

    private func renderGuards() {
        guard let row else { return }
        let master = row.master
        let summary = MasterReading.guardsLine(master)
        let rule = MasterReading.guardRule(master)
        let readings = master.guards.map { MasterReading.guardRow($0) }
        guard guards.redraws(for: [row.id, master.name, master.guards, master.runningGuards, summary, rule, readings])
        else { return }
        let check = masterSmallButton(
            master.runningGuards ? MasterWords.checking : MasterWords.checkNow, target: self, action: #selector(checkGuards))
        check.isEnabled = !master.runningGuards && !master.guards.isEmpty
        guards.setAccessories([check])
        guard !master.guards.isEmpty else {
            guards.setRows([MasterLineRow(MasterRowReading(title: "", detail: MasterLine(MasterWords.noGuards)), detailLines: 3)])
            return
        }
        var rows: [NSView] = []
        let header = MasterLineRow(MasterRowReading(title: summary.text, detail: MasterLine(rule)), detailLines: 3)
        rows.append(header)
        for (item, reading) in zip(master.guards, readings) {
            let lamp = LampView(
                color: MasterInk.color(item.last == nil ? .quiet : item.isFailing ? .failing : item.running == true ? .active : .good),
                filled: item.last != nil)
            let view = MasterLineRow(reading, leading: lamp)
            view.contextMenu = { [weak self] in self?.guardMenu(item) }
            view.toolTip = item.last?.output ?? item.command
            rows.append(view)
        }
        if let failing = master.failingGuards.first {
            let hand = masterLinkButton(
                MasterWords.handFailure(master.name), target: self, action: #selector(handFailure))
            hand.identifier = NSUserInterfaceItemIdentifier(failing.id)
            rows.append(masterInset(hand, top: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s))
        }
        guards.setRows(rows)
    }

    private func renderTasks() {
        guard let row else { return }
        let refs = row.master.tasks
        let readings = refs.map { MasterReading.taskRow($0) }
        tasks.isHidden = refs.isEmpty
        guard tasks.redraws(for: [row.id, refs, readings]) else { return }
        tasks.setRows(
            zip(refs, readings).map { ref, reading in
                let view = MasterLineRow(reading)
                view.onPress = { [weak self] in self?.onOpenChat?(row.profileID, ref.sessionID) }
                return view
            })
    }

    private func renderWatches() {
        guard let row else { return }
        let schedules = MachineDesk.shared.board.rows.filter {
            $0.profileID == row.profileID && row.master.watches.contains($0.schedule.id)
        }
        let readings = schedules.map {
            MasterRowReading(title: $0.title, detail: MasterLine($0.subtitle), trailing: $0.markWords)
        }
        watches.isHidden = schedules.isEmpty
        guard watches.redraws(for: [row.id, schedules.map(\.schedule.id), readings]) else { return }
        watches.setRows(
            zip(schedules, readings).map { schedule, reading in
                let view = MasterLineRow(reading)
                view.onPress = { [weak self] in self?.onOpenSchedule?(schedule.id) }
                return view
            })
    }

    /// The charter keeps one field and changes its words only when they changed, so text being
    /// selected to copy is still selected after a read that found nothing new.
    private func renderCharter() {
        guard let row else { return }
        let blank = row.master.charter.isEmpty
        let words = blank ? Localized.text("No charter yet.") : row.master.charter
        if charterText.stringValue != words { charterText.stringValue = words }
        let ink = blank ? MacTheme.Color.tertiaryLabel : MacTheme.Color.label
        if charterText.textColor != ink { charterText.textColor = ink }
        guard skills.redraws(for: [row.master.skills]) else { return }
        let flow = ChipFlow()
        flow.setChips(row.master.skills.map { MasterChip(MasterLine($0)) })
        skills.isHidden = row.master.skills.isEmpty
        skills.setRows([masterInset(flow, top: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s)])
    }

    private func renderNotebook() {
        guard let row else { return }
        let line = MasterReading.notebookLine(row.master)
        notebookLine.stringValue = line.text + " · " + MasterReading.shortPath(row.master.notebook.path)
        notebookLine.textColor = line.tone == .quiet ? MacTheme.Color.secondaryLabel : MasterInk.color(line.tone)
        let query = noteSearch.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = query.isEmpty ? notes : notes.filter {
            $0.title.lowercased().contains(query) || $0.summary.lowercased().contains(query)
        }
        let titles = Dictionary(row.master.tasks.map { ($0.sessionID, $0.title) }) { first, _ in first }
        let readings = shown.map { MasterReading.noteRow($0, taskTitles: titles) }
        let retiredReadings = retiredNotes.map { MasterReading.noteRow($0) }
        guard notebook.redraws(for: [
            row.id, shown, readings, retiredNotes, retiredReadings, showsRetired, notes.isEmpty && row.master.notebook.notes == 0,
        ]) else { return }
        var views: [NSView] = []
        notebookLine.removeFromSuperview()
        views.append(masterInset(notebookLine, top: MacTheme.Spacing.s, bottom: MacTheme.Spacing.xs))
        if notes.isEmpty, row.master.notebook.notes == 0 {
            views.append(MasterLineRow(MasterRowReading(title: "", detail: MasterLine(MasterWords.noNotes))))
        }
        for (note, reading) in zip(shown, readings) {
            let view = MasterLineRow(reading)
            view.onPress = { [weak self, weak view] in
                guard let self, let view else { return }
                self.openNote(note, from: view)
            }
            views.append(view)
        }
        if !retiredNotes.isEmpty {
            let toggle = masterLinkButton(
                (showsRetired ? "▾ " : "▸ ") + MasterWords.retired + " · \(retiredNotes.count)", target: self,
                action: #selector(toggleRetired))
            views.append(masterInset(toggle, top: MacTheme.Spacing.s, bottom: MacTheme.Spacing.s))
            if showsRetired {
                for (note, reading) in zip(retiredNotes, retiredReadings) {
                    let view = MasterLineRow(reading)
                    view.alphaValue = 0.6
                    view.onPress = { [weak self, weak view] in
                        guard let self, let view else { return }
                        self.openNote(note, from: view)
                    }
                    views.append(view)
                }
            }
        }
        notebook.setRows(views)
    }

    private func renderJournal() {
        guard let row else { return }
        let shown = Array((entries.isEmpty ? row.master.journal : entries).prefix(30))
        let readings = shown.map { MasterReading.journalRow($0) }
        guard journal.redraws(for: [row.id, shown, readings]) else { return }
        guard !shown.isEmpty else {
            journal.setRows([MasterLineRow(MasterRowReading(title: "", detail: MasterLine(MasterWords.noJournal)))])
            return
        }
        journal.setRows(
            zip(shown, readings).map { entry, reading in
                let view = MasterLineRow(reading, detailLines: 3)
                if let session = entry.sessionID {
                    view.onPress = { [weak self] in self?.onOpenChat?(row.profileID, session) }
                }
                if !entry.commits.isEmpty { view.toolTip = entry.commits.joined(separator: "\n") }
                return view
            })
    }

    private func newTask() {
        guard let row else { return }
        onNewTask?(row)
    }

    @objc private func proveTapped() { prove() }

    @objc private func checkGuards() {
        runGuards(only: nil)
    }

    private func runGuards(only guardID: String?) {
        guard let row, let keeping = MasterDesk.shared.keeping(for: row.profileID) else { return }
        let id = row.master.id
        let profileID = row.profileID
        Task { [weak self] in
            do {
                let fresh = try await keeping.runExpertGuards(id, guardID: guardID)
                MasterDesk.shared.adopt(fresh, profileID: profileID)
            } catch {
                self?.onToast?(AgentErrorText.readable(error))
            }
        }
    }

    @objc private func handFailure(_ sender: NSButton) {
        guard let row, let id = sender.identifier?.rawValue,
            let item = row.master.guards.first(where: { $0.id == id })
        else { return }
        onHandFailure?(row, item)
    }

    @objc private func toggleRetired() {
        showsRetired.toggle()
        renderNotebook()
    }

    func controlTextDidChange(_ obj: Notification) { renderNotebook() }

    private func headMenu() -> [NSMenuItem] {
        guard row != nil else { return [] }
        let brief = NSMenuItem(title: MasterWords.showBrief, action: #selector(showBrief), keyEquivalent: "")
        brief.target = self
        let check = NSMenuItem(title: MasterWords.checkNow, action: #selector(checkGuards), keyEquivalent: "")
        check.target = self
        let prove = NSMenuItem(title: Localized.text("Check the Bench"), action: #selector(proveTapped), keyEquivalent: "")
        prove.target = self
        let delete = NSMenuItem(title: MasterWords.delete + "…", action: #selector(deleteTapped), keyEquivalent: "")
        delete.target = self
        return [brief, check, prove, .separator(), delete]
    }

    @objc private func showBrief() { if let row { onShowBrief?(row) } }
    @objc private func deleteTapped() { if let row { onDelete?(row) } }

    private func benchMenu(_ item: ExpertBenchItem) -> NSMenu {
        let menu = NSMenu()
        for (label, value) in [
            (Localized.text("Copy Identifier"), item.identifier), (Localized.text("Copy Command"), item.command),
            (Localized.text("Copy Lock File"), item.lock),
        ] {
            guard let value, !value.isEmpty else { continue }
            let entry = NSMenuItem(title: label, action: #selector(copyValue(_:)), keyEquivalent: "")
            entry.representedObject = value
            entry.target = self
            menu.addItem(entry)
        }
        let check = NSMenuItem(title: Localized.text("Check the Bench"), action: #selector(proveTapped), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        return menu
    }

    private func guardMenu(_ item: ExpertGuard) -> NSMenu {
        let menu = NSMenu()
        let run = NSMenuItem(title: Localized.text("Check This Guard"), action: #selector(runOne(_:)), keyEquivalent: "")
        run.representedObject = item.id
        run.target = self
        run.isEnabled = item.running != true
        menu.addItem(run)
        if item.isFailing, let row {
            let hand = NSMenuItem(
                title: MasterWords.handFailure(row.master.name), action: #selector(handOne(_:)),
                keyEquivalent: "")
            hand.representedObject = item.id
            hand.target = self
            menu.addItem(hand)
        }
        let copy = NSMenuItem(title: Localized.text("Copy Command"), action: #selector(copyValue(_:)), keyEquivalent: "")
        copy.representedObject = item.command
        copy.target = self
        menu.addItem(copy)
        if let output = item.last?.output, !output.isEmpty {
            let copyOutput = NSMenuItem(title: Localized.text("Copy Output"), action: #selector(copyValue(_:)), keyEquivalent: "")
            copyOutput.representedObject = output
            copyOutput.target = self
            menu.addItem(copyOutput)
        }
        return menu
    }

    @objc private func runOne(_ sender: NSMenuItem) { runGuards(only: sender.representedObject as? String) }

    @objc private func handOne(_ sender: NSMenuItem) {
        guard let row, let id = sender.representedObject as? String,
            let item = row.master.guards.first(where: { $0.id == id })
        else { return }
        onHandFailure?(row, item)
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        onToast?(Localized.text("Copied"))
    }

    /// A note's whole body, read from the machine, in a popover beside its row.
    private func openNote(_ note: ExpertNote, from view: NSView) {
        guard let row else { return }
        notePopover?.close()
        let controller = MasterNoteViewController(note: note, row: row)
        controller.onOpenTask = { [weak self] session in
            self?.notePopover?.close()
            self?.onOpenChat?(row.profileID, session)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        notePopover = popover
        guard note.body == nil, let keeping = MasterDesk.shared.keeping(for: row.profileID) else { return }
        Task { [weak controller] in
            guard let full = try? await keeping.expertNote(row.master.id, note: note.id) else { return }
            controller?.show(full)
        }
    }

    private func rowsText(_ section: MasterSection) -> [String] {
        section.body.arrangedSubviews.compactMap { $0 as? MasterLineRow }.map { "\($0.titleText): \($0.detailText)" }
    }
}

/// The page's head: the mark, the name, what the master is for, where and with what it works, and
/// its verbs — New task first, because that is what the page is for.
@MainActor
final class MasterHeadView: NSView {
    private let mark = MasterMarkView(glyph: "", hue: .blue, side: 58)
    private let name = NSTextField(labelWithString: "")
    private let beta = BetaBadge(feature: .masters, reportLines: { MasterDesk.shared.betaReportLines })
    private let purpose = NSTextField(wrappingLabelWithString: "")
    private let meta = ChipFlow()
    private let newTask = NSButton()
    private let edit = NSButton()
    private let more = NSPopUpButton(frame: .zero, pullsDown: true)
    private let words = NSStackView()
    private let buttons = NSStackView()
    private var beside: [NSLayoutConstraint] = []
    private var under: [NSLayoutConstraint] = []
    private var drawnChips: [AnyHashable]?
    var onNewTask: (() -> Void)?
    var onEdit: (() -> Void)?
    var menuItems: (() -> [NSMenuItem])?

    var nameText: String { name.stringValue }
    var buttonsUnder: Bool { under.first?.isActive == true }
    var wordsWidth: CGFloat { words.frame.width }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        name.font = MacTheme.Ramp.font(.headline)
        name.textColor = MacTheme.Color.label
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        purpose.font = MacTheme.Ramp.font(.panelDetail)
        purpose.textColor = MacTheme.Color.secondaryLabel
        purpose.isSelectable = false
        purpose.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newTask.title = MasterWords.newTask
        newTask.bezelStyle = .push
        newTask.keyEquivalent = "\r"
        newTask.keyEquivalentModifierMask = [.command]
        newTask.bezelColor = MacTheme.Color.accent
        newTask.target = self
        newTask.action = #selector(newTaskTapped)
        newTask.toolTip = "⌘↩"
        edit.title = MasterWords.edit + "…"
        edit.bezelStyle = .push
        edit.target = self
        edit.action = #selector(editTapped)
        more.bezelStyle = .push
        more.addItem(withTitle: "")
        more.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: Localized.text("More"))
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        more.menu?.delegate = self
        for view in [newTask, edit, more] { buttons.addArrangedSubview(view) }
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s
        buttons.setHuggingPriority(.required, for: .horizontal)
        masterHug(buttons)
        let nameRow = NSView()
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [name, beta] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            nameRow.addSubview(view)
        }
        name.setContentHuggingPriority(.required, for: .horizontal)
        beta.setContentHuggingPriority(.required, for: .horizontal)
        beta.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: nameRow.leadingAnchor),
            name.topAnchor.constraint(equalTo: nameRow.topAnchor),
            name.bottomAnchor.constraint(equalTo: nameRow.bottomAnchor),
            beta.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: MacTheme.Spacing.s),
            beta.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            beta.trailingAnchor.constraint(lessThanOrEqualTo: nameRow.trailingAnchor),
        ])
        for view in [nameRow, purpose, meta] as [NSView] { words.addArrangedSubview(view) }
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 4
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        masterHug(words)
        placeParts()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The mark and the words lead; the verbs sit at the trailing end beside them, or — when the
    /// head is too narrow to leave the words a readable column — on a line of their own under the
    /// words. Placed by constraints, two sets, switched by width.
    private func placeParts() {
        for view in [mark, words, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        func low(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
            constraint.priority = .init(1)
            return constraint
        }
        let gap = MacTheme.Spacing.l
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor),
            mark.topAnchor.constraint(equalTo: topAnchor),
            words.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: gap),
            words.topAnchor.constraint(equalTo: topAnchor),
            meta.widthAnchor.constraint(equalTo: words.widthAnchor),
            purpose.widthAnchor.constraint(lessThanOrEqualTo: words.widthAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: mark.bottomAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: words.bottomAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: buttons.bottomAnchor),
            low(bottomAnchor.constraint(equalTo: mark.bottomAnchor)),
            low(bottomAnchor.constraint(equalTo: words.bottomAnchor)),
            low(bottomAnchor.constraint(equalTo: buttons.bottomAnchor)),
        ])
        beside = [
            buttons.topAnchor.constraint(equalTo: topAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            words.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -gap),
        ]
        under = [
            buttons.leadingAnchor.constraint(equalTo: words.leadingAnchor),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            buttons.topAnchor.constraint(equalTo: words.bottomAnchor, constant: MacTheme.Spacing.m),
            words.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(beside)
    }

    /// Narrower than the mark, a readable column of words and the three verbs side by side, the
    /// verbs go under the words.
    override func layout() {
        super.layout()
        let wantsUnder = bounds.width < 520
        guard wantsUnder != buttonsUnder else { return }
        NSLayoutConstraint.deactivate(wantsUnder ? beside : under)
        NSLayoutConstraint.activate(wantsUnder ? under : beside)
    }

    func show(_ row: MasterRow, meta parts: [String]) {
        mark.show(row)
        if name.stringValue != row.master.name { name.stringValue = row.master.name }
        if purpose.stringValue != row.master.purpose { purpose.stringValue = row.master.purpose }
        purpose.isHidden = row.master.purpose.isEmpty
        let state = row.state()
        let key: [AnyHashable] = [parts, state]
        guard key != drawnChips else { return }
        drawnChips = key
        var chips = parts.map { MasterChip(MasterLine($0)) }
        if state.tone != .quiet { chips.append(MasterChip(state, lamp: true)) }
        meta.setChips(chips)
    }

    @objc private func newTaskTapped() { onNewTask?() }
    @objc private func editTapped() { onEdit?() }
}

extension MasterHeadView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        for item in menuItems?() ?? [] { menu.addItem(item) }
    }
}

/// One note, whole: its title and line, its body, when it was written or confirmed, and the task
/// it came from, one press away.
@MainActor
final class MasterNoteViewController: NSViewController {
    private let note: ExpertNote
    private let row: MasterRow
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let body = NSTextView()
    private let facts = NSTextField(wrappingLabelWithString: "")
    private let openTask = NSButton()
    var onOpenTask: ((String) -> Void)?

    init(note: ExpertNote, row: MasterRow) {
        self.note = note
        self.row = row
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        titleLabel.font = MacTheme.Ramp.font(.cardTitle)
        summary.font = MacTheme.Ramp.font(.panelDetail)
        summary.textColor = MacTheme.Color.secondaryLabel
        facts.font = MacTheme.Ramp.font(.panelFootnote)
        facts.textColor = MacTheme.Color.tertiaryLabel
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.font = MacTheme.Ramp.font(.cardBody)
        body.textColor = MacTheme.Color.label
        body.textContainerInset = NSSize(width: 0, height: 4)
        let bodyScroll = NSScrollView()
        bodyScroll.documentView = body
        bodyScroll.hasVerticalScroller = true
        bodyScroll.drawsBackground = false
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        body.autoresizingMask = [.width]
        body.isVerticallyResizable = true
        body.textContainer?.widthTracksTextView = true
        openTask.title = Localized.text("Open the task it came from")
        openTask.bezelStyle = .push
        openTask.controlSize = .small
        openTask.target = self
        openTask.action = #selector(openTaskTapped)
        let column = FillingStack(topDown: false)
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [titleLabel, summary, bodyScroll, facts, openTask] as [NSView] { column.addArrangedSubview(view) }
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalToConstant: 420),
            bodyScroll.heightAnchor.constraint(equalToConstant: 200),
        ])
        view = column
        show(note)
    }

    func show(_ note: ExpertNote) {
        titleLabel.stringValue = note.title
        summary.stringValue = note.summary
        summary.isHidden = note.summary.isEmpty
        body.string = note.body ?? Localized.text("Reading…")
        var parts: [String] = [note.id]
        if let touched = note.lastTouched { parts.append(MasterReading.day(touched)) }
        if let retired = note.retired {
            parts.append(Localized.text("Retired: %@", retired.reason ?? ""))
        }
        facts.stringValue = parts.joined(separator: " · ")
        openTask.isHidden = note.sourceSession == nil
    }

    @objc private func openTaskTapped() {
        if let session = note.sourceSession { onOpenTask?(session) }
    }
}

final class MasterFlippedClip: NSClipView {
    nonisolated override var isFlipped: Bool { true }
}

/// Two columns of sections side by side, each as tall as what it holds and the pair as tall as the
/// taller one — or, stacked, one above the other. Placed by constraints of its own rather than a
/// stack view, which stretched the shorter column to the taller one's height.
@MainActor
final class MasterColumns: NSView {
    private let left: NSView
    private let right: NSView
    private var wide: [NSLayoutConstraint] = []
    private var tall: [NSLayoutConstraint] = []

    var stacked = false {
        didSet {
            guard stacked != oldValue else { return }
            NSLayoutConstraint.deactivate(stacked ? wide : tall)
            NSLayoutConstraint.activate(stacked ? tall : wide)
        }
    }

    init(left: NSView, right: NSView, gap: CGFloat) {
        self.left = left
        self.right = right
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        addSubview(left)
        addSubview(right)
        func low(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
            constraint.priority = .init(1)
            return constraint
        }
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: topAnchor),
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        wide = [
            right.topAnchor.constraint(equalTo: topAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: gap),
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: left.bottomAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: right.bottomAnchor),
            low(bottomAnchor.constraint(equalTo: left.bottomAnchor)),
            low(bottomAnchor.constraint(equalTo: right.bottomAnchor)),
        ]
        tall = [
            left.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.leadingAnchor.constraint(equalTo: leadingAnchor),
            right.topAnchor.constraint(equalTo: left.bottomAnchor, constant: gap),
            bottomAnchor.constraint(equalTo: right.bottomAnchor),
        ]
        NSLayoutConstraint.activate(wide)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
