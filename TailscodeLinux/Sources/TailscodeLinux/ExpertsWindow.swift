import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Experts: every machine's experts, each machine its own group in the order the person keeps
/// them, each expert its mark, its name and its one state line, opening its page. A machine that
/// keeps experts offers New expert; one that cannot is said to be one.
final class ExpertsWindow: MachineWindow, @unchecked Sendable {
    static let windowKey = "experts·all"
    var watch: NSObjectProtocol?
    var servers: [(id: String, name: String)] = []

    /// The machines that answered without keeping experts: opencode, omp-bridge, a claude-bridge
    /// too old for them. One that keeps experts but is not answering is said to be not answering,
    /// never to be one that cannot.
    var others: [String] {
        let board = ExpertDesk.shared.board
        let known = Set(board.machines.map(\.profileID) + board.unanswered.map(\.profileID))
        return servers.filter { !known.contains($0.id) }.map(\.name)
    }

    static func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        let window = (MachineWindowRegistry.existing(windowKey) as? ExpertsWindow) ?? ExpertsWindow()
        window.show(title: ExpertWords.title, parent: parent, width: 560, height: 680)
    }

    init() {
        super.init(key: Self.windowKey)
    }

    override func opened() {
        watch = NotificationCenter.default.addObserver(forName: ExpertDesk.didChange, object: nil, queue: nil) {
            [weak self] _ in
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                self.render()
            }
        }
        ExpertDesk.shared.watch(key)
        ExpertDesk.shared.refresh()
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
        ExpertDesk.shared.unwatch(key)
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
    }

    func render() {
        let board = ExpertDesk.shared.board
        var groups: [UnsafeMutablePointer<GtkWidget>] = []
        if !ExpertDesk.shared.loadedOnce {
            let group = MachineRows.group(nil)
            MachineRows.add(MachineRows.row(Localized.text("Asking every machine…")), to: group)
            replaceGroups([group])
            return
        }
        if board.isEmpty, !board.machines.isEmpty || board.unanswered.isEmpty {
            let group = MachineRows.group(nil)
            let row = MachineRows.row(ExpertWords.empty, subtitle: ExpertWords.emptyDetail)
            MachineRows.prefix("✦", css: "accent", on: row)
            MachineRows.add(row, to: group)
            groups.append(group)
        }
        for machine in board.machines {
            let group = MachineRows.group(board.machines.count > 1 || !board.isEmpty ? machine.machine : nil)
            for row in board.rows where row.profileID == machine.profileID {
                let state = row.state()
                let item = MachineRows.row(
                    row.expert.name, subtitle: state.text, subtitleCSS: ExpertMarks.lineClass(state.tone))
                adw_action_row_add_prefix(ptr(item), ExpertMarks.mark(row.expert, size: .row))
                if let badge = ExpertReading.badge(row.expert) {
                    let count = Gtk.label("\(badge)", css: "expert-badge", selectable: false)
                    gtk_widget_set_valign(count, GTK_ALIGN_CENTER)
                    adw_action_row_add_suffix(ptr(item), count)
                }
                let chevron = Gtk.label("›", css: "dim-label", selectable: false)
                gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
                adw_action_row_add_suffix(ptr(item), chevron)
                gtk_list_box_row_set_activatable(ptr(item), 1)
                tailscode_set_accessible_label(item, [row.expert.name, state.text].joined(separator: ", "))
                Gtk.connect(UnsafeMutableRawPointer(item), "activated") { [weak self] in
                    Gtk.onMain { [weak self] in ExpertWindow.present(row: row, parent: self?.window) }
                }
                MachineRows.add(item, to: group)
            }
            let profileID = machine.profileID
            let add = MachineRows.link(ExpertWords.newExpert, subtitle: Localized.text("From a skill on %@, or blank", machine.machine)) {
                mainWindow?.presentNewExpert(profileID: profileID)
            }
            MachineRows.prefix("＋", css: "accent", on: add)
            MachineRows.add(add, to: group)
            groups.append(group)
        }
        if !board.unanswered.isEmpty {
            let group = MachineRows.group(nil)
            for machine in board.unanswered {
                let row = MachineRows.row(machine.machine, subtitle: ExpertWords.notAnswering(machine.machine))
                MachineRows.prefix("○", css: "dim-label", on: row)
                MachineRows.add(row, to: group)
            }
            groups.append(group)
        }
        if !others.isEmpty {
            let group = MachineRows.group(nil)
            for name in others {
                let row = MachineRows.row(name, subtitle: ExpertWords.cannotKeep(name))
                Gtk.addClass(row, "dim-label")
                MachineRows.add(row, to: group)
            }
            groups.append(group)
        }
        replaceGroups(groups)
    }
}
