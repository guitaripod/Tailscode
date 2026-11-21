import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Masters: every machine's masters, each machine its own group in the order the person keeps
/// them, each master its mark, its name and its one state line, opening its page. A machine that
/// keeps masters offers New master; one that cannot is said to be one.
final class MastersWindow: MachineWindow, @unchecked Sendable {
    static let windowKey = "masters·all"
    var watch: NSObjectProtocol?
    private let beta = BetaBadge(feature: .masters) { MasterDesk.shared.board.betaReportLines }
    private var lead: UnsafeMutablePointer<GtkWidget>?
    var servers: [(id: String, name: String)] = []

    /// The machines that answered without keeping masters: opencode, omp-bridge, a claude-bridge
    /// too old for them. One that keeps masters but is not answering is said to be not answering,
    /// never to be one that cannot.
    var others: [String] {
        let board = MasterDesk.shared.board
        let known = Set(board.machines.map(\.profileID) + board.unanswered.map(\.profileID))
        return servers.filter { !known.contains($0.id) }.map(\.name)
    }

    static func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        let window = (MachineWindowRegistry.existing(windowKey) as? MastersWindow) ?? MastersWindow()
        window.show(title: MasterWords.title, parent: parent, width: 560, height: 680)
    }

    init() {
        super.init(key: Self.windowKey)
    }

    override func opened() {
        watch = NotificationCenter.default.addObserver(forName: MasterDesk.didChange, object: nil, queue: nil) {
            [weak self] _ in
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                self.render()
            }
        }
        MasterDesk.shared.watch(key)
        MasterDesk.shared.refresh()
        render()
        Task { [weak self] in
            let servers = await MachineFeatures.servers()
            let pairs = servers.map { ($0.profile.id, $0.profile.name) }
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                self.servers = pairs
                self.render()
            }
        }
    }

    override func closed() {
        beta.tearDown()
        lead = nil
        MasterDesk.shared.unwatch(key)
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
    }

    /// The page's groups under its head: the feature's name with the mark it wears while in beta.
    /// The head is put on the page once and never taken off it, because a group taken off a page
    /// is let go, and the mark would go with it under a press.
    private func showGroups(_ fresh: [UnsafeMutablePointer<GtkWidget>]) {
        if lead == nil, let page {
            let group = MachineRows.group(MasterWords.title, description: MasterWords.emptyDetail)
            gtk_widget_set_valign(beta.widget, GTK_ALIGN_START)
            adw_preferences_group_set_header_suffix(ptr(group), beta.widget)
            adw_preferences_page_add(ptr(page), ptr(group))
            lead = group
        }
        replaceGroups(fresh)
    }

    func render() {
        let board = MasterDesk.shared.board
        var groups: [UnsafeMutablePointer<GtkWidget>] = []
        if !MasterDesk.shared.loadedOnce {
            let group = MachineRows.group(nil)
            MachineRows.add(MachineRows.row(Localized.text("Asking every machine…")), to: group)
            showGroups([group])
            return
        }
        if board.isEmpty, !board.machines.isEmpty || board.unanswered.isEmpty {
            let group = MachineRows.group(nil)
            let row = MachineRows.row(MasterWords.empty, subtitle: MasterWords.emptyDetail)
            MachineRows.prefix("✦", css: "accent", on: row)
            MachineRows.add(row, to: group)
            groups.append(group)
        }
        for machine in board.machines {
            let group = MachineRows.group(board.machines.count > 1 || !board.isEmpty ? machine.machine : nil)
            for row in board.rows where row.profileID == machine.profileID {
                let state = row.state()
                let item = MachineRows.row(
                    row.master.name, subtitle: state.text, subtitleCSS: MasterMarks.lineClass(state.tone))
                adw_action_row_add_prefix(ptr(item), MasterMarks.mark(row.master, size: .row))
                if let badge = MasterReading.badge(row.master) {
                    let count = Gtk.label("\(badge)", css: "master-badge", selectable: false)
                    gtk_widget_set_valign(count, GTK_ALIGN_CENTER)
                    adw_action_row_add_suffix(ptr(item), count)
                }
                let chevron = Gtk.label("›", css: "dim-label", selectable: false)
                gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
                adw_action_row_add_suffix(ptr(item), chevron)
                gtk_list_box_row_set_activatable(ptr(item), 1)
                tailscode_set_accessible_label(item, [row.master.name, state.text].joined(separator: ", "))
                Gtk.connect(UnsafeMutableRawPointer(item), "activated") { [weak self] in
                    Gtk.onMain { [weak self] in MasterWindow.present(row: row, parent: self?.window) }
                }
                MachineRows.add(item, to: group)
            }
            let profileID = machine.profileID
            let add = MachineRows.link(MasterWords.newMaster, subtitle: Localized.text("From a skill on %@, or blank", machine.machine)) {
                mainWindow?.presentNewMaster(profileID: profileID)
            }
            MachineRows.prefix("＋", css: "accent", on: add)
            MachineRows.add(add, to: group)
            groups.append(group)
        }
        if !board.unanswered.isEmpty {
            let group = MachineRows.group(nil)
            for machine in board.unanswered {
                let row = MachineRows.row(machine.machine, subtitle: MasterWords.notAnswering(machine.machine))
                MachineRows.prefix("○", css: "dim-label", on: row)
                MachineRows.add(row, to: group)
            }
            groups.append(group)
        }
        if !others.isEmpty {
            let group = MachineRows.group(nil)
            for name in others {
                let row = MachineRows.row(name, subtitle: MasterWords.cannotKeep(name))
                Gtk.addClass(row, "dim-label")
                MachineRows.add(row, to: group)
            }
            groups.append(group)
        }
        showGroups(groups)
    }
}
