import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// What one shelf row says, compared before anything is redrawn.
struct ExpertShelfLine: Equatable, Sendable {
    let profileID: String
    let expertID: String
    let glyph: String
    let hue: String
    let name: String
    let state: ExpertLine
    let badge: Int?
}

extension MainWindow {
    /// The sidebar's shelf: a heading that opens Experts and one row per expert — its mark, its
    /// name, its one state line in its tone, the notes waiting. It says nothing while no machine
    /// keeps experts, and offers New expert while one does but has none.
    func makeExpertShelf() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(expertShelf, "expert-shelf")
        gtk_widget_set_visible(expertShelf, 0)
        return expertShelf
    }

    func startExpertWatch() {
        if expertWatch == nil {
            expertWatch = NotificationCenter.default.addObserver(
                forName: ExpertDesk.didChange, object: nil, queue: nil
            ) { [weak self] _ in
                Gtk.onMain { [weak self] in self?.renderExpertShelf() }
            }
        }
        ExpertDesk.shared.refresh()
    }

    func renderExpertShelf() {
        let board = ExpertDesk.shared.board
        let lines = board.rows.map { row in
            ExpertShelfLine(
                profileID: row.profileID, expertID: row.expert.id, glyph: row.expert.glyph, hue: row.expert.hue,
                name: row.expert.name, state: row.state(), badge: ExpertReading.badge(row.expert))
        }
        let silent = board.unanswered.map {
            ExpertShelfLine(
                profileID: $0.profileID, expertID: "", glyph: "", hue: "", name: $0.machine, state: ExpertLine(""),
                badge: nil)
        }
        let signature = lines + silent
        let marksMoved =
            lines.map { "\($0.expertID)\($0.glyph)\($0.hue)\($0.name)" }
            != expertShelfDrawn.filter { !$0.expertID.isEmpty }.map { "\($0.expertID)\($0.glyph)\($0.hue)\($0.name)" }
        guard signature != expertShelfDrawn || gtk_widget_get_visible(expertShelf) != (board.keepsExperts ? 1 : 0)
        else {
            return
        }
        expertShelfDrawn = signature
        Gtk.removeChildren(of: expertShelf)
        guard board.keepsExperts else {
            gtk_widget_set_visible(expertShelf, 0)
            return
        }
        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(ExpertWords.title.uppercased(), css: "expert-shelf-heading", selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(heading), title)
        let more = Gtk.label("›", css: "dim-label", selectable: false)
        gtk_box_append(ptr(heading), more)
        gtk_widget_set_cursor_from_name(heading, "pointer")
        gtk_widget_set_tooltip_text(heading, ExpertWords.title)
        Gtk.onRelease(heading) { [weak self] in self?.presentExperts() }
        gtk_box_append(ptr(expertShelf), heading)
        for (line, row) in zip(lines, board.rows) {
            gtk_box_append(ptr(expertShelf), shelfRow(line, row: row))
        }
        if lines.isEmpty, board.machines.isEmpty {
            for machine in board.unanswered {
                let quiet = Gtk.label(
                    ExpertWords.notAnswering(machine.machine), css: "expert-shelf-state", selectable: false)
                Gtk.addClass(quiet, ExpertMarks.toneClass(.quiet))
                gtk_label_set_xalign(op(quiet), 0)
                Gtk.margins(quiet, leading: 4)
                gtk_box_append(ptr(expertShelf), quiet)
            }
        } else if lines.isEmpty {
            let add = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            Gtk.addClass(add, "expert-shelf-row")
            gtk_box_append(ptr(add), Gtk.label("＋", css: "accent", selectable: false))
            gtk_box_append(ptr(add), Gtk.label(ExpertWords.newExpert, css: "accent", selectable: false))
            gtk_widget_set_cursor_from_name(add, "pointer")
            Gtk.onRelease(add) { [weak self] in self?.presentNewExpert() }
            gtk_box_append(ptr(expertShelf), add)
        }
        gtk_widget_set_visible(expertShelf, 1)
        if marksMoved {
            lastSidebar = nil
            renderSidebar()
        }
    }

    private func shelfRow(_ line: ExpertShelfLine, row: ExpertRow) -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 9)
        Gtk.addClass(box, "expert-shelf-row")
        gtk_box_append(ptr(box), ExpertMarks.mark(row.expert, size: .normal))
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(words, 1)
        let name = Gtk.label(line.name, css: "expert-shelf-name", selectable: false)
        gtk_label_set_xalign(op(name), 0)
        gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(words), name)
        let state = Gtk.label(line.state.text, css: "expert-shelf-state", selectable: false)
        Gtk.addClass(state, ExpertMarks.toneClass(line.state.tone))
        gtk_label_set_xalign(op(state), 0)
        gtk_label_set_ellipsize(op(state), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(words), state)
        gtk_box_append(ptr(box), words)
        if let badge = line.badge {
            let count = Gtk.label("\(badge)", css: "expert-badge", selectable: false)
            gtk_widget_set_valign(count, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(box), count)
        }
        gtk_widget_set_cursor_from_name(box, "pointer")
        gtk_widget_set_tooltip_text(box, [line.name, line.state.text, row.machine].joined(separator: " · "))
        tailscode_set_accessible_label(box, [line.name, line.state.text].joined(separator: ", "))
        let profileID = line.profileID
        let expertID = line.expertID
        Gtk.onRelease(box) { [weak self] in self?.presentExpert(profileID: profileID, expertID: expertID) }
        return box
    }

    // MARK: Opening

    func presentExperts() {
        ExpertsWindow.present(parent: sidebarPane ?? window)
    }

    func presentExpert(profileID: String, expertID: String) {
        guard let row = ExpertDesk.shared.row(profileID: profileID, expertID: expertID) else {
            ExpertDesk.shared.refresh()
            toast(Localized.text("That expert is not on the machine any more."))
            return
        }
        ExpertWindow.present(row: row, parent: window)
    }

    /// New expert: from a skill on the machine, or blank, on the machine asked for or the only
    /// one that keeps experts.
    func presentNewExpert(profileID: String? = nil) {
        let board = ExpertDesk.shared.board
        let machines = board.machines
        if let silent = board.unanswered.first(where: { $0.profileID == profileID })
            ?? (profileID == nil && machines.isEmpty ? board.unanswered.first : nil)
        {
            toast(ExpertWords.notAnswering(silent.machine))
            return
        }
        guard let target = profileID ?? machines.first?.profileID,
            machines.contains(where: { $0.profileID == target }),
            let keeper = ExpertDesk.shared.keeping(profileID: target)
        else {
            toast(ExpertWords.cannotKeep(Localized.text("This machine")))
            return
        }
        let machine = machines.first { $0.profileID == target }?.machine ?? target
        ExpertEditorWindow.presentNew(profileID: target, machine: machine, keeper: keeper, parent: window)
    }

    /// A new task for an expert: the composer that says what the task starts with, carrying a
    /// conversation when one is handed over.
    func presentExpertTask(_ row: ExpertRow, carry: ConversationBrief? = nil, text: String = "") {
        guard let keeper = ExpertDesk.shared.keeping(profileID: row.profileID) else {
            toast(ExpertWords.cannotKeep(row.machine))
            return
        }
        ExpertTaskWindow.present(row: row, keeper: keeper, carry: carry, text: text, parent: window)
    }

    /// Hand to an expert: which of this machine's experts takes the conversation.
    func presentHandOver(from pane: ChatPane) {
        guard let entry = pane.entry else { return }
        let experts = ExpertDesk.shared.experts(on: entry.profileID)
        guard !experts.isEmpty else {
            if let silent = ExpertDesk.shared.board.unanswered.first(where: { $0.profileID == entry.profileID }) {
                toast(ExpertWords.notAnswering(silent.machine))
                ExpertDesk.shared.refresh()
            } else if ExpertDesk.shared.board.machines.contains(where: { $0.profileID == entry.profileID }) {
                toast(Localized.text("This machine has no experts yet. Make one from this chat first."))
            } else {
                toast(ExpertWords.cannotKeep(entry.profileName))
                ExpertDesk.shared.refresh()
            }
            return
        }
        let carry = pane.expertCarry()
        if experts.count == 1, let only = experts.first {
            presentExpertTask(only, carry: carry)
            return
        }
        let (dialog, content) = Dialogs.window(title: ExpertWords.handToExpert, parent: window, width: 440)
        let note = Gtk.label(ExpertWords.handOverNote(entry.session.title), css: "expert-handover", wrap: true, selectable: false)
        gtk_label_set_xalign(op(note), 0)
        gtk_box_append(ptr(content), note)
        let list = gtk_list_box_new()!
        Gtk.addClass(list, "boxed-list")
        gtk_list_box_set_selection_mode(op(list), GTK_SELECTION_NONE)
        let dialogBits = UInt(bitPattern: dialog)
        for row in experts {
            let item = MachineRows.row(row.expert.name, subtitle: row.state().text, subtitleCSS: ExpertMarks.lineClass(row.state().tone))
            adw_action_row_add_prefix(ptr(item), ExpertMarks.mark(row.expert, size: .row))
            gtk_list_box_row_set_activatable(ptr(item), 1)
            Gtk.connect(UnsafeMutableRawPointer(item), "activated") { [weak self] in
                Gtk.onMain { [weak self] in
                    if let raw = UnsafeMutableRawPointer(bitPattern: dialogBits) { gtk_window_destroy(ptr(raw)) }
                    self?.presentExpertTask(row, carry: carry)
                }
            }
            gtk_list_box_append(op(list), item)
        }
        gtk_box_append(ptr(content), list)
        gtk_window_present(ptr(dialog))
    }

    /// Make an expert from this chat: the machine drafts it from a fork of the conversation that
    /// is never saved, and the person reviews the draft before anything is made.
    func makeExpert(from pane: ChatPane) {
        guard let entry = pane.entry, let keeper = pane.expertKeeper else {
            toast(ExpertWords.cannotKeep(pane.entry?.profileName ?? Localized.text("This machine")))
            return
        }
        ExpertEditorWindow.presentDraft(
            profileID: entry.profileID, machine: entry.profileName, keeper: keeper, sessionID: entry.session.id,
            parent: window)
    }

    /// A task the machine just started, put on screen the way a new chat is.
    func openExpertTask(_ session: AgentSession, profileID: String) {
        guard let profile = ExpertDesk.shared.profile(profileID) ?? fleetProfiles().first(where: { $0.id == profileID })
        else { return }
        let entry = SessionEntry(
            profileID: profile.id, profileName: profile.name, host: profile.baseURL.host ?? profile.name,
            backendType: profile.backend, session: session)
        if !entries.contains(where: { $0.session.id == entry.session.id }) { entries.insert(entry, at: 0) }
        lastSidebar = nil
        renderSidebar()
        open(entry)
        ExpertDesk.shared.refresh()
        Task { [weak self] in await self?.refresh() }
    }

    // MARK: Drive

    /// Drive verbs for experts, so the harness reaches every surface without a pointer.
    func driveExperts(_ verb: String, _ argument: String) -> Bool {
        let demo = DemoWorld.claudeProfile.id
        let say: @Sendable (String) -> Void = { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
        switch verb {
        case "experts":
            ExpertDesk.shared.refresh()
            Gtk.after(900) { [weak self] in
                self?.presentExperts()
                say("EXPERTS \(ExpertDesk.shared.board.rows.count) shelf=\(self?.expertShelfDrawn.count ?? -1)")
            }
        case "expert", "expertnotes", "expertedit", "experttask", "expertbrief", "expertguards":
            let id = argument.isEmpty ? "demo-x-ipad" : argument
            Gtk.after(600) { [weak self] in
                guard let self, let row = ExpertDesk.shared.row(profileID: demo, expertID: id)
                    ?? ExpertDesk.shared.board.rows.first(where: { $0.expert.id == id })
                else {
                    say("EXPERT missing \(id)")
                    return
                }
                switch verb {
                case "expert": ExpertWindow.present(row: row, parent: self.window)
                case "expertnotes":
                    if let keeper = ExpertDesk.shared.keeping(profileID: row.profileID) {
                        ExpertNotebookWindow.present(row: row, keeper: keeper, parent: self.window)
                    }
                case "expertedit":
                    if let keeper = ExpertDesk.shared.keeping(profileID: row.profileID) {
                        ExpertEditorWindow.presentEdit(row: row, keeper: keeper, parent: self.window)
                    }
                case "expertbrief":
                    ExpertWindow.present(row: row, parent: self.window)
                    Gtk.after(900) {
                        (MachineWindowRegistry.existing(ExpertWindow.key(row.profileID, row.expert.id)) as? ExpertWindow)?
                            .showBrief()
                    }
                case "expertguards":
                    ExpertWindow.present(row: row, parent: self.window)
                    Gtk.after(600) {
                        (MachineWindowRegistry.existing(ExpertWindow.key(row.profileID, row.expert.id)) as? ExpertWindow)?
                            .checkGuards(only: nil)
                    }
                default: self.presentExpertTask(row)
                }
                say("EXPERT \(verb) \(row.expert.name) \(row.state().text)")
            }
        case "expertnew":
            Gtk.after(600) { [weak self] in self?.presentNewExpert(profileID: argument.isEmpty ? nil : argument) }
        case "expertdraft":
            makeExpert(from: activePane)
        case "handover":
            let pane = activePane
            Gtk.after(600) { [weak self] in
                guard let self else { return }
                if argument.isEmpty {
                    self.presentHandOver(from: pane)
                } else if let row = ExpertDesk.shared.board.rows.first(where: { $0.expert.id == argument }) {
                    self.presentExpertTask(row, carry: pane.expertCarry())
                }
            }
        case "finishtask":
            activePane.finishExpertTask()
        case "debrief":
            let pane = activePane
            Gtk.after(300) {
                let debrief = pane.expertDebrief
                say(
                    "DEBRIEF \(debrief?.state.rawValue ?? "none") proposals=\(debrief?.proposals.count ?? 0) pending=\(debrief?.pending.count ?? 0) shown=\(gtk_widget_get_visible(pane.expertBox))"
                )
            }
        case "expertaccept":
            activePane.acceptAllProposals()
        case "expertlater":
            if let id = activePane.sessionID {
                activePane.expertLater.insert(id)
                activePane.renderDebriefCard()
            }
        case "expertchooser":
            activePane.openModelChooser()
        case "expertsend":
            guard let composer = ExpertTaskWindow.current else {
                say("EXPERTSEND no composer")
                return true
            }
            composer.type(argument)
            composer.submit()
            Gtk.after(1_500) { [weak self] in
                say("EXPERTSEND opened=\(self?.activePane.entry?.session.title ?? "-") expert=\(self?.activePane.entry?.session.expertID ?? "-")")
            }
        case "appearance":
            Preferences.setAppearance(Preferences.Appearance(rawValue: argument) ?? .system)
            Preferences.applyAppearance()
            MatrixTheme.install()
            say("APPEARANCE \(Preferences.appearance.rawValue)")
        case "windowshot":
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return true }
            Gtk.after(200) {
                say("WINDOWSHOT \(parts[0]) \(WindowShot.render(titled: parts[0], to: parts[1]) ? "ok" : "missing")")
            }
        default:
            return false
        }
        return true
    }
}
