import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MasterEditorWindow {
    func addBenchItem() {
        let (dialog, content) = Dialogs.window(title: MasterWords.addBenchItem, parent: window, width: 460)
        let kinds: [ExpertBenchItem.Kind] = [.appleDevice, .command, .port]
        let kindNames = [Localized.text("An iPhone, iPad or other Apple device"), Localized.text("A command that proves it"), Localized.text("A port that answers")]
        let picked = MasterDialogValue(0)
        let list = gtk_list_box_new()!
        Gtk.addClass(list, "boxed-list")
        gtk_list_box_set_selection_mode(op(list), GTK_SELECTION_NONE)
        gtk_list_box_append(op(list), SettingsRows.comboRow(title: Localized.text("Kind"), subtitle: nil, options: kindNames, selected: 0) { picked.value = $0 })
        let fields = ["name", "identifier", "command", "host", "port", "lock"]
        let titles = [
            MasterWords.name, Localized.text("UDID, device identifier or name"), Localized.text("Command (exits 0 when it is there)"),
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
        let (dialog, content) = Dialogs.window(title: MasterWords.addGuard, parent: window, width: 480)
        let note = Gtk.label(MasterWords.noGuards, css: "row-detail", wrap: true, selectable: false)
        gtk_label_set_xalign(op(note), 0)
        gtk_box_append(ptr(content), note)
        let list = gtk_list_box_new()!
        Gtk.addClass(list, "boxed-list")
        gtk_list_box_set_selection_mode(op(list), GTK_SELECTION_NONE)
        let fields = ["name", "command", "directory", "pattern", "atMost", "atLeast", "unit", "timeout"]
        let titles = [
            MasterWords.name, Localized.text("Command"), MasterWords.folder,
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

    func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast(Localized.text("A master needs a name."))
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
                name: trimmed, glyph: shownGlyph, hue: hue.rawValue, purpose: purpose, directory: directory, model: model,
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
                MasterDesk.shared.refresh()
                Gtk.onMain { [weak self] in self?.saved(outcome, profileID: profileID, machine: machine) }
            }
        case .new, .draft:
            var draft = typed
            draft.name = trimmed
            draft.hue = hue.rawValue
            let final = MasterMaking.finalized(draft, keeping: ticks)
            Task { [weak self] in
                let outcome: Result<MachineExpert, Error>
                do {
                    outcome = .success(try await keeper.createExpert(final))
                } catch {
                    outcome = .failure(error)
                }
                MasterDesk.shared.refresh()
                Gtk.onMain { [weak self] in self?.saved(outcome, profileID: profileID, machine: machine) }
            }
        }
    }

    private func saved(_ outcome: Result<MachineExpert, Error>, profileID: String, machine: String) {
        saving = false
        switch outcome {
        case .success(let master):
            MasterDesk.shared.refresh()
            let parent = window
            let editing = isEdit
            close()
            if !editing {
                MasterWindow.present(row: MasterRow(profileID: profileID, machine: machine, master: master), parent: parent)
            } else if let page = MachineWindowRegistry.existing(MasterWindow.key(profileID, master.id)) as? MasterWindow {
                page.master = master
                page.render()
            }
        case .failure(let error):
            toast(Self.words(error))
            render()
        }
    }
}

/// A value a closure can change, for a dialog's own small state.
final class MasterDialogValue<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
