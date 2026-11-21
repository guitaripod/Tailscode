import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// What one shelf row says, compared before anything is redrawn.
struct MasterShelfLine: Equatable, Sendable {
    let profileID: String
    let expertID: String
    let glyph: String
    let hue: String
    let name: String
    let state: MasterLine
    let badge: Int?
}

extension MainWindow {
    /// The sidebar's shelf: a heading that opens Masters and one row per master — its mark, its
    /// name, its one state line in its tone, the notes waiting. It says nothing while no machine
    /// keeps masters, and offers New master while one does but has none.
    func makeMasterShelf() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(masterShelf, "master-shelf")
        gtk_widget_set_visible(masterShelf, 0)
        return masterShelf
    }

    func startMasterWatch() {
        if masterWatch == nil {
            masterWatch = NotificationCenter.default.addObserver(
                forName: MasterDesk.didChange, object: nil, queue: nil
            ) { [weak self] _ in
                Gtk.onMain { [weak self] in self?.renderMasterShelf() }
            }
        }
        MasterDesk.shared.refresh()
    }

    func renderMasterShelf() {
        let board = MasterDesk.shared.board
        let lines = board.rows.map { row in
            MasterShelfLine(
                profileID: row.profileID, expertID: row.master.id, glyph: row.master.glyph, hue: row.master.hue,
                name: row.master.name, state: row.state(), badge: MasterReading.badge(row.master))
        }
        let silent = board.unanswered.map {
            MasterShelfLine(
                profileID: $0.profileID, expertID: "", glyph: "", hue: "", name: $0.machine, state: MasterLine(""),
                badge: nil)
        }
        let signature = lines + silent
        let marksMoved =
            lines.map { "\($0.expertID)\($0.glyph)\($0.hue)\($0.name)" }
            != masterShelfDrawn.filter { !$0.expertID.isEmpty }.map { "\($0.expertID)\($0.glyph)\($0.hue)\($0.name)" }
        guard signature != masterShelfDrawn || gtk_widget_get_visible(masterShelf) != (board.keepsExperts ? 1 : 0)
        else {
            return
        }
        masterShelfDrawn = signature
        Gtk.removeChildren(of: masterShelf)
        guard board.keepsExperts else {
            gtk_widget_set_visible(masterShelf, 0)
            return
        }
        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(MasterWords.title.uppercased(), css: "master-shelf-heading", selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(heading), title)
        let more = Gtk.label("›", css: "dim-label", selectable: false)
        gtk_box_append(ptr(heading), more)
        gtk_widget_set_cursor_from_name(heading, "pointer")
        gtk_widget_set_tooltip_text(heading, MasterWords.title)
        Gtk.onRelease(heading) { [weak self] in self?.presentMasters() }
        gtk_box_append(ptr(masterShelf), heading)
        for (line, row) in zip(lines, board.rows) {
            gtk_box_append(ptr(masterShelf), shelfRow(line, row: row))
        }
        if lines.isEmpty, board.machines.isEmpty {
            for machine in board.unanswered {
                let quiet = Gtk.label(
                    MasterWords.notAnswering(machine.machine), css: "master-shelf-state", selectable: false)
                Gtk.addClass(quiet, MasterMarks.toneClass(.quiet))
                gtk_label_set_xalign(op(quiet), 0)
                Gtk.margins(quiet, leading: 4)
                gtk_box_append(ptr(masterShelf), quiet)
            }
        } else if lines.isEmpty {
            let add = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            Gtk.addClass(add, "master-shelf-row")
            gtk_box_append(ptr(add), Gtk.label("＋", css: "accent", selectable: false))
            gtk_box_append(ptr(add), Gtk.label(MasterWords.newMaster, css: "accent", selectable: false))
            gtk_widget_set_cursor_from_name(add, "pointer")
            Gtk.onRelease(add) { [weak self] in self?.presentNewMaster() }
            gtk_box_append(ptr(masterShelf), add)
        }
        gtk_widget_set_visible(masterShelf, 1)
        if marksMoved {
            lastSidebar = nil
            renderSidebar()
        }
    }

    private func shelfRow(_ line: MasterShelfLine, row: MasterRow) -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 9)
        Gtk.addClass(box, "master-shelf-row")
        gtk_box_append(ptr(box), MasterMarks.mark(row.master, size: .normal))
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(words, 1)
        let name = Gtk.label(line.name, css: "master-shelf-name", selectable: false)
        gtk_label_set_xalign(op(name), 0)
        gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(words), name)
        let state = Gtk.label(line.state.text, css: "master-shelf-state", selectable: false)
        Gtk.addClass(state, MasterMarks.toneClass(line.state.tone))
        gtk_label_set_xalign(op(state), 0)
        gtk_label_set_ellipsize(op(state), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(words), state)
        gtk_box_append(ptr(box), words)
        if let badge = line.badge {
            let count = Gtk.label("\(badge)", css: "master-badge", selectable: false)
            gtk_widget_set_valign(count, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(box), count)
        }
        gtk_widget_set_cursor_from_name(box, "pointer")
        gtk_widget_set_tooltip_text(box, [line.name, line.state.text, row.machine].joined(separator: " · "))
        tailscode_set_accessible_label(box, [line.name, line.state.text].joined(separator: ", "))
        let profileID = line.profileID
        let expertID = line.expertID
        Gtk.onRelease(box) { [weak self] in self?.presentMaster(profileID: profileID, expertID: expertID) }
        return box
    }

    // MARK: Opening

    func presentMasters() {
        MastersWindow.present(parent: sidebarPane ?? window)
    }

    func presentMaster(profileID: String, expertID: String) {
        guard let row = MasterDesk.shared.row(profileID: profileID, expertID: expertID) else {
            MasterDesk.shared.refresh()
            toast(Localized.text("That master is not on the machine any more."))
            return
        }
        MasterWindow.present(row: row, parent: window)
    }

    /// New master: from a skill on the machine, or blank, on the machine asked for or the only
    /// one that keeps masters.
    func presentNewMaster(profileID: String? = nil) {
        let board = MasterDesk.shared.board
        let machines = board.machines
        if let silent = board.unanswered.first(where: { $0.profileID == profileID })
            ?? (profileID == nil && machines.isEmpty ? board.unanswered.first : nil)
        {
            toast(MasterWords.notAnswering(silent.machine))
            return
        }
        guard let target = profileID ?? machines.first?.profileID,
            machines.contains(where: { $0.profileID == target }),
            let keeper = MasterDesk.shared.keeping(profileID: target)
        else {
            toast(MasterWords.cannotKeep(Localized.text("This machine")))
            return
        }
        let machine = machines.first { $0.profileID == target }?.machine ?? target
        MasterEditorWindow.presentNew(profileID: target, machine: machine, keeper: keeper, parent: window)
    }

    /// A new task for a master: the composer that says what the task starts with, carrying a
    /// conversation when one is handed over.
    func presentMasterTask(_ row: MasterRow, carry: ConversationBrief? = nil, text: String = "") {
        guard let keeper = MasterDesk.shared.keeping(profileID: row.profileID) else {
            toast(MasterWords.cannotKeep(row.machine))
            return
        }
        MasterTaskWindow.present(row: row, keeper: keeper, carry: carry, text: text, parent: window)
    }

    /// Hand to a master: which of this machine's masters takes the conversation.
    func presentHandOver(from pane: ChatPane) {
        guard let entry = pane.entry else { return }
        let masters = MasterDesk.shared.masters(on: entry.profileID)
        guard !masters.isEmpty else {
            if let silent = MasterDesk.shared.board.unanswered.first(where: { $0.profileID == entry.profileID }) {
                toast(MasterWords.notAnswering(silent.machine))
                MasterDesk.shared.refresh()
            } else if MasterDesk.shared.board.machines.contains(where: { $0.profileID == entry.profileID }) {
                toast(Localized.text("This machine has no masters yet. Make one from this chat first."))
            } else {
                toast(MasterWords.cannotKeep(entry.profileName))
                MasterDesk.shared.refresh()
            }
            return
        }
        let carry = pane.masterCarry()
        if masters.count == 1, let only = masters.first {
            presentMasterTask(only, carry: carry)
            return
        }
        let (dialog, content) = Dialogs.window(title: MasterWords.handToMaster, parent: window, width: 440)
        let note = Gtk.label(MasterWords.handOverNote(entry.session.title), css: "master-handover", wrap: true, selectable: false)
        gtk_label_set_xalign(op(note), 0)
        gtk_box_append(ptr(content), note)
        let list = gtk_list_box_new()!
        Gtk.addClass(list, "boxed-list")
        gtk_list_box_set_selection_mode(op(list), GTK_SELECTION_NONE)
        let dialogBits = UInt(bitPattern: dialog)
        for row in masters {
            let item = MachineRows.row(row.master.name, subtitle: row.state().text, subtitleCSS: MasterMarks.lineClass(row.state().tone))
            adw_action_row_add_prefix(ptr(item), MasterMarks.mark(row.master, size: .row))
            gtk_list_box_row_set_activatable(ptr(item), 1)
            Gtk.connect(UnsafeMutableRawPointer(item), "activated") { [weak self] in
                Gtk.onMain { [weak self] in
                    if let raw = UnsafeMutableRawPointer(bitPattern: dialogBits) { gtk_window_destroy(ptr(raw)) }
                    self?.presentMasterTask(row, carry: carry)
                }
            }
            gtk_list_box_append(op(list), item)
        }
        gtk_box_append(ptr(content), list)
        gtk_window_present(ptr(dialog))
    }

    /// Make a master from this chat: the machine drafts it from a fork of the conversation that
    /// is never saved, and the person reviews the draft before anything is made.
    func makeMaster(from pane: ChatPane) {
        guard let entry = pane.entry, let keeper = pane.masterKeeper else {
            toast(MasterWords.cannotKeep(pane.entry?.profileName ?? Localized.text("This machine")))
            return
        }
        MasterEditorWindow.presentDraft(
            profileID: entry.profileID, machine: entry.profileName, keeper: keeper, sessionID: entry.session.id,
            parent: window)
    }

    /// A task the machine just started, put on screen the way a new chat is.
    func openMasterTask(_ session: AgentSession, profileID: String) {
        guard let profile = MasterDesk.shared.profile(profileID) ?? fleetProfiles().first(where: { $0.id == profileID })
        else { return }
        let entry = SessionEntry(
            profileID: profile.id, profileName: profile.name, host: profile.baseURL.host ?? profile.name,
            backendType: profile.backend, session: session)
        if !entries.contains(where: { $0.session.id == entry.session.id }) { entries.insert(entry, at: 0) }
        lastSidebar = nil
        renderSidebar()
        open(entry)
        MasterDesk.shared.refresh()
        Task { [weak self] in await self?.refresh() }
    }

    // MARK: Drive

    /// Drive verbs for masters, so the harness reaches every surface without a pointer.
    func driveMasters(_ verb: String, _ argument: String) -> Bool {
        let demo = DemoWorld.claudeProfile.id
        let say: @Sendable (String) -> Void = { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
        switch verb {
        case "masters":
            MasterDesk.shared.refresh()
            Gtk.after(900) { [weak self] in
                self?.presentMasters()
                say("MASTERS \(MasterDesk.shared.board.rows.count) shelf=\(self?.masterShelfDrawn.count ?? -1)")
            }
        case "master", "masternotes", "masteredit", "mastertask", "masterbrief", "masterguards":
            let id = argument.isEmpty ? "demo-x-ipad" : argument
            Gtk.after(600) { [weak self] in
                guard let self, let row = MasterDesk.shared.row(profileID: demo, expertID: id)
                    ?? MasterDesk.shared.board.rows.first(where: { $0.master.id == id })
                else {
                    say("MASTER missing \(id)")
                    return
                }
                switch verb {
                case "master": MasterWindow.present(row: row, parent: self.window)
                case "masternotes":
                    if let keeper = MasterDesk.shared.keeping(profileID: row.profileID) {
                        MasterNotebookWindow.present(row: row, keeper: keeper, parent: self.window)
                    }
                case "masteredit":
                    if let keeper = MasterDesk.shared.keeping(profileID: row.profileID) {
                        MasterEditorWindow.presentEdit(row: row, keeper: keeper, parent: self.window)
                    }
                case "masterbrief":
                    MasterWindow.present(row: row, parent: self.window)
                    Gtk.after(900) {
                        (MachineWindowRegistry.existing(MasterWindow.key(row.profileID, row.master.id)) as? MasterWindow)?
                            .showBrief()
                    }
                case "masterguards":
                    MasterWindow.present(row: row, parent: self.window)
                    Gtk.after(600) {
                        (MachineWindowRegistry.existing(MasterWindow.key(row.profileID, row.master.id)) as? MasterWindow)?
                            .checkGuards(only: nil)
                    }
                default: self.presentMasterTask(row)
                }
                say("MASTER \(verb) \(row.master.name) \(row.state().text)")
            }
        case "masternew":
            Gtk.after(600) { [weak self] in self?.presentNewMaster(profileID: argument.isEmpty ? nil : argument) }
        case "masterdraft":
            makeMaster(from: activePane)
        case "mastermark":
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            Gtk.after(300) {
                let editors = MachineWindowRegistry.all(MasterEditorWindow.self)
                guard let editor = editors.first, let path = parts.last else { return say("MASTERMARK no editor") }
                if parts.count == 2, let hue = MasterHue.allCases.first(where: { $0.rawValue == parts[0] }) { editor.pick(hue) }
                editor.shootMarkPopover(to: path) { ok in say("MASTERMARK \(ok ? "ok" : "missing")") }
            }
        case "masterpart":
            Gtk.after(300) {
                let editors = MachineWindowRegistry.all(MasterEditorWindow.self)
                let editor = editors.first { $0.isEdit } ?? editors.first
                if argument == "back" {
                    editor?.closePart()
                } else if let part = MasterOutline.Part(rawValue: argument) {
                    editor?.closePart()
                    Gtk.after(500) { editor?.open(part) }
                }
                say("MASTERPART \(argument) editor=\(editor != nil)")
            }
        case "handover":
            let pane = activePane
            Gtk.after(600) { [weak self] in
                guard let self else { return }
                if argument.isEmpty {
                    self.presentHandOver(from: pane)
                } else if let row = MasterDesk.shared.board.rows.first(where: { $0.master.id == argument }) {
                    self.presentMasterTask(row, carry: pane.masterCarry())
                }
            }
        case "finishtask":
            activePane.finishExpertTask()
        case "debrief":
            let pane = activePane
            Gtk.after(300) {
                let debrief = pane.expertDebrief
                say(
                    "DEBRIEF \(debrief?.state.rawValue ?? "none") proposals=\(debrief?.proposals.count ?? 0) pending=\(debrief?.pending.count ?? 0) shown=\(gtk_widget_get_visible(pane.masterBox))"
                )
            }
        case "masteraccept":
            activePane.acceptAllProposals()
        case "masterlater":
            if let id = activePane.sessionID {
                activePane.masterLater.insert(id)
                activePane.renderDebriefCard()
            }
        case "masterchooser":
            activePane.openModelChooser()
        case "mastersend":
            guard let composer = MasterTaskWindow.current else {
                say("MASTERSEND no composer")
                return true
            }
            composer.type(argument)
            composer.submit()
            Gtk.after(1_500) { [weak self] in
                say("MASTERSEND opened=\(self?.activePane.entry?.session.title ?? "-") master=\(self?.activePane.entry?.session.expertID ?? "-")")
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
