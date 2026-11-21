import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// A master's page: who it is and New task, its bench as the machine just proved it, its guards
/// with Check now and a failing guard's hand-over, its notebook, journal and tasks, the schedules
/// that are its watches, its charter and skills, the brief a task starts with, Edit and Delete.
final class MasterWindow: MachineWindow, @unchecked Sendable {
    let profileID: String
    let machine: String
    var master: MachineExpert
    var journal: [ExpertJournalEntry]?
    var watchSchedules: [MachineSchedule] = []
    var proving = false
    var busy = false
    var watch: NSObjectProtocol?
    var generation = 0

    static func key(_ profileID: String, _ expertID: String) -> String { "master·\(profileID)·\(expertID)" }

    static func present(row: MasterRow, parent: UnsafeMutablePointer<GtkWidget>?) {
        let window =
            (MachineWindowRegistry.existing(key(row.profileID, row.master.id)) as? MasterWindow)
            ?? MasterWindow(row: row)
        window.show(title: row.master.name, parent: parent, width: 620, height: 800)
    }

    init(row: MasterRow) {
        profileID = row.profileID
        machine = row.machine
        master = row.master
        super.init(key: Self.key(row.profileID, row.master.id))
    }

    var keeper: (any MachineExperts)? { MasterDesk.shared.keeping(profileID: profileID) }

    var row: MasterRow { MasterRow(profileID: profileID, machine: machine, master: master) }

    override func opened() {
        watch = NotificationCenter.default.addObserver(forName: MasterDesk.didChange, object: nil, queue: nil) {
            [weak self] _ in
            Gtk.onMain { [weak self] in self?.adoptBoard() }
        }
        MasterDesk.shared.watch(key)
        render()
        prove()
        loadJournal()
        loadWatches()
    }

    override func closed() {
        generation += 1
        MasterDesk.shared.unwatch(key)
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
    }

    /// The shelf read the machines again; this page takes what it says about this master, keeping
    /// the bench this page proved more recently than the shelf did.
    func adoptBoard() {
        guard isOpen, let fresh = MasterDesk.shared.row(profileID: profileID, expertID: master.id)?.master else {
            return
        }
        var merged = fresh
        if let mine = master.bench.compactMap(\.checkedAt).max(),
            mine > (fresh.bench.compactMap(\.checkedAt).max() ?? .distantPast)
        {
            merged.bench = master.bench
        }
        guard merged != master else { return }
        let journalMoved = merged.journal != master.journal
        master = merged
        render()
        if journalMoved { loadJournal() }
    }

    func prove() {
        guard let keeper, !proving else { return }
        proving = true
        render()
        let id = master.id
        let mine = generation
        Task { [weak self] in
            let fresh = try? await keeper.machineExpert(id, prove: true)
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen, mine == self.generation else { return }
                self.proving = false
                if let fresh { self.master = fresh }
                self.render()
            }
        }
    }

    func reload() {
        guard let keeper else { return }
        let id = master.id
        let mine = generation
        Task { [weak self] in
            let fresh = try? await keeper.machineExpert(id, prove: false)
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen, mine == self.generation else { return }
                if let fresh {
                    self.master = fresh
                    self.render()
                }
                if fresh?.runningGuards == true {
                    Gtk.after(3_000) { [weak self] in
                        guard let self, self.isOpen, mine == self.generation else { return }
                        self.reload()
                    }
                }
            }
        }
    }

    func loadJournal() {
        guard let keeper else { return }
        let id = master.id
        Task { [weak self] in
            let entries = try? await keeper.expertJournal(id)
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                self.journal = entries
                self.render()
            }
        }
    }

    func loadWatches() {
        guard !master.watches.isEmpty,
            let scheduling = MasterDesk.shared.backend(profileID: profileID) as? any MachineScheduling
        else { return }
        let ids = Set(master.watches)
        Task { [weak self] in
            let schedules = (try? await scheduling.machineSchedules()) ?? []
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                self.watchSchedules = schedules.filter { ids.contains($0.id) }
                self.render()
            }
        }
    }

    func render() {
        if let window { gtk_window_set_title(ptr(window), master.name) }
        var groups = [headGroup()]
        if let task = master.task { groups.append(taskGroup(task)) }
        groups += [benchGroup(), guardsGroup(), notebookGroup(), journalGroup()]
        if !master.tasks.isEmpty { groups.append(tasksGroup()) }
        if !watchSchedules.isEmpty { groups.append(watchesGroup()) }
        groups += [charterGroup(), deleteGroup()]
        replaceGroups(groups)
    }

    private func headGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        let hero = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        gtk_box_append(ptr(hero), MasterMarks.mark(master, size: .large))
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        let name = Gtk.label(master.name, css: "master-head-name", wrap: true, selectable: false)
        gtk_label_set_xalign(op(name), 0)
        gtk_box_append(ptr(words), name)
        if !master.purpose.isEmpty {
            let purpose = Gtk.label(master.purpose, css: "master-head-purpose", wrap: true, selectable: true)
            gtk_label_set_xalign(op(purpose), 0)
            gtk_box_append(ptr(words), purpose)
        }
        gtk_box_append(ptr(hero), words)
        gtk_box_append(ptr(column), hero)
        let modelWord = master.model.map { ScheduleDetailWindow.modelWords($0, profileID: profileID) }
        let meta = MasterReading.meta(master, machine: machine, modelWord: modelWord).map {
            Gtk.label($0, css: "master-meta", selectable: false)
        }
        gtk_box_append(ptr(column), Gtk.wrapRow(meta, spacing: 6))
        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let task = Gtk.button(MasterWords.newTask, css: ["suggested-action"]) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                mainWindow?.presentMasterTask(self.row)
            }
        }
        gtk_widget_set_hexpand(task, 1)
        gtk_box_append(ptr(buttons), task)
        gtk_box_append(
            ptr(buttons),
            Gtk.button(MasterWords.edit) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, let keeper = self.keeper else { return }
                    MasterEditorWindow.presentEdit(row: self.row, keeper: keeper, parent: self.window)
                }
            })
        gtk_box_append(ptr(column), buttons)
        MachineRows.add(MachineRows.wrapped(column, margin: 14), to: group)
        return group
    }

    private func taskGroup(_ task: ExpertTaskRef) -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let reading = MasterReading.taskRow(task)
        let row = MachineRows.link(reading.title, subtitle: reading.detail.text) {
            mainWindow?.openSession(withID: task.sessionID)
        }
        if let css = MasterMarks.lineClass(reading.detail.tone) { Gtk.addClass(row, css) }
        MachineRows.prefix("●", css: MasterMarks.toneClass(.active), on: row)
        MachineRows.add(row, to: group)
        return group
    }

    private func benchGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(MasterWords.bench)
        let check = Gtk.button(proving ? MasterWords.checking : Localized.text("Check"), css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.prove() }
        }
        gtk_widget_set_sensitive(check, proving ? 0 : 1)
        adw_preferences_group_set_header_suffix(ptr(group), check)
        if master.bench.isEmpty {
            MachineRows.add(MachineRows.row(MasterWords.noBench, subtitleCSS: "dim-label"), to: group)
        }
        for item in master.bench {
            let line = MasterReading.benchLine(item, machine: machine)
            let row = MachineRows.row(item.name, subtitle: line.text, subtitleCSS: MasterMarks.lineClass(line.tone))
            adw_action_row_add_prefix(ptr(row), MasterMarks.lamp(line.tone))
            if item.state == .held, let sessionID = item.holder?.sessionID {
                MachineRows.suffixButton(Localized.text("Open"), on: row) {
                    mainWindow?.openSession(withID: sessionID)
                }
            }
            MachineRows.add(row, to: group)
        }
        return group
    }

    private func guardsGroup() -> UnsafeMutablePointer<GtkWidget> {
        let line = MasterReading.guardsLine(master)
        let group = MachineRows.group(MasterWords.guards, description: MasterReading.guardRule(master))
        let running = master.runningGuards || busy
        let check = Gtk.button(running ? MasterWords.checking : MasterWords.checkNow, css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.checkGuards(only: nil) }
        }
        gtk_widget_set_sensitive(check, running || master.guards.isEmpty ? 0 : 1)
        adw_preferences_group_set_header_suffix(ptr(group), check)
        if master.guards.isEmpty {
            MachineRows.add(MachineRows.row(MasterWords.noGuards, subtitleCSS: "dim-label"), to: group)
            return group
        }
        let summary = MachineRows.row(line.text, subtitleCSS: nil)
        if line.tone != .quiet { MachineRows.prefix("●", css: MasterMarks.toneClass(line.tone), on: summary) }
        MachineRows.add(summary, to: group)
        for item in master.guards {
            let reading = MasterReading.guardRow(item)
            let row = MasterMarks.row(reading)
            MachineRows.add(row, to: group)
            guard item.isFailing else { continue }
            let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let words = Self.failureTask(item, machine: machine)
            gtk_box_append(
                ptr(buttons),
                Gtk.button(MasterWords.handFailure(master.name), css: ["suggested-action"]) {
                    [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        mainWindow?.presentMasterTask(self.row, text: words)
                    }
                })
            if let output = item.last?.output, !output.isEmpty {
                let title = item.name
                gtk_box_append(
                    ptr(buttons),
                    Gtk.button(Localized.text("Output")) { [weak self] in
                        Gtk.onMain { [weak self] in
                            Dialogs.reader(title: title, body: output, mono: true, parent: self?.window)
                        }
                    })
            }
            MachineRows.add(MachineRows.wrapped(buttons, margin: 8), to: group)
        }
        return group
    }

    /// The first words of a task that starts from a failing guard: which guard, its command and
    /// the output it ended with.
    static func failureTask(_ item: ExpertGuard, machine: String) -> String {
        MasterMaking.failureTask(item, machine: machine)
    }

    func checkGuards(only: String?) {
        guard let keeper, !busy else { return }
        busy = true
        render()
        let id = master.id
        Task { [weak self] in
            let outcome: Result<MachineExpert, Error>
            do {
                outcome = .success(try await keeper.runExpertGuards(id, guardID: only))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let fresh): self.master = fresh
                case .failure(let error): self.toast(Self.words(error))
                }
                self.render()
                Gtk.after(2_000) { [weak self] in self?.reload() }
                MasterDesk.shared.refresh()
            }
        }
    }

    private func notebookGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(MasterWords.notebook)
        let line = MasterReading.notebookLine(master)
        let path = MasterReading.shortPath(master.notebook.path)
        let row = MachineRows.link(line.text, subtitle: path) { [weak self] in
            guard let self, let keeper = self.keeper else { return }
            MasterNotebookWindow.present(row: self.row, keeper: keeper, parent: self.window)
        }
        if line.tone != .quiet { MachineRows.prefix("●", css: MasterMarks.toneClass(line.tone), on: row) }
        MachineRows.add(row, to: group)
        return group
    }

    private func journalGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(MasterWords.journal)
        let entries = journal ?? master.journal
        if entries.isEmpty {
            MachineRows.add(MachineRows.row(MasterWords.noJournal, subtitleCSS: "dim-label"), to: group)
        }
        for entry in entries.prefix(12) {
            let row = MasterMarks.row(MasterReading.journalRow(entry))
            if let sessionID = entry.sessionID {
                gtk_list_box_row_set_activatable(ptr(row), 1)
                Gtk.connect(UnsafeMutableRawPointer(row), "activated") {
                    Gtk.onMain { mainWindow?.openSession(withID: sessionID) }
                }
            }
            MachineRows.add(row, to: group)
        }
        return group
    }

    private func tasksGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(MasterWords.tasks)
        for task in master.tasks {
            let reading = MasterReading.taskRow(task)
            let row = MachineRows.link(reading.title, subtitle: reading.detail.text) {
                mainWindow?.openSession(withID: task.sessionID)
            }
            if let css = MasterMarks.lineClass(reading.detail.tone) { Gtk.addClass(row, css) }
            MachineRows.add(row, to: group)
        }
        return group
    }

    private func watchesGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(MasterWords.watches)
        let backend = MasterDesk.shared.backend(profileID: profileID)
        for schedule in watchSchedules {
            let when = ScheduleWords.when(schedule.rule)
            let row = MachineRows.link(schedule.title, subtitle: when) { [weak self] in
                guard let self, let backend else { return }
                ScheduleDetailWindow.present(
                    profileID: self.profileID, machine: self.machine, backend: backend, schedule: schedule,
                    parent: self.window)
            }
            MachineRows.prefix("◷", css: "accent", on: row)
            MachineRows.add(row, to: group)
        }
        return group
    }

    private func charterGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(MasterWords.charter)
        let brief = Gtk.button(MasterWords.showBrief, css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.showBrief() }
        }
        adw_preferences_group_set_header_suffix(ptr(group), brief)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        let charter = Gtk.label(
            master.charter.isEmpty ? Localized.text("No charter yet.") : master.charter, css: "agent-text", wrap: true,
            selectable: true)
        gtk_label_set_xalign(op(charter), 0)
        gtk_box_append(ptr(column), charter)
        if !master.skills.isEmpty {
            let skills = Gtk.label(MasterWords.skills, css: "master-shelf-heading", selectable: false)
            gtk_label_set_xalign(op(skills), 0)
            gtk_box_append(ptr(column), skills)
            gtk_box_append(ptr(column), MasterMarks.chips(master.skills.map { MasterLine($0) }))
        }
        MachineRows.add(MachineRows.wrapped(column, margin: 12), to: group)
        return group
    }

    func showBrief() {
        guard let keeper else { return }
        let id = master.id
        let name = master.name
        Task { [weak self] in
            let preview = try? await keeper.expertBrief(id)
            Gtk.onMain { [weak self] in
                guard let self, let preview else { return }
                Dialogs.reader(
                    title: MasterWords.briefTitle, subtitle: name + " · " + MasterWords.tokens(preview.tokens),
                    body: preview.text, parent: self.window)
            }
        }
    }

    private func deleteGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let delete = MachineRows.row(MasterWords.delete, subtitle: MasterWords.deleteDetail)
        MachineRows.suffixButton(Localized.text("Delete"), css: ["destructive-action"], sensitive: !busy, on: delete) {
            [weak self] in
            self?.confirmDelete()
        }
        MachineRows.add(delete, to: group)
        return group
    }

    func confirmDelete() {
        Dialogs.confirm(
            title: MasterWords.delete + "?", body: master.name + "\n\n" + MasterWords.deleteDetail,
            confirmLabel: Localized.text("Delete"), parent: window
        ) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let keeper = self.keeper else { return }
                let id = self.master.id
                Task { [weak self] in
                    do {
                        try await keeper.deleteExpert(id)
                        Gtk.onMain { [weak self] in
                            MasterDesk.shared.refresh()
                            self?.close()
                        }
                    } catch {
                        Gtk.onMain { [weak self] in self?.toast(Self.words(error)) }
                    }
                }
            }
        }
    }
}

/// The end of a long output, cut on a line, so a task's first message carries what matters.
enum CommandTail {
    static func tail(_ text: String, lines: Int = 30) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
