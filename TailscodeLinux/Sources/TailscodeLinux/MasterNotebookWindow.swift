import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// A master's notebook: one row per note — its title, its first line, when it was written or
/// last confirmed and the task it came from, a tag on one nobody has confirmed for two months —
/// searchable, a press reading the whole note; the retired notes folded at the foot with their
/// reasons, never deleted.
final class MasterNotebookWindow: MachineWindow, @unchecked Sendable {
    var row: MasterRow
    let keeper: any MachineExperts
    var notes: [ExpertNote]?
    var retired: [ExpertNote] = []
    /// Why the notebook could not be read, said instead of an empty notebook it is not.
    var failure: String?
    var watch: NSObjectProtocol?

    static func key(_ row: MasterRow) -> String { "notebook·\(row.profileID)·\(row.master.id)" }

    static func present(row: MasterRow, keeper: any MachineExperts, parent: UnsafeMutablePointer<GtkWidget>?) {
        let window =
            (MachineWindowRegistry.existing(key(row)) as? MasterNotebookWindow)
            ?? MasterNotebookWindow(row: row, keeper: keeper)
        window.show(title: row.master.name + " · " + MasterWords.notebook, parent: parent, width: 600, height: 760)
    }

    init(row: MasterRow, keeper: any MachineExperts) {
        self.row = row
        self.keeper = keeper
        super.init(key: Self.key(row))
    }

    override func opened() {
        if let window { adw_preferences_window_set_search_enabled(ptr(window), 1) }
        watch = NotificationCenter.default.addObserver(forName: MasterDesk.didChange, object: nil, queue: nil) {
            [weak self] _ in
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                if let fresh = MasterDesk.shared.row(profileID: self.row.profileID, expertID: self.row.master.id) {
                    let moved = fresh.master.notebook != self.row.master.notebook
                    self.row = fresh
                    if moved { self.reload() }
                }
            }
        }
        MasterDesk.shared.watch(key)
        render()
        reload()
    }

    override func closed() {
        MasterDesk.shared.unwatch(key)
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
    }

    func reload() {
        let id = row.master.id
        let keeper = self.keeper
        let machine = row.machine
        Task { [weak self] in
            let read: Result<(live: [ExpertNote], gone: [ExpertNote]), Error>
            do {
                let live = try await keeper.expertNotes(id, retired: false)
                let gone = try await keeper.expertNotes(id, retired: true)
                read = .success((live, gone))
            } catch {
                read = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                switch read {
                case .success(let notes):
                    self.notes = notes.live
                    self.retired = notes.gone
                    self.failure = nil
                case .failure(let error):
                    self.failure = MasterWords.notAnswering(machine) + " · " + Self.words(error)
                }
                self.render()
            }
        }
    }

    /// The titles of the tasks the notes came from, from what the master last said about its tasks.
    private var taskTitles: [String: String] {
        var titles: [String: String] = [:]
        for task in row.master.tasks { titles[task.sessionID] = task.title }
        for entry in row.master.journal { if let id = entry.sessionID { titles[id] = entry.title } }
        return titles
    }

    func render() {
        let facts = row.master.notebook
        let group = MachineRows.group(
            MasterReading.notebookLine(row.master).text, description: MasterReading.shortPath(facts.path))
        if let failure {
            MachineRows.add(MachineRows.row(failure, subtitleCSS: "fact-bad"), to: group)
            if notes == nil {
                replaceGroups([group])
                return
            }
        }
        guard let notes else {
            MachineRows.add(MachineRows.row(Localized.text("Reading the notebook…")), to: group)
            replaceGroups([group])
            return
        }
        if notes.isEmpty {
            MachineRows.add(MachineRows.row(MasterWords.noNotes, subtitleCSS: "dim-label"), to: group)
        }
        let titles = taskTitles
        for note in notes {
            let reading = MasterReading.noteRow(note, taskTitles: titles)
            let item = MasterMarks.row(reading)
            gtk_list_box_row_set_activatable(ptr(item), 1)
            let id = note.id
            Gtk.connect(UnsafeMutableRawPointer(item), "activated") { [weak self] in
                Gtk.onMain { [weak self] in self?.read(id) }
            }
            MachineRows.add(item, to: group)
        }
        var groups = [group]
        if !retired.isEmpty {
            let fold = MachineRows.group(nil)
            let expander = adw_expander_row_new()!
            adw_preferences_row_set_title(ptr(expander), MasterWords.retired + " · \(retired.count)")
            adw_expander_row_set_subtitle(
                ptr(expander), Localized.text("Kept with their reasons, so a later task does not take them for true"))
            for note in retired {
                let reading = MasterReading.noteRow(note)
                let item = MachineRows.row(reading.title, subtitle: reading.detail.text)
                Gtk.addClass(item, "master-note-retired")
                gtk_list_box_row_set_activatable(ptr(item), 1)
                let id = note.id
                Gtk.connect(UnsafeMutableRawPointer(item), "activated") { [weak self] in
                    Gtk.onMain { [weak self] in self?.read(id) }
                }
                adw_expander_row_add_row(ptr(expander), item)
            }
            MachineRows.add(expander, to: fold)
            groups.append(fold)
        }
        replaceGroups(groups)
    }

    func read(_ noteID: String) {
        let id = row.master.id
        let keeper = self.keeper
        Task { [weak self] in
            let note = try? await keeper.expertNote(id, note: noteID)
            Gtk.onMain { [weak self] in
                guard let self, let note else { return }
                var subtitle = [note.summary]
                if let retired = note.retired, let reason = retired.reason {
                    subtitle.append(Localized.text("Retired: %@", reason))
                }
                Dialogs.reader(
                    title: note.title, subtitle: subtitle.filter { !$0.isEmpty }.joined(separator: "\n"),
                    body: note.body ?? note.summary, parent: self.window)
            }
        }
    }
}
