import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// An expert's page: who it is and New task, its bench as the machine just proved it, its guards
/// with Check now and a failing guard's hand-over, its notebook, journal and tasks, the schedules
/// that are its watches, its charter and skills, the brief a task starts with, Edit and Delete.
final class ExpertWindow: MachineWindow, @unchecked Sendable {
    let profileID: String
    let machine: String
    var expert: MachineExpert
    var journal: [ExpertJournalEntry]?
    var watchSchedules: [MachineSchedule] = []
    var proving = false
    var busy = false
    var watch: NSObjectProtocol?
    var generation = 0

    static func key(_ profileID: String, _ expertID: String) -> String { "expert·\(profileID)·\(expertID)" }

    static func present(row: ExpertRow, parent: UnsafeMutablePointer<GtkWidget>?) {
        let window =
            (MachineWindowRegistry.existing(key(row.profileID, row.expert.id)) as? ExpertWindow)
            ?? ExpertWindow(row: row)
        window.show(title: row.expert.name, parent: parent, width: 620, height: 800)
    }

    init(row: ExpertRow) {
        profileID = row.profileID
        machine = row.machine
        expert = row.expert
        super.init(key: Self.key(row.profileID, row.expert.id))
    }

    var keeper: (any MachineExperts)? { ExpertDesk.shared.keeping(profileID: profileID) }

    var row: ExpertRow { ExpertRow(profileID: profileID, machine: machine, expert: expert) }

    override func opened() {
        watch = NotificationCenter.default.addObserver(forName: ExpertDesk.didChange, object: nil, queue: nil) {
            [weak self] _ in
            Gtk.onMain { [weak self] in self?.adoptBoard() }
        }
        ExpertDesk.shared.watch(key)
        render()
        prove()
        loadJournal()
        loadWatches()
    }

    override func closed() {
        generation += 1
        ExpertDesk.shared.unwatch(key)
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
    }

    /// The shelf read the machines again; this page takes what it says about this expert, keeping
    /// the bench this page proved more recently than the shelf did.
    func adoptBoard() {
        guard isOpen, let fresh = ExpertDesk.shared.row(profileID: profileID, expertID: expert.id)?.expert else {
            return
        }
        var merged = fresh
        if let mine = expert.bench.compactMap(\.checkedAt).max(),
            mine > (fresh.bench.compactMap(\.checkedAt).max() ?? .distantPast)
        {
            merged.bench = expert.bench
        }
        guard merged != expert else { return }
        let journalMoved = merged.journal != expert.journal
        expert = merged
        render()
        if journalMoved { loadJournal() }
    }

    func prove() {
        guard let keeper, !proving else { return }
        proving = true
        render()
        let id = expert.id
        let mine = generation
        Task { [weak self] in
            let fresh = try? await keeper.machineExpert(id, prove: true)
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen, mine == self.generation else { return }
                self.proving = false
                if let fresh { self.expert = fresh }
                self.render()
            }
        }
    }

    func reload() {
        guard let keeper else { return }
        let id = expert.id
        let mine = generation
        Task { [weak self] in
            let fresh = try? await keeper.machineExpert(id, prove: false)
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen, mine == self.generation else { return }
                if let fresh {
                    self.expert = fresh
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
        let id = expert.id
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
        guard !expert.watches.isEmpty,
            let scheduling = ExpertDesk.shared.backend(profileID: profileID) as? any MachineScheduling
        else { return }
        let ids = Set(expert.watches)
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
        if let window { gtk_window_set_title(ptr(window), expert.name) }
        var groups = [headGroup()]
        if let task = expert.task { groups.append(taskGroup(task)) }
        groups += [benchGroup(), guardsGroup(), notebookGroup(), journalGroup()]
        if !expert.tasks.isEmpty { groups.append(tasksGroup()) }
        if !watchSchedules.isEmpty { groups.append(watchesGroup()) }
        groups += [charterGroup(), deleteGroup()]
        replaceGroups(groups)
    }

    private func headGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        let hero = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 14)
        gtk_box_append(ptr(hero), ExpertMarks.mark(expert, size: .large))
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        let name = Gtk.label(expert.name, css: "expert-head-name", wrap: true, selectable: false)
        gtk_label_set_xalign(op(name), 0)
        gtk_box_append(ptr(words), name)
        if !expert.purpose.isEmpty {
            let purpose = Gtk.label(expert.purpose, css: "expert-head-purpose", wrap: true, selectable: true)
            gtk_label_set_xalign(op(purpose), 0)
            gtk_box_append(ptr(words), purpose)
        }
        gtk_box_append(ptr(hero), words)
        gtk_box_append(ptr(column), hero)
        let modelWord = expert.model.map { ScheduleDetailWindow.modelWords($0, profileID: profileID) }
        let meta = ExpertReading.meta(expert, machine: machine, modelWord: modelWord).map {
            Gtk.label($0, css: "expert-meta", selectable: false)
        }
        gtk_box_append(ptr(column), Gtk.wrapRow(meta, spacing: 6))
        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let task = Gtk.button(ExpertWords.newTask, css: ["suggested-action"]) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                mainWindow?.presentExpertTask(self.row)
            }
        }
        gtk_widget_set_hexpand(task, 1)
        gtk_box_append(ptr(buttons), task)
        gtk_box_append(
            ptr(buttons),
            Gtk.button(ExpertWords.edit) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, let keeper = self.keeper else { return }
                    ExpertEditorWindow.presentEdit(row: self.row, keeper: keeper, parent: self.window)
                }
            })
        gtk_box_append(ptr(column), buttons)
        MachineRows.add(MachineRows.wrapped(column, margin: 14), to: group)
        return group
    }

    private func taskGroup(_ task: ExpertTaskRef) -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let reading = ExpertReading.taskRow(task)
        let row = MachineRows.link(reading.title, subtitle: reading.detail.text) {
            mainWindow?.openSession(withID: task.sessionID)
        }
        if let css = ExpertMarks.lineClass(reading.detail.tone) { Gtk.addClass(row, css) }
        MachineRows.prefix("●", css: ExpertMarks.toneClass(.active), on: row)
        MachineRows.add(row, to: group)
        return group
    }

    private func benchGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(ExpertWords.bench)
        let check = Gtk.button(proving ? ExpertWords.checking : Localized.text("Check"), css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.prove() }
        }
        gtk_widget_set_sensitive(check, proving ? 0 : 1)
        adw_preferences_group_set_header_suffix(ptr(group), check)
        if expert.bench.isEmpty {
            MachineRows.add(MachineRows.row(ExpertWords.noBench, subtitleCSS: "dim-label"), to: group)
        }
        for item in expert.bench {
            let line = ExpertReading.benchLine(item, machine: machine)
            let row = MachineRows.row(item.name, subtitle: line.text, subtitleCSS: ExpertMarks.lineClass(line.tone))
            adw_action_row_add_prefix(ptr(row), ExpertMarks.lamp(line.tone))
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
        let line = ExpertReading.guardsLine(expert)
        let group = MachineRows.group(ExpertWords.guards, description: ExpertReading.guardRule(expert))
        let running = expert.runningGuards || busy
        let check = Gtk.button(running ? ExpertWords.checking : ExpertWords.checkNow, css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.checkGuards(only: nil) }
        }
        gtk_widget_set_sensitive(check, running || expert.guards.isEmpty ? 0 : 1)
        adw_preferences_group_set_header_suffix(ptr(group), check)
        if expert.guards.isEmpty {
            MachineRows.add(MachineRows.row(ExpertWords.noGuards, subtitleCSS: "dim-label"), to: group)
            return group
        }
        let summary = MachineRows.row(line.text, subtitleCSS: nil)
        if line.tone != .quiet { MachineRows.prefix("●", css: ExpertMarks.toneClass(line.tone), on: summary) }
        MachineRows.add(summary, to: group)
        for item in expert.guards {
            let reading = ExpertReading.guardRow(item)
            let row = ExpertMarks.row(reading)
            MachineRows.add(row, to: group)
            guard item.isFailing else { continue }
            let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let words = Self.failureTask(item, machine: machine)
            gtk_box_append(
                ptr(buttons),
                Gtk.button(ExpertWords.handFailure(expert.name), css: ["suggested-action"]) {
                    [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        mainWindow?.presentExpertTask(self.row, text: words)
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
        ExpertMaking.failureTask(item, machine: machine)
    }

    func checkGuards(only: String?) {
        guard let keeper, !busy else { return }
        busy = true
        render()
        let id = expert.id
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
                case .success(let fresh): self.expert = fresh
                case .failure(let error): self.toast(Self.words(error))
                }
                self.render()
                Gtk.after(2_000) { [weak self] in self?.reload() }
                ExpertDesk.shared.refresh()
            }
        }
    }

    private func notebookGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(ExpertWords.notebook)
        let line = ExpertReading.notebookLine(expert)
        let path = ExpertReading.shortPath(expert.notebook.path)
        let row = MachineRows.link(line.text, subtitle: path) { [weak self] in
            guard let self, let keeper = self.keeper else { return }
            ExpertNotebookWindow.present(row: self.row, keeper: keeper, parent: self.window)
        }
        if line.tone != .quiet { MachineRows.prefix("●", css: ExpertMarks.toneClass(line.tone), on: row) }
        MachineRows.add(row, to: group)
        return group
    }

    private func journalGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(ExpertWords.journal)
        let entries = journal ?? expert.journal
        if entries.isEmpty {
            MachineRows.add(MachineRows.row(ExpertWords.noJournal, subtitleCSS: "dim-label"), to: group)
        }
        for entry in entries.prefix(12) {
            let row = ExpertMarks.row(ExpertReading.journalRow(entry))
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
        let group = MachineRows.group(ExpertWords.tasks)
        for task in expert.tasks {
            let reading = ExpertReading.taskRow(task)
            let row = MachineRows.link(reading.title, subtitle: reading.detail.text) {
                mainWindow?.openSession(withID: task.sessionID)
            }
            if let css = ExpertMarks.lineClass(reading.detail.tone) { Gtk.addClass(row, css) }
            MachineRows.add(row, to: group)
        }
        return group
    }

    private func watchesGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(ExpertWords.watches)
        let backend = ExpertDesk.shared.backend(profileID: profileID)
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
        let group = MachineRows.group(ExpertWords.charter)
        let brief = Gtk.button(ExpertWords.showBrief, css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.showBrief() }
        }
        adw_preferences_group_set_header_suffix(ptr(group), brief)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        let charter = Gtk.label(
            expert.charter.isEmpty ? Localized.text("No charter yet.") : expert.charter, css: "agent-text", wrap: true,
            selectable: true)
        gtk_label_set_xalign(op(charter), 0)
        gtk_box_append(ptr(column), charter)
        if !expert.skills.isEmpty {
            let skills = Gtk.label(ExpertWords.skills, css: "expert-shelf-heading", selectable: false)
            gtk_label_set_xalign(op(skills), 0)
            gtk_box_append(ptr(column), skills)
            gtk_box_append(ptr(column), ExpertMarks.chips(expert.skills.map { ExpertLine($0) }))
        }
        MachineRows.add(MachineRows.wrapped(column, margin: 12), to: group)
        return group
    }

    func showBrief() {
        guard let keeper else { return }
        let id = expert.id
        let name = expert.name
        Task { [weak self] in
            let preview = try? await keeper.expertBrief(id)
            Gtk.onMain { [weak self] in
                guard let self, let preview else { return }
                Dialogs.reader(
                    title: ExpertWords.briefTitle, subtitle: name + " · " + ExpertWords.tokens(preview.tokens),
                    body: preview.text, parent: self.window)
            }
        }
    }

    private func deleteGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let delete = MachineRows.row(ExpertWords.delete, subtitle: ExpertWords.deleteDetail)
        MachineRows.suffixButton(Localized.text("Delete"), css: ["destructive-action"], sensitive: !busy, on: delete) {
            [weak self] in
            self?.confirmDelete()
        }
        MachineRows.add(delete, to: group)
        return group
    }

    func confirmDelete() {
        Dialogs.confirm(
            title: ExpertWords.delete + "?", body: expert.name + "\n\n" + ExpertWords.deleteDetail,
            confirmLabel: Localized.text("Delete"), parent: window
        ) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let keeper = self.keeper else { return }
                let id = self.expert.id
                Task { [weak self] in
                    do {
                        try await keeper.deleteExpert(id)
                        Gtk.onMain { [weak self] in
                            ExpertDesk.shared.refresh()
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
