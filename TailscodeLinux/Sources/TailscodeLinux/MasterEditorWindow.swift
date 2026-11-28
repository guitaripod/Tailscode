import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Making or changing a master on one short page: its mark, its name and what it is for, the
/// folder it works in, and one line for every other part (charter, skills, notebook, first notes,
/// bench, guards, model) that says what the part holds and opens it as a page of its own in the
/// same window. A draft from a chat or a skill arrives as a review — its first notes ticked
/// unless they held only that day — and nothing is saved until Create.
final class MasterEditorWindow: MachineWindow, @unchecked Sendable {
    enum Mode {
        case new
        case draft(sessionID: String)
        case edit(expertID: String)
    }

    var profileID: String
    var machine: String
    var keeper: any MachineExperts
    let mode: Mode
    var drafting = false
    var draftFailure: String?
    var saving = false
    /// The machine's skills: nil while they are read, and a failure said as one rather than as a
    /// machine with no skills.
    var skills: [ExpertSkill]?
    var skillsFailure: String?

    var name = ""
    /// The mark's letters when the person chose them; empty while the mark follows the name.
    var glyph = ""
    var hue = MasterHue.blue
    var hueChosen = false
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

    /// The part whose page is pushed over the front page, when one is.
    private(set) var part: MasterOutline.Part?
    private(set) var partGroups: [UnsafeMutablePointer<GtkWidget>] = []
    private var partPage: UnsafeMutablePointer<GtkWidget>?
    private var navigation: UnsafeMutablePointer<GtkWidget>?
    private var toasts: UnsafeMutablePointer<GtkWidget>?
    private var saveButton: UnsafeMutablePointer<GtkWidget>?
    private var cancelButton: UnsafeMutablePointer<GtkWidget>?
    private var markLabel: UnsafeMutablePointer<GtkWidget>?
    private var markPopover: UnsafeMutablePointer<GtkWidget>?
    private var skillPopover: UnsafeMutablePointer<GtkWidget>?
    private var lettersEntry: UnsafeMutablePointer<GtkWidget>?
    private var hueButtons: [(hue: MasterHue, button: UnsafeMutablePointer<GtkWidget>)] = []
    private var wordsLabel: UnsafeMutablePointer<GtkWidget>?
    private var charterView: UnsafeMutablePointer<GtkWidget>?

    static let size: (width: Int32, height: Int32) = (560, 700)

    static func key(_ profileID: String, _ mode: Mode) -> String {
        switch mode {
        case .new: return "master-new·\(profileID)"
        case .draft(let session): return "master-draft·\(profileID)·\(session)"
        case .edit(let id): return "master-edit·\(profileID)·\(id)"
        }
    }

    static func presentNew(
        profileID: String, machine: String, keeper: any MachineExperts, parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        let window =
            (MachineWindowRegistry.existing(key(profileID, .new)) as? MasterEditorWindow)
            ?? MasterEditorWindow(profileID: profileID, machine: machine, keeper: keeper, mode: .new)
        window.show(title: MasterWords.newMaster, parent: parent, width: size.width, height: size.height)
    }

    static func presentDraft(
        profileID: String, machine: String, keeper: any MachineExperts, sessionID: String,
        parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        let mode = Mode.draft(sessionID: sessionID)
        let window =
            (MachineWindowRegistry.existing(key(profileID, mode)) as? MasterEditorWindow)
            ?? MasterEditorWindow(profileID: profileID, machine: machine, keeper: keeper, mode: mode)
        window.show(title: MasterWords.newMaster, parent: parent, width: size.width, height: size.height)
    }

    static func presentEdit(row: MasterRow, keeper: any MachineExperts, parent: UnsafeMutablePointer<GtkWidget>?) {
        let mode = Mode.edit(expertID: row.master.id)
        let window =
            (MachineWindowRegistry.existing(key(row.profileID, mode)) as? MasterEditorWindow)
            ?? {
                let made = MasterEditorWindow(profileID: row.profileID, machine: row.machine, keeper: keeper, mode: mode)
                made.adopt(row.master)
                return made
            }()
        window.show(
            title: MasterWords.edit + " · " + row.master.name, parent: parent, width: size.width, height: size.height)
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

    var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    /// The mark as drawn: the person's letters, or the name's while they chose none.
    var shownGlyph: String { glyph.isEmpty ? MasterMaking.glyph(for: name) : glyph }

    func adopt(_ master: MachineExpert) {
        name = master.name
        glyph = master.glyph == MasterMaking.glyph(for: master.name) ? "" : master.glyph
        hue = MasterHue(master.hue)
        hueChosen = true
        purpose = master.purpose
        directory = master.directory ?? ""
        model = master.model ?? ""
        effort = master.effort ?? ""
        charter = master.charter
        chosenSkills = master.skills
        adopts = master.notebookPath != nil
        notebookPath = master.notebookPath ?? ""
        bench = master.bench.map(\.described)
        guards = master.guards.map(\.described)
        guardRule = master.guardRule
    }

    func adopt(_ draft: ExpertDraft) {
        name = draft.name
        glyph = draft.glyph.flatMap { $0 == MasterMaking.glyph(for: draft.name) ? nil : $0 } ?? ""
        if let hue = draft.hue { self.hue = MasterHue(hue) }
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
        if let rule = draft.guardRule { guardRule = rule }
        notes = draft.notes ?? []
        ticks = MasterMaking.defaultTicks(draft)
    }

    /// What has been typed and chosen so far, as the draft the front page reads and Create sends.
    var typed: ExpertDraft {
        ExpertDraft(
            name: name, glyph: glyph.isEmpty ? nil : glyph, hue: hueChosen ? hue.rawValue : nil, purpose: purpose,
            directory: directory.nilIfBlank, model: model.nilIfBlank, effort: effort.nilIfBlank, charter: charter,
            skills: chosenSkills, notebookPath: adopts ? notebookPath.nilIfBlank : nil, bench: bench, guards: guards,
            guardRule: guardRule, timeZone: TimeZone.current.identifier, notes: notes)
    }

    /// The front page's lines, one for each part.
    var outline: [MasterOutline.Row] {
        MasterOutline.rows(typed, kept: notes.filter { ticks.contains($0.title) }.count, modelName: modelName)
    }

    /// Whether the page offers to draft the master from a skill: a new one the machine could
    /// still write everything for, on a machine that has skills.
    var offersSkillDraft: Bool {
        isNew && !drafting && MasterOutline.canDraft(typed) && !(skills ?? []).isEmpty
    }

    private var modelName: String? {
        guard !model.isEmpty else { return nil }
        let catalog = ModelCatalogStore.cached(profileID).filter { $0.agentName == nil }
        return catalog.first { $0.id == model }.map { ModelBadge.word(for: $0.selection, in: catalog) } ?? model
    }

    // MARK: Window

    /// The editor's own window: a navigation view under a toast overlay, the front page with
    /// Cancel and Create in its header, and each part pushed over it with a way back.
    override func show(title: String, parent: UnsafeMutablePointer<GtkWidget>?, width: Int32 = 560, height: Int32 = 700) {
        if let window {
            gtk_window_present(ptr(window))
            return
        }
        let window = adw_window_new()!
        gtk_window_set_title(ptr(window), title)
        gtk_window_set_default_size(ptr(window), width, height)
        gtk_window_set_modal(ptr(window), 0)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        let navigation = adw_navigation_view_new()!
        let toasts = adw_toast_overlay_new()!
        adw_toast_overlay_set_child(op(toasts), navigation)
        adw_window_set_content(ptr(window), toasts)

        let header = adw_header_bar_new()!
        adw_header_bar_set_show_start_title_buttons(op(header), 0)
        adw_header_bar_set_show_end_title_buttons(op(header), 0)
        let cancel = Gtk.button(MasterWords.cancel) { [weak self] in
            Gtk.onMain { [weak self] in self?.close() }
        }
        let save = Gtk.button(isEdit ? MasterWords.save : MasterWords.create, css: ["suggested-action"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.save() }
        }
        adw_header_bar_pack_start(op(header), cancel)
        adw_header_bar_pack_end(op(header), save)
        let page = adw_preferences_page_new()!
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(op(toolbar), header)
        adw_toolbar_view_set_content(op(toolbar), page)
        let front = adw_navigation_page_new(toolbar, title)!
        adw_navigation_view_push(op(navigation), ptr(UnsafeMutableRawPointer(front)))

        self.window = window
        self.page = page
        self.navigation = navigation
        self.toasts = toasts
        self.saveButton = save
        self.cancelButton = cancel
        MachineWindowRegistry.hold(self)
        let key = self.key
        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") {
            MachineWindowRegistry.release(key)
        }
        Gtk.onKey(window) { [weak self] keyval, _ in
            guard keyval == UInt32(GDK_KEY_Escape), let self, self.part == nil, !self.popoverShown else { return false }
            Gtk.onMain { [weak self] in self?.close() }
            return true
        }
        opened()
        gtk_window_present(ptr(window))
    }

    private var popoverShown: Bool {
        [markPopover, skillPopover].contains { $0.map { gtk_widget_get_visible($0) != 0 } ?? false }
    }

    override func toast(_ text: String) {
        guard let toasts, let toast = adw_toast_new(text) else { return }
        adw_toast_set_timeout(toast, 3)
        adw_toast_overlay_add_toast(op(toasts), toast)
    }

    override func closed() {
        part = nil
        partPage = nil
        partGroups = []
        navigation = nil
        toasts = nil
        saveButton = nil
        cancelButton = nil
        forgetFrontWidgets()
        wordsLabel = nil
        charterView = nil
    }

    private func forgetFrontWidgets() {
        markLabel = nil
        markPopover = nil
        skillPopover = nil
        lettersEntry = nil
        hueButtons = []
    }

    override func opened() {
        render()
        readSkills()
        if case .draft(let sessionID) = mode { draft(session: sessionID, skill: nil) }
    }

    private func readSkills() {
        let keeper = self.keeper
        let asked = profileID
        Task { [weak self] in
            let read: Result<[ExpertSkill], Error>
            do {
                read = .success(try await keeper.expertSkills())
            } catch {
                read = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen, self.profileID == asked else { return }
                switch read {
                case .success(let skills): self.skills = skills
                case .failure(let error): self.skillsFailure = Self.words(error)
                }
                self.render()
            }
        }
    }

    /// Asks the machine for a draft, from a conversation or from a skill, and lays it over what
    /// was typed: what the person typed stays, everything left empty is the machine's.
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
                case .success(let draft): self.adopt(MasterOutline.merged(draft, over: self.typed))
                case .failure(let error): self.draftFailure = Self.words(error)
                }
                self.render()
            }
        }
    }

    /// Another machine for a new master: what was the old machine's — its folder, notebook,
    /// skills, bench, guards and model — is let go, and what belongs to the master itself stays.
    func move(to target: String) {
        guard target != profileID, let keeper = MasterDesk.shared.keeping(profileID: target),
            let found = MasterDesk.shared.board.machines.first(where: { $0.profileID == target })
        else { return }
        profileID = target
        machine = found.machine
        self.keeper = keeper
        model = ""
        directory = ""
        adopts = false
        notebookPath = ""
        chosenSkills = []
        skills = nil
        skillsFailure = nil
        bench = []
        guards = []
        render()
        readSkills()
    }

    // MARK: Front page

    /// Draws the front page again, and the open part's page with it. The charter's page is left
    /// as it stands: it is a text view someone may be typing in.
    func render() {
        renderFront()
        if let part, part != .charter { renderPart(part) }
    }

    private func renderFront() {
        forgetFrontWidgets()
        if let saveButton { gtk_widget_set_sensitive(saveButton, saving || drafting ? 0 : 1) }
        if let cancelButton { gtk_widget_set_sensitive(cancelButton, saving ? 0 : 1) }
        var groups: [UnsafeMutablePointer<GtkWidget>] = []
        if drafting {
            let group = MachineRows.group(nil)
            let row = MachineRows.row(
                MasterWords.drafting,
                subtitle: Localized.text("A fork of the conversation, never saved, drafts it. This takes a minute."))
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(op(spinner))
            adw_action_row_add_prefix(ptr(row), spinner)
            MachineRows.add(row, to: group)
            groups.append(group)
        }
        if let draftFailure {
            let group = MachineRows.group(nil)
            MachineRows.add(MachineRows.row(MasterWords.draftFailed, subtitle: draftFailure, subtitleCSS: "fact-bad"), to: group)
            groups.append(group)
        }
        groups += [identityGroup(), outlineGroup()]
        if isEdit { groups.append(deleteGroup()) }
        replaceGroups(groups)
    }

    private func identityGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_box_append(ptr(line), markButton())
        let fields = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_hexpand(fields, 1)
        gtk_widget_set_valign(fields, GTK_ALIGN_CENTER)
        let nameEntry = plainEntry(MasterWords.name, value: name) { [weak self] text in
            guard let self else { return }
            self.name = text
            self.redrawMark()
        }
        Gtk.addClass(nameEntry, "master-name-entry")
        gtk_box_append(ptr(fields), nameEntry)
        gtk_box_append(
            ptr(fields), plainEntry(MasterWords.purpose, value: purpose) { [weak self] text in self?.purpose = text })
        gtk_box_append(ptr(line), fields)
        MachineRows.add(MachineRows.wrapped(line, margin: 10), to: group)
        let machines = MasterDesk.shared.board.machines
        if isNew, machines.count > 1 {
            MachineRows.add(
                SettingsRows.comboRow(
                    title: Localized.text("Machine"), subtitle: nil, options: machines.map(\.machine),
                    selected: machines.firstIndex { $0.profileID == profileID } ?? 0
                ) { [weak self] index in
                    Gtk.onMain { [weak self] in
                        guard index < machines.count else { return }
                        self?.move(to: machines[index].profileID)
                    }
                }, to: group)
        }
        MachineRows.add(
            entry(MasterWords.folderPlaceholder, value: directory) { [weak self] in self?.directory = $0 }, to: group)
        return group
    }

    /// The mark as a press: its popover holds the colours and the two letters.
    private func markButton() -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_menu_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "master-mark-button")
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        let mark = MasterMarks.mark(shownGlyph, hue: hue, size: .large)
        gtk_menu_button_set_child(op(button), mark)
        Tip.set(button, MasterWords.markAndColour)
        tailscode_set_accessible_label(button, MasterWords.markAndColour)
        markLabel = mark

        let popover = gtk_popover_new()!
        let content = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(content, 8)
        hueButtons = MasterHue.allCases.map { option in
            let dot = gtk_button_new()!
            Gtk.addClass(dot, "flat")
            Gtk.addClass(dot, "circular")
            if option == hue { Gtk.addClass(dot, "master-hue-picked") }
            gtk_button_set_child(ptr(dot), MasterMarks.mark("", hue: option, size: .row))
            tailscode_set_accessible_label(dot, option.name)
            Tip.set(dot, option.name)
            Gtk.connect(UnsafeMutableRawPointer(dot), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in self?.pick(option) }
            }
            return (option, dot)
        }
        let dots = gtk_grid_new()!
        gtk_grid_set_column_spacing(ptr(dots), 4)
        gtk_grid_set_row_spacing(ptr(dots), 4)
        for (index, item) in hueButtons.enumerated() {
            gtk_grid_attach(ptr(dots), item.button, Int32(index % 5), Int32(index / 5), 1, 1)
        }
        gtk_box_append(ptr(content), dots)
        let letters = plainEntry(MasterWords.letters, value: glyph) { [weak self] text in
            guard let self else { return }
            self.glyph = String(text.prefix(2))
            self.redrawMark()
        }
        gtk_entry_set_max_length(ptr(letters), 2)
        gtk_entry_set_placeholder_text(ptr(letters), MasterWords.letters + " · " + MasterMaking.glyph(for: name))
        gtk_box_append(ptr(content), letters)
        lettersEntry = letters
        gtk_popover_set_child(ptr(popover), content)
        gtk_menu_button_set_popover(op(button), popover)
        markPopover = popover
        return button
    }

    /// Opens the mark's popover and draws it into a file, for the harness: a popover has a
    /// surface of its own, which a picture of the window leaves out.
    func shootMarkPopover(to path: String, done: @escaping @Sendable (Bool) -> Void) {
        guard let markPopover else { return done(false) }
        gtk_popover_popup(ptr(markPopover))
        Gtk.after(500) { [weak self] in
            guard let popover = self?.markPopover else { return done(false) }
            done(WindowShot.render(popover, to: path))
        }
    }

    func pick(_ option: MasterHue) {
        if let markLabel {
            gtk_widget_remove_css_class(markLabel, "master-hue-\(hue.rawValue)")
            Gtk.addClass(markLabel, "master-hue-\(option.rawValue)")
        }
        hue = option
        hueChosen = true
        for item in hueButtons {
            if item.hue == option {
                Gtk.addClass(item.button, "master-hue-picked")
            } else {
                gtk_widget_remove_css_class(item.button, "master-hue-picked")
            }
        }
    }

    private func redrawMark() {
        if let markLabel {
            gtk_label_set_text(op(markLabel), shownGlyph)
            tailscode_set_accessible_label(markLabel, shownGlyph)
        }
        if let lettersEntry {
            gtk_entry_set_placeholder_text(ptr(lettersEntry), MasterWords.letters + " · " + MasterMaking.glyph(for: name))
        }
    }

    private func outlineGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        if offersSkillDraft, let skills { MachineRows.add(skillDraftRow(skills), to: group) }
        for line in outline {
            let row = MachineRows.row(line.title)
            gtk_list_box_row_set_activatable(ptr(row), 1)
            let value = Gtk.label(line.value, css: line.isSet ? "master-outline-value" : "dim-label", selectable: false)
            gtk_label_set_ellipsize(op(value), PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_max_width_chars(op(value), 34)
            gtk_label_set_xalign(op(value), 1)
            gtk_widget_set_valign(value, GTK_ALIGN_CENTER)
            Tip.set(value, line.value)
            adw_action_row_add_suffix(ptr(row), value)
            let chevron = Gtk.label("›", css: "dim-label", selectable: false)
            gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(ptr(row), chevron)
            tailscode_set_accessible_label(row, line.title + ", " + line.value)
            let part = line.part
            Gtk.connect(UnsafeMutableRawPointer(row), "activated") { [weak self] in
                Gtk.onMain { [weak self] in self?.open(part) }
            }
            MachineRows.add(row, to: group)
        }
        return group
    }

    /// One row that starts a new master from a skill on the machine: its press lists the skills,
    /// and picking one asks the machine to write the charter, the bench and the guards from it.
    private func skillDraftRow(_ skills: [ExpertSkill]) -> UnsafeMutablePointer<GtkWidget> {
        let row = MachineRows.row(MasterWords.draftFromSkill, subtitle: MasterWords.draftFromSkillDetail)
        Gtk.addClass(row, "master-draft-row")
        let button = gtk_menu_button_new()!
        gtk_menu_button_set_label(op(button), Localized.text("Choose"))
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(button, MasterWords.draftFromSkill)
        let popover = gtk_popover_new()!
        let list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        for skill in skills {
            let name = skill.name
            let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
            let title = Gtk.label(skill.name, css: "master-shelf-name", selectable: false)
            gtk_label_set_xalign(op(title), 0)
            gtk_box_append(ptr(words), title)
            if !skill.description.isEmpty {
                let detail = Gtk.label(skill.description, css: "master-skill-detail", wrap: true, selectable: false)
                gtk_label_set_xalign(op(detail), 0)
                gtk_label_set_max_width_chars(op(detail), 44)
                Gtk.addClass(detail, "dim-label")
                gtk_box_append(ptr(words), detail)
            }
            let pick = gtk_button_new()!
            Gtk.addClass(pick, "flat")
            gtk_button_set_child(ptr(pick), words)
            tailscode_set_accessible_label(pick, skill.name)
            Gtk.connect(UnsafeMutableRawPointer(pick), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    if let popover = self.skillPopover { gtk_popover_popdown(ptr(popover)) }
                    self.draft(session: nil, skill: name)
                }
            }
            gtk_box_append(ptr(list), pick)
        }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_propagate_natural_width(op(scroller), 1)
        gtk_scrolled_window_set_max_content_height(op(scroller), 360)
        gtk_scrolled_window_set_child(op(scroller), list)
        gtk_popover_set_child(ptr(popover), scroller)
        gtk_menu_button_set_popover(op(button), popover)
        skillPopover = popover
        adw_action_row_add_suffix(ptr(row), button)
        adw_action_row_set_activatable_widget(ptr(row), button)
        return row
    }

    private func deleteGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let row = MachineRows.row(MasterWords.delete, subtitle: MasterWords.deleteDetail)
        MachineRows.suffixButton(Localized.text("Delete"), css: ["destructive-action"], sensitive: !saving, on: row) {
            [weak self] in self?.confirmDelete()
        }
        MachineRows.add(row, to: group)
        return group
    }

    func confirmDelete() {
        guard case .edit(let id) = mode else { return }
        let keeper = self.keeper
        let profileID = self.profileID
        Dialogs.confirm(
            title: MasterWords.delete + "?", body: name + "\n\n" + MasterWords.deleteDetail,
            confirmLabel: Localized.text("Delete"), parent: window
        ) { [weak self] in
            Task { [weak self] in
                do {
                    try await keeper.deleteExpert(id)
                    Gtk.onMain { [weak self] in
                        MasterDesk.shared.refresh()
                        MachineWindowRegistry.existing(MasterWindow.key(profileID, id))?.close()
                        self?.close()
                    }
                } catch {
                    Gtk.onMain { [weak self] in self?.toast(Self.words(error)) }
                }
            }
        }
    }

    // MARK: Parts

    /// Pushes one part's page over the front page. Coming back draws the front page again, so
    /// its line says what the part holds now.
    func open(_ part: MasterOutline.Part) {
        guard let navigation, self.part == nil else { return }
        self.part = part
        let page = adw_preferences_page_new()!
        partPage = page
        partGroups = []
        let header = adw_header_bar_new()!
        adw_header_bar_set_show_end_title_buttons(op(header), 0)
        adw_header_bar_set_show_start_title_buttons(op(header), 0)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(op(toolbar), header)
        adw_toolbar_view_set_content(op(toolbar), page)
        let pushed = adw_navigation_page_new(toolbar, MasterOutline.row(part, typed).title)!
        Gtk.connect(UnsafeMutableRawPointer(pushed), "hidden") { [weak self] in
            Gtk.onMain { [weak self] in self?.partClosed(part) }
        }
        adw_navigation_view_push(op(navigation), ptr(UnsafeMutableRawPointer(pushed)))
        renderPart(part)
    }

    /// Goes back to the front page.
    func closePart() {
        guard part != nil, let navigation else { return }
        adw_navigation_view_pop(op(navigation))
    }

    private func partClosed(_ closed: MasterOutline.Part) {
        guard part == closed else { return }
        part = nil
        partPage = nil
        partGroups = []
        wordsLabel = nil
        charterView = nil
        guard isOpen else { return }
        renderFront()
    }

    private func renderPart(_ part: MasterOutline.Part) {
        guard let partPage else { return }
        let fresh: [UnsafeMutablePointer<GtkWidget>]
        switch part {
        case .charter: fresh = [charterGroup()]
        case .skills: fresh = [skillsGroup()]
        case .notebook: fresh = [notebookGroup()]
        case .notes: fresh = [notesGroup()]
        case .bench: fresh = [benchGroup()]
        case .guards: fresh = [guardsGroup(), guardRuleGroup()]
        case .model: fresh = [modelGroup()]
        }
        for group in partGroups { adw_preferences_page_remove(ptr(partPage), ptr(group)) }
        partGroups = fresh
        for group in fresh { adw_preferences_page_add(ptr(partPage), ptr(group)) }
    }

    private func modelGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil, description: machine)
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
            SettingsRows.comboRow(title: MasterWords.model, subtitle: nil, options: modelOptions, selected: chosen) {
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
            nil,
            description: Localized.text("Standing instructions for this kind of work: a map, not a manual. Facts belong in the notebook."))
        let frame = gtk_frame_new(nil)!
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_height(op(scroller), 380)
        let view = gtk_text_view_new()!
        gtk_text_view_set_wrap_mode(ptr(UnsafeMutableRawPointer(view)), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_left_margin(ptr(UnsafeMutableRawPointer(view)), 12)
        gtk_text_view_set_right_margin(ptr(UnsafeMutableRawPointer(view)), 12)
        gtk_text_view_set_top_margin(ptr(UnsafeMutableRawPointer(view)), 10)
        gtk_text_view_set_bottom_margin(ptr(UnsafeMutableRawPointer(view)), 10)
        tailscode_set_accessible_label(view, MasterWords.charter)
        let count = Gtk.label(MasterOutline.wordCount(MasterOutline.words(charter)), css: "dim-label", selectable: false)
        gtk_label_set_xalign(op(count), 1)
        wordsLabel = count
        if let buffer = gtk_text_view_get_buffer(ptr(UnsafeMutableRawPointer(view))) {
            gtk_text_buffer_set_text(buffer, charter, -1)
            let bufferBits = UInt(bitPattern: buffer)
            Gtk.connect(UnsafeMutableRawPointer(buffer), "changed") { [weak self] in
                guard let raw = UnsafeMutablePointer<GtkTextBuffer>(bitPattern: bufferBits) else { return }
                let words = Self.bufferText(raw)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.charter = words
                    if let label = self.wordsLabel {
                        gtk_label_set_text(op(label), MasterOutline.wordCount(MasterOutline.words(words)))
                    }
                }
            }
        }
        gtk_scrolled_window_set_child(op(scroller), view)
        gtk_frame_set_child(ptr(frame), scroller)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_box_append(ptr(column), frame)
        gtk_box_append(ptr(column), count)
        MachineRows.add(MachineRows.wrapped(column, margin: 8), to: group)
        charterView = view
        Gtk.after(120) { [weak self] in
            if let view = self?.charterView { gtk_widget_grab_focus(view) }
        }
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
        let group = MachineRows.group(nil, description: Localized.text("A task loads these before it starts work."))
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
        let group = MachineRows.group(
            nil,
            description: Localized.text("A folder you already keep is adopted as it is: one fact per file, indexed in MEMORY.md. Notes are only written when you accept them."))
        MachineRows.add(
            SettingsRows.switchRow(
                title: Localized.text("Adopt a folder I already keep"),
                subtitle: adopts ? nil : MasterWords.notebookOwn, value: adopts
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
        let group = MachineRows.group(nil, description: Localized.text("Only the ticked ones are written into the notebook."))
        for note in notes {
            let title = note.title
            let row = SettingsRows.switchRow(title: note.title, subtitle: note.summary, value: ticks.contains(note.title)) {
                [weak self] on in
                Gtk.onMain { [weak self] in
                    if on { self?.ticks.insert(title) } else { self?.ticks.remove(title) }
                }
            }
            adw_action_row_set_subtitle_lines(ptr(row), 0)
            if note.lasting == false {
                let tag = Gtk.label(MasterWords.lastingUnticked, css: "master-stale", selectable: false)
                gtk_widget_set_valign(tag, GTK_ALIGN_CENTER)
                adw_action_row_add_suffix(ptr(row), tag)
            }
            MachineRows.add(row, to: group)
        }
        return group
    }

    private func benchGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(
            nil, description: Localized.text("Devices and services the machine proves before each task."))
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
        let add = MachineRows.link(MasterWords.addBenchItem) { [weak self] in self?.addBenchItem() }
        MachineRows.prefix("＋", css: "accent", on: add)
        MachineRows.add(add, to: group)
        return group
    }

    private func guardsGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil, description: guards.isEmpty ? MasterWords.noGuards : nil)
        for item in guards {
            var detail = item.command
            if let metric = item.metric {
                let line = metric.atMost.map { "≤ \(MasterEditorWindow.number($0))" } ?? metric.atLeast.map { "≥ \(MasterEditorWindow.number($0))" } ?? ""
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
        let add = MachineRows.link(MasterWords.addGuard) { [weak self] in self?.addGuard() }
        MachineRows.prefix("＋", css: "accent", on: add)
        MachineRows.add(add, to: group)
        return group
    }

    private func guardRuleGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let when = MachineRows.row(
            Localized.text("When they run"),
            subtitle: guardRule.map { ScheduleWords.when($0) } ?? MasterWords.guardsOnDemand)
        MachineRows.suffixButton(Localized.text("Change…"), on: when) { [weak self] in
            guard let self else { return }
            AskLaterDialog.presentRule(machine: self.machine, title: MasterWords.guards, parent: self.window) {
                [weak self] rule, _ in
                Gtk.onMain { [weak self] in
                    self?.guardRule = rule
                    self?.render()
                }
            }
        }
        if guardRule != nil {
            MachineRows.suffixButton(MasterWords.guardsOnDemand, on: when) { [weak self] in
                self?.guardRule = nil
                self?.render()
            }
        }
        MachineRows.add(when, to: group)
        return group
    }

    // MARK: Pieces

    /// A bare entry that says what it is for in its placeholder, for the lines beside the mark.
    private func plainEntry(_ title: String, value: String, onChange: @escaping @Sendable (String) -> Void)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(entry), title)
        gtk_editable_set_text(op(entry), value)
        tailscode_set_accessible_label(entry, title)
        let bits = UInt(bitPattern: entry)
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let text = gtk_editable_get_text(op(raw)).map { String(cString: $0) } ?? ""
            Gtk.onMain { onChange(text) }
        }
        return entry
    }

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
}
