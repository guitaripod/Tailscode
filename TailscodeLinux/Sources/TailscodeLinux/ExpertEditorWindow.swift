import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Making or changing an expert: who it is, where it works and with what model, its charter and
/// skills, its notebook (its own or an adopted folder), its bench and guards and when the guards
/// run. A draft from a chat or a skill arrives as a review — its first notes ticked unless they
/// held only that day — and nothing is saved until Create.
final class ExpertEditorWindow: MachineWindow, @unchecked Sendable {
    enum Mode {
        case new
        case draft(sessionID: String)
        case edit(expertID: String)
    }

    let profileID: String
    let machine: String
    let keeper: any MachineExperts
    let mode: Mode
    var drafting = false
    var draftFailure: String?
    var saving = false
    /// The machine's skills: nil while they are read, and a failure said as one rather than as a
    /// machine with no skills.
    var skills: [ExpertSkill]?
    var skillsFailure: String?

    var name = ""
    var glyph = ""
    var hue = ExpertHue.blue
    var purpose = ""
    var directory = ""
    var model = ""
    var effort = ""
    var charter = ""
    var chosenSkills: [String] = []
    var adopts = false
    var notebookPath = ""
    var bench: [ExpertBenchItem] = []
    var guards: [ExpertGuard] = []
    var guardRule: ScheduleRule? = ScheduleRule(kind: .daily, hour: 3, minute: 0)
    var notes: [ExpertDraftNote] = []
    var ticks: Set<String> = []

    static func key(_ profileID: String, _ mode: Mode) -> String {
        switch mode {
        case .new: return "expert-new·\(profileID)"
        case .draft(let session): return "expert-draft·\(profileID)·\(session)"
        case .edit(let id): return "expert-edit·\(profileID)·\(id)"
        }
    }

    static func presentNew(
        profileID: String, machine: String, keeper: any MachineExperts, parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        let window =
            (MachineWindowRegistry.existing(key(profileID, .new)) as? ExpertEditorWindow)
            ?? ExpertEditorWindow(profileID: profileID, machine: machine, keeper: keeper, mode: .new)
        window.show(title: ExpertWords.newExpert, parent: parent, width: 620, height: 820)
    }

    static func presentDraft(
        profileID: String, machine: String, keeper: any MachineExperts, sessionID: String,
        parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        let mode = Mode.draft(sessionID: sessionID)
        let window =
            (MachineWindowRegistry.existing(key(profileID, mode)) as? ExpertEditorWindow)
            ?? ExpertEditorWindow(profileID: profileID, machine: machine, keeper: keeper, mode: mode)
        window.show(title: ExpertWords.newExpert, parent: parent, width: 620, height: 820)
    }

    static func presentEdit(row: ExpertRow, keeper: any MachineExperts, parent: UnsafeMutablePointer<GtkWidget>?) {
        let mode = Mode.edit(expertID: row.expert.id)
        let window =
            (MachineWindowRegistry.existing(key(row.profileID, mode)) as? ExpertEditorWindow)
            ?? {
                let made = ExpertEditorWindow(profileID: row.profileID, machine: row.machine, keeper: keeper, mode: mode)
                made.adopt(row.expert)
                return made
            }()
        window.show(title: ExpertWords.edit + " · " + row.expert.name, parent: parent, width: 620, height: 820)
    }

    init(profileID: String, machine: String, keeper: any MachineExperts, mode: Mode) {
        self.profileID = profileID
        self.machine = machine
        self.keeper = keeper
        self.mode = mode
        super.init(key: Self.key(profileID, mode))
    }

    var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    func adopt(_ expert: MachineExpert) {
        name = expert.name
        glyph = expert.glyph
        hue = ExpertHue(expert.hue)
        purpose = expert.purpose
        directory = expert.directory ?? ""
        model = expert.model ?? ""
        effort = expert.effort ?? ""
        charter = expert.charter
        chosenSkills = expert.skills
        adopts = expert.notebookPath != nil
        notebookPath = expert.notebookPath ?? ""
        bench = expert.bench.map(\.described)
        guards = expert.guards.map(\.described)
        guardRule = expert.guardRule
    }

    func adopt(_ draft: ExpertDraft) {
        name = draft.name
        glyph = draft.glyph ?? ExpertMaking.glyph(for: draft.name)
        if let hue = draft.hue { self.hue = ExpertHue(hue) }
        purpose = draft.purpose ?? ""
        directory = draft.directory ?? directory
        model = draft.model ?? model
        effort = draft.effort ?? effort
        charter = draft.charter ?? ""
        chosenSkills = draft.skills ?? []
        if let path = draft.notebookPath {
            adopts = true
            notebookPath = path
        }
        bench = draft.bench ?? bench
        guards = draft.guards ?? guards
        notes = draft.notes ?? []
        ticks = ExpertMaking.defaultTicks(draft)
    }

    override func opened() {
        render()
        let keeper = self.keeper
        Task { [weak self] in
            let read: Result<[ExpertSkill], Error>
            do {
                read = .success(try await keeper.expertSkills())
            } catch {
                read = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                switch read {
                case .success(let skills): self.skills = skills
                case .failure(let error): self.skillsFailure = Self.words(error)
                }
                self.render()
            }
        }
        if case .draft(let sessionID) = mode { draft(session: sessionID, skill: nil) }
    }

    func draft(session: String?, skill: String?) {
        guard !drafting else { return }
        drafting = true
        draftFailure = nil
        render()
        let keeper = self.keeper
        Task { [weak self] in
            let outcome: Result<ExpertDraft, Error>
            do {
                outcome = .success(try await keeper.draftExpert(session: session, skill: skill))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                self.drafting = false
                switch outcome {
                case .success(let draft): self.adopt(draft)
                case .failure(let error): self.draftFailure = Self.words(error)
                }
                self.render()
            }
        }
    }

    func render() {
        var groups: [UnsafeMutablePointer<GtkWidget>] = []
        if drafting {
            let group = MachineRows.group(nil)
            let row = MachineRows.row(
                ExpertWords.drafting,
                subtitle: Localized.text("A fork of the conversation, never saved, drafts it. This takes a minute."))
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(op(spinner))
            adw_action_row_add_prefix(ptr(row), spinner)
            MachineRows.add(row, to: group)
            groups.append(group)
        }
        if let draftFailure {
            let group = MachineRows.group(nil)
            MachineRows.add(MachineRows.row(ExpertWords.draftFailed, subtitle: draftFailure, subtitleCSS: "fact-bad"), to: group)
            groups.append(group)
        }
        if case .new = mode, let skills, !skills.isEmpty { groups.append(skillDraftGroup(skills)) }
        groups += [identityGroup(), placeGroup(), charterGroup(), skillsGroup(), notebookGroup()]
        if !notes.isEmpty { groups.append(notesGroup()) }
        groups += [benchGroup(), guardsGroup(), saveGroup()]
        replaceGroups(groups)
    }

    // MARK: Groups

    private func skillDraftGroup(_ skills: [ExpertSkill]) -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(
            ExpertWords.makeFromSkill, description: Localized.text("Draft the expert from a skill on %@, or fill it in below.", machine))
        for skill in skills {
            let row = MachineRows.row(skill.name, subtitle: skill.description)
            let name = skill.name
            MachineRows.suffixButton(Localized.text("Draft"), sensitive: !drafting, on: row) { [weak self] in
                self?.draft(session: nil, skill: name)
            }
            MachineRows.add(row, to: group)
        }
        return group
    }

    private func identityGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let marks = ExpertHue.allCases.map { hue -> UnsafeMutablePointer<GtkWidget> in
            let button = gtk_button_new()!
            Gtk.addClass(button, "flat")
            Gtk.addClass(button, "circular")
            if hue == self.hue { Gtk.addClass(button, "expert-hue-picked") }
            gtk_button_set_child(
                ptr(button), ExpertMarks.mark(glyph.isEmpty ? ExpertMaking.glyph(for: name) : glyph, hue: hue, size: .row))
            tailscode_set_accessible_label(button, hue.name)
            gtk_widget_set_tooltip_text(button, hue.name)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.hue = hue
                    self?.render()
                }
            }
            return button
        }
        MachineRows.add(MachineRows.wrapped(Gtk.wrapRow(marks, spacing: 4), margin: 8), to: group)
        MachineRows.add(entry(ExpertWords.name, value: name) { [weak self] in self?.name = $0 }, to: group)
        MachineRows.add(
            entry(Localized.text("Glyph, two letters"), value: glyph) { [weak self] in self?.glyph = String($0.prefix(2)) },
            to: group)
        MachineRows.add(entry(ExpertWords.purpose, value: purpose) { [weak self] in self?.purpose = $0 }, to: group)
        return group
    }

    private func placeGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(Localized.text("Where it works"), description: machine)
        MachineRows.add(entry(ExpertWords.folder, value: directory) { [weak self] in self?.directory = $0 }, to: group)
        let catalog = ModelCatalogStore.cached(profileID).filter { $0.agentName == nil }
        let models = [""] + catalog.map(\.id)
        let names = [Localized.text("The machine's default")] + catalog.map { ModelBadge.word(for: $0.selection, in: catalog) }
        var chosen = models.firstIndex(of: model) ?? 0
        var modelOptions = names
        if chosen == 0, !model.isEmpty {
            modelOptions.append(model)
            chosen = modelOptions.count - 1
        }
        let allModels = models + (model.isEmpty || models.contains(model) ? [] : [model])
        MachineRows.add(
            SettingsRows.comboRow(title: ExpertWords.model, subtitle: nil, options: modelOptions, selected: chosen) {
                [weak self] index in
                Gtk.onMain { [weak self] in self?.model = index < allModels.count ? allModels[index] : "" }
            }, to: group)
        let levels = ["", "low", "medium", "high", "xhigh", "max"]
        let levelNames = [Localized.text("The machine's default")] + levels.dropFirst()
        MachineRows.add(
            SettingsRows.comboRow(
                title: Localized.text("Effort"), subtitle: nil, options: Array(levelNames),
                selected: levels.firstIndex(of: effort) ?? 0
            ) { [weak self] index in
                Gtk.onMain { [weak self] in self?.effort = levels[index] }
            }, to: group)
        return group
    }

    private func charterGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(
            ExpertWords.charter,
            description: Localized.text("Standing instructions for this kind of work: a map, not a manual. Facts belong in the notebook."))
        let frame = gtk_frame_new(nil)!
        let view = gtk_text_view_new()!
        gtk_text_view_set_wrap_mode(ptr(UnsafeMutableRawPointer(view)), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_left_margin(ptr(UnsafeMutableRawPointer(view)), 10)
        gtk_text_view_set_right_margin(ptr(UnsafeMutableRawPointer(view)), 10)
        gtk_text_view_set_top_margin(ptr(UnsafeMutableRawPointer(view)), 8)
        gtk_text_view_set_bottom_margin(ptr(UnsafeMutableRawPointer(view)), 8)
        gtk_widget_set_size_request(view, -1, 140)
        tailscode_set_accessible_label(view, ExpertWords.charter)
        if let buffer = gtk_text_view_get_buffer(ptr(UnsafeMutableRawPointer(view))) {
            gtk_text_buffer_set_text(buffer, charter, -1)
            let bufferBits = UInt(bitPattern: buffer)
            Gtk.connect(UnsafeMutableRawPointer(buffer), "changed") { [weak self] in
                guard let raw = UnsafeMutablePointer<GtkTextBuffer>(bitPattern: bufferBits) else { return }
                let words = Self.bufferText(raw)
                Gtk.onMain { [weak self] in self?.charter = words }
            }
        }
        gtk_frame_set_child(ptr(frame), view)
        MachineRows.add(MachineRows.wrapped(frame, margin: 8), to: group)
        return group
    }

    private static func bufferText(_ buffer: UnsafeMutablePointer<GtkTextBuffer>) -> String {
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    private func skillsGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(
            ExpertWords.skills, description: Localized.text("A task loads these before it starts work."))
        let known = skills ?? []
        var names = known.map(\.name)
        for chosen in chosenSkills where !names.contains(chosen) { names.append(chosen) }
        if let skillsFailure {
            MachineRows.add(MachineRows.row(skillsFailure, subtitleCSS: "fact-bad"), to: group)
        } else if skills == nil {
            MachineRows.add(MachineRows.row(Localized.text("Reading skills…"), subtitleCSS: "dim-label"), to: group)
        } else if names.isEmpty {
            MachineRows.add(MachineRows.row(Localized.text("No skills on this machine."), subtitleCSS: "dim-label"), to: group)
        }
        for name in names {
            let detail = known.first { $0.name == name }?.description
            MachineRows.add(
                SettingsRows.switchRow(title: name, subtitle: detail, value: chosenSkills.contains(name)) { [weak self] on in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        if on {
                            if !self.chosenSkills.contains(name) { self.chosenSkills.append(name) }
                        } else {
                            self.chosenSkills.removeAll { $0 == name }
                        }
                    }
                }, to: group)
        }
        return group
    }

    private func notebookGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(ExpertWords.notebookFolder)
        MachineRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Adopt a folder I already keep"),
                subtitle: adopts ? nil : ExpertWords.notebookOwn, value: adopts
            ) { [weak self] on in
                Gtk.onMain { [weak self] in
                    guard let self, self.adopts != on else { return }
                    self.adopts = on
                    self.render()
                }
            }, to: group)
        if adopts {
            MachineRows.add(
                entry(Localized.text("Folder on %@", machine), value: notebookPath) { [weak self] in self?.notebookPath = $0 },
                to: group)
        }
        return group
    }

    private func notesGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(
            Localized.text("First notes"), description: Localized.text("Only the ticked ones are written into the notebook."))
        for note in notes {
            var subtitle = note.summary
            if note.lasting == false { subtitle = ExpertWords.lastingUnticked + " · " + subtitle }
            let title = note.title
            MachineRows.add(
                SettingsRows.switchRow(title: note.title, subtitle: subtitle, value: ticks.contains(note.title)) {
                    [weak self] on in
                    Gtk.onMain { [weak self] in
                        if on { self?.ticks.insert(title) } else { self?.ticks.remove(title) }
                    }
                }, to: group)
        }
        return group
    }

    private func benchGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(
            ExpertWords.bench, description: Localized.text("Devices and services the machine proves before each task."))
        for item in bench {
            let detail = [item.identifier, item.command, item.port.map { "\(item.host ?? "127.0.0.1"):\($0)" }, item.lock]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let row = MachineRows.row(item.name, subtitle: detail)
            let id = item.id
            MachineRows.suffixButton(Localized.text("Remove"), on: row) { [weak self] in
                self?.bench.removeAll { $0.id == id }
                self?.render()
            }
            MachineRows.add(row, to: group)
        }
        let add = MachineRows.link(ExpertWords.addBenchItem) { [weak self] in self?.addBenchItem() }
        MachineRows.prefix("＋", css: "accent", on: add)
        MachineRows.add(add, to: group)
        return group
    }

    private func guardsGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(ExpertWords.guards)
        for item in guards {
            var detail = item.command
            if let metric = item.metric {
                let line = metric.atMost.map { "≤ \(ExpertEditorWindow.number($0))" } ?? metric.atLeast.map { "≥ \(ExpertEditorWindow.number($0))" } ?? ""
                detail += " · /\(metric.pattern)/ \(line)\(metric.unit.map { " \($0)" } ?? "")"
            }
            let row = MachineRows.row(item.name, subtitle: detail)
            let id = item.id
            MachineRows.suffixButton(Localized.text("Remove"), on: row) { [weak self] in
                self?.guards.removeAll { $0.id == id }
                self?.render()
            }
            MachineRows.add(row, to: group)
        }
        let add = MachineRows.link(ExpertWords.addGuard) { [weak self] in self?.addGuard() }
        MachineRows.prefix("＋", css: "accent", on: add)
        MachineRows.add(add, to: group)
        let when = MachineRows.row(
            Localized.text("When they run"),
            subtitle: guardRule.map { ScheduleWords.when($0) } ?? ExpertWords.guardsOnDemand)
        MachineRows.suffixButton(Localized.text("Change…"), on: when) { [weak self] in
            guard let self else { return }
            AskLaterDialog.presentRule(machine: self.machine, title: ExpertWords.guards, parent: self.window) {
                [weak self] rule, _ in
                Gtk.onMain { [weak self] in
                    self?.guardRule = rule
                    self?.render()
                }
            }
        }
        if guardRule != nil {
            MachineRows.suffixButton(ExpertWords.guardsOnDemand, on: when) { [weak self] in
                self?.guardRule = nil
                self?.render()
            }
        }
        MachineRows.add(when, to: group)
        return group
    }

    private func saveGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        let cancel = Gtk.button(ExpertWords.cancel, css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.close() }
        }
        gtk_widget_set_sensitive(cancel, saving ? 0 : 1)
        gtk_box_append(ptr(buttons), cancel)
        let save = Gtk.button(isEdit ? ExpertWords.save : ExpertWords.create, css: ["suggested-action"]) {
            [weak self] in
            Gtk.onMain { [weak self] in self?.save() }
        }
        gtk_widget_set_sensitive(save, saving || drafting ? 0 : 1)
        gtk_box_append(ptr(buttons), save)
        MachineRows.add(MachineRows.wrapped(buttons, margin: 8), to: group)
        return group
    }

    // MARK: Pieces

    private func entry(_ title: String, value: String, onChange: @escaping @Sendable (String) -> Void)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = adw_entry_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        gtk_editable_set_text(op(row), value)
        let bits = UInt(bitPattern: row)
        Gtk.connect(UnsafeMutableRawPointer(row), "changed") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let text = gtk_editable_get_text(op(raw)).map { String(cString: $0) } ?? ""
            Gtk.onMain { onChange(text) }
        }
        return row
    }

    /// A limit as typed, said back without trapping on one too large for an integer or infinite.
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        return String(format: "%.2f", value)
    }

    func addBenchItem() {
        let (dialog, content) = Dialogs.window(title: ExpertWords.addBenchItem, parent: window, width: 460)
        let kinds: [ExpertBenchItem.Kind] = [.appleDevice, .command, .port]
        let kindNames = [Localized.text("An iPhone, iPad or other Apple device"), Localized.text("A command that proves it"), Localized.text("A port that answers")]
        let picked = ExpertDialogValue(0)
        let list = gtk_list_box_new()!
        Gtk.addClass(list, "boxed-list")
        gtk_list_box_set_selection_mode(op(list), GTK_SELECTION_NONE)
        gtk_list_box_append(op(list), SettingsRows.comboRow(title: Localized.text("Kind"), subtitle: nil, options: kindNames, selected: 0) { picked.value = $0 })
        let fields = ["name", "identifier", "command", "host", "port", "lock"]
        let titles = [
            ExpertWords.name, Localized.text("UDID, device identifier or name"), Localized.text("Command (exits 0 when it is there)"),
            Localized.text("Host"), Localized.text("Port"), Localized.text("Lock file held around work on it"),
        ]
        var built: [String: UInt] = [:]
        for (field, title) in zip(fields, titles) {
            let row = adw_entry_row_new()!
            adw_preferences_row_set_title(ptr(row), title)
            gtk_list_box_append(op(list), row)
            built[field] = UInt(bitPattern: row)
        }
        let rows = built
        gtk_box_append(ptr(content), list)
        let dialogBits = UInt(bitPattern: dialog)
        let read: @Sendable (String) -> String = { field in
            guard let bits = rows[field], let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return "" }
            return Dialogs.entryText(ptr(raw))
        }
        let add = Gtk.button(Localized.text("Add"), css: ["suggested-action"]) { [weak self] in
            Gtk.onMain { [weak self] in
                let name = read("name")
                guard !name.isEmpty else { return }
                let kind = kinds[min(picked.value, kinds.count - 1)]
                let item = ExpertBenchItem(
                    name: name, kind: kind, identifier: read("identifier").nilIfBlank, command: read("command").nilIfBlank,
                    host: read("host").nilIfBlank, port: Int(read("port")), lock: read("lock").nilIfBlank)
                self?.bench.append(item)
                self?.render()
                if let raw = UnsafeMutableRawPointer(bitPattern: dialogBits) { gtk_window_destroy(ptr(raw)) }
            }
        }
        gtk_box_append(ptr(content), Dialogs.buttonRow(window: dialog, confirm: add))
        gtk_window_present(ptr(dialog))
    }

    func addGuard() {
        let (dialog, content) = Dialogs.window(title: ExpertWords.addGuard, parent: window, width: 480)
        let note = Gtk.label(ExpertWords.noGuards, css: "row-detail", wrap: true, selectable: false)
        gtk_label_set_xalign(op(note), 0)
        gtk_box_append(ptr(content), note)
        let list = gtk_list_box_new()!
        Gtk.addClass(list, "boxed-list")
        gtk_list_box_set_selection_mode(op(list), GTK_SELECTION_NONE)
        let fields = ["name", "command", "directory", "pattern", "atMost", "atLeast", "unit", "timeout"]
        let titles = [
            ExpertWords.name, Localized.text("Command"), ExpertWords.folder,
            Localized.text("Number to read, as a pattern (optional)"), Localized.text("At most"), Localized.text("At least"),
            Localized.text("Unit"), Localized.text("Seconds it may run"),
        ]
        var built: [String: UInt] = [:]
        for (field, title) in zip(fields, titles) {
            let row = adw_entry_row_new()!
            adw_preferences_row_set_title(ptr(row), title)
            gtk_list_box_append(op(list), row)
            built[field] = UInt(bitPattern: row)
        }
        let rows = built
        gtk_box_append(ptr(content), list)
        let dialogBits = UInt(bitPattern: dialog)
        let read: @Sendable (String) -> String = { field in
            guard let bits = rows[field], let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return "" }
            return Dialogs.entryText(ptr(raw))
        }
        let add = Gtk.button(Localized.text("Add"), css: ["suggested-action"]) { [weak self] in
            Gtk.onMain { [weak self] in
                let name = read("name")
                let command = read("command")
                guard !name.isEmpty, !command.isEmpty else { return }
                let pattern = read("pattern")
                let metric =
                    pattern.isEmpty
                    ? nil
                    : ExpertGuardMetric(
                        pattern: pattern, atMost: Double(read("atMost")), atLeast: Double(read("atLeast")),
                        unit: read("unit").nilIfBlank)
                let item = ExpertGuard(
                    name: name, command: command, directory: read("directory").nilIfBlank, metric: metric,
                    timeout: Int(read("timeout")))
                self?.guards.append(item)
                self?.render()
                if let raw = UnsafeMutableRawPointer(bitPattern: dialogBits) { gtk_window_destroy(ptr(raw)) }
            }
        }
        gtk_box_append(ptr(content), Dialogs.buttonRow(window: dialog, confirm: add))
        gtk_window_present(ptr(dialog))
    }

    // MARK: Saving

    func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast(Localized.text("An expert needs a name."))
            return
        }
        guard !saving else { return }
        saving = true
        render()
        let keeper = self.keeper
        let profileID = self.profileID
        let machine = self.machine
        switch mode {
        case .edit(let id):
            let change = ExpertChange(
                name: trimmed, glyph: glyph, hue: hue.rawValue, purpose: purpose, directory: directory, model: model,
                effort: effort, charter: charter, skills: chosenSkills, notebookPath: adopts ? notebookPath : "",
                bench: bench, guards: guards, guardRule: guardRule, guardsOnDemand: guardRule == nil ? true : nil,
                timeZone: TimeZone.current.identifier)
            Task { [weak self] in
                let outcome: Result<MachineExpert, Error>
                do {
                    outcome = .success(try await keeper.updateExpert(id, change))
                } catch {
                    outcome = .failure(error)
                }
                ExpertDesk.shared.refresh()
                Gtk.onMain { [weak self] in self?.saved(outcome, profileID: profileID, machine: machine) }
            }
        case .new, .draft:
            let draft = ExpertDraft(
                name: trimmed, glyph: glyph.isEmpty ? nil : glyph, hue: hue.rawValue, purpose: purpose,
                directory: directory.nilIfBlank, model: model.nilIfBlank, effort: effort.nilIfBlank, charter: charter,
                skills: chosenSkills, notebookPath: adopts ? notebookPath.nilIfBlank : nil, bench: bench, guards: guards,
                guardRule: guardRule, timeZone: TimeZone.current.identifier, notes: notes)
            let final = ExpertMaking.finalized(draft, keeping: ticks)
            Task { [weak self] in
                let outcome: Result<MachineExpert, Error>
                do {
                    outcome = .success(try await keeper.createExpert(final))
                } catch {
                    outcome = .failure(error)
                }
                ExpertDesk.shared.refresh()
                Gtk.onMain { [weak self] in self?.saved(outcome, profileID: profileID, machine: machine) }
            }
        }
    }

    private func saved(_ outcome: Result<MachineExpert, Error>, profileID: String, machine: String) {
        saving = false
        switch outcome {
        case .success(let expert):
            ExpertDesk.shared.refresh()
            let parent = window
            let editing = isEdit
            close()
            if !editing {
                ExpertWindow.present(row: ExpertRow(profileID: profileID, machine: machine, expert: expert), parent: parent)
            } else if let page = MachineWindowRegistry.existing(ExpertWindow.key(profileID, expert.id)) as? ExpertWindow {
                page.expert = expert
                page.render()
            }
        case .failure(let error):
            toast(Self.words(error))
            render()
        }
    }
}

/// A value a closure can change, for a dialog's own small state.
final class ExpertDialogValue<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
