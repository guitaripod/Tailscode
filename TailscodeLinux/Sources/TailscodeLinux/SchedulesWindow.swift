import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Scheduled: every machine's schedules soonest first, each row its words, when and where it
/// asks, and how its last run went. A row opens the schedule's own page. Read again every half
/// minute while open, so a run that lands shows here without anybody asking.
final class SchedulesWindow: MachineWindow, @unchecked Sendable {
    /// One machine's schedules only, when opened from that machine; nil is every machine.
    let profileID: String?
    var board: ScheduleBoard?
    var servers: [String: any CodingAgentBackend] = [:]
    var names: [String: String] = [:]
    var generation = 0

    static func key(_ profileID: String?) -> String { "scheduled·\(profileID ?? "all")" }

    static func present(profileID: String? = nil, parent: UnsafeMutablePointer<GtkWidget>?) {
        let window =
            (MachineWindowRegistry.existing(key(profileID)) as? SchedulesWindow)
            ?? SchedulesWindow(profileID: profileID)
        window.show(title: ScheduleWords.title, parent: parent, width: 560, height: 680)
    }

    init(profileID: String?) {
        self.profileID = profileID
        super.init(key: Self.key(profileID))
    }

    override func opened() {
        render()
        reload()
    }

    override func closed() {
        generation += 1
    }

    func reload() {
        generation += 1
        let mine = generation
        let only = profileID
        Task { [weak self] in
            let servers = await MachineFeatures.schedulingServers().filter { only == nil || $0.profile.id == only }
            let board = await ScheduleBoard.load(servers)
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen, mine == self.generation else { return }
                self.servers = Dictionary(servers.map { ($0.profile.id, $0.backend) }) { first, _ in first }
                self.names = Dictionary(servers.map { ($0.profile.id, $0.profile.name) }) { first, _ in first }
                self.board = board
                self.render()
                Gtk.after(30_000) { [weak self] in
                    guard let self, self.isOpen, mine == self.generation else { return }
                    self.reload()
                }
            }
        }
    }

    func render() {
        let group = MachineRows.group(
            profileID.flatMap { names[$0] }.map { Localized.text("Scheduled on %@", $0) } ?? nil,
            description: board?.homeLine())
        guard let board else {
            MachineRows.add(MachineRows.row(Localized.text("Asking every machine…")), to: group)
            replaceGroups([group])
            return
        }
        if board.isEmpty {
            let row = MachineRows.row(ScheduleWords.empty, subtitle: ScheduleWords.emptyDetail)
            MachineRows.prefix("◷", css: "dim-label", on: row)
            MachineRows.add(row, to: group)
        }
        for scheduleRow in board.rows {
            let row = MachineRows.row(scheduleRow.title, subtitle: scheduleRow.subtitle)
            MachineRows.prefix(ScheduleMark.waiting.glyph, css: "accent", on: row)
            let mark = Gtk.label(
                [scheduleRow.mark.glyph, scheduleRow.markWords].compactMap { $0 }.joined(separator: " "),
                css: MachineRows.markCSS(scheduleRow.mark), selectable: false)
            gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(ptr(row), mark)
            let chevron = Gtk.label("›", css: "dim-label", selectable: false)
            gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(ptr(row), chevron)
            gtk_list_box_row_set_activatable(ptr(row), 1)
            if scheduleRow.schedule.paused { Gtk.addClass(row, "dim-label") }
            let profile = scheduleRow.profileID
            let id = scheduleRow.schedule.id
            Gtk.connect(UnsafeMutableRawPointer(row), "activated") { [weak self] in
                Gtk.onMain { [weak self] in self?.open(profileID: profile, scheduleID: id) }
            }
            MachineRows.add(row, to: group)
        }
        replaceGroups([group])
    }

    func open(profileID: String, scheduleID: String) {
        guard let backend = servers[profileID],
            let row = board?.rows.first(where: { $0.profileID == profileID && $0.schedule.id == scheduleID })
        else { return }
        ScheduleDetailWindow.present(
            profileID: profileID, machine: row.machine, backend: backend, schedule: row.schedule, parent: window)
    }

    /// Every open Scheduled window, and the sidebar's line, read the machines again.
    static func refreshAll() {
        for window in MachineWindowRegistry.all(SchedulesWindow.self) { window.reload() }
        mainWindow?.refreshScheduleLine()
    }
}
