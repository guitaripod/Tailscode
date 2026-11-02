import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// A schedule's own page: its words (editable), when it asks (changed with the same chips and
/// phrase as Ask later), its two switches, Run now, Pause, Delete — its conversations stay — and
/// its history, each run in Core's words and one press from the conversation it ran in.
final class ScheduleDetailWindow: MachineWindow, @unchecked Sendable {
    let profileID: String
    let machine: String
    let backend: any CodingAgentBackend
    var schedule: MachineSchedule
    var busy = false

    static func key(_ profileID: String, _ scheduleID: String) -> String { "schedule·\(profileID)·\(scheduleID)" }

    static func present(
        profileID: String, machine: String, backend: any CodingAgentBackend, schedule: MachineSchedule,
        parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        let existing = MachineWindowRegistry.existing(key(profileID, schedule.id)) as? ScheduleDetailWindow
        let window =
            existing
            ?? ScheduleDetailWindow(profileID: profileID, machine: machine, backend: backend, schedule: schedule)
        window.show(title: schedule.title, parent: parent, width: 560, height: 720)
    }

    init(profileID: String, machine: String, backend: any CodingAgentBackend, schedule: MachineSchedule) {
        self.profileID = profileID
        self.machine = machine
        self.backend = backend
        self.schedule = schedule
        super.init(key: Self.key(profileID, schedule.id))
    }

    var scheduling: (any MachineScheduling)? { backend as? any MachineScheduling }

    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: schedule.timeZone) ?? .current
        return calendar
    }

    override func opened() {
        render()
        reload()
        Gtk.after(80) { [weak self] in
            guard let self, let window = self.window else { return }
            gtk_window_set_focus(ptr(window), nil)
        }
    }

    func reload() {
        guard let scheduling else { return }
        let id = schedule.id
        Task { [weak self] in
            let all = try? await scheduling.machineSchedules()
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen else { return }
                guard let fresh = all?.first(where: { $0.id == id }) else {
                    if all != nil { self.close() }
                    return
                }
                self.schedule = fresh
                self.render()
            }
        }
    }

    func render() {
        if let window { gtk_window_set_title(ptr(window), schedule.title) }
        replaceGroups([wordsGroup(), whenGroup(), actionsGroup(), historyGroup()])
    }

    private func wordsGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let text = adw_entry_row_new()!
        adw_preferences_row_set_use_markup(ptr(text), 0)
        adw_preferences_row_set_title(ptr(text), Localized.text("What it asks"))
        gtk_editable_set_text(op(text), schedule.text)
        adw_entry_row_set_show_apply_button(ptr(text), 1)
        let textBits = UInt(bitPattern: text)
        Gtk.connect(UnsafeMutableRawPointer(text), "apply") { [weak self] in
            guard let raw = UnsafeMutableRawPointer(bitPattern: textBits) else { return }
            let words = Dialogs.entryText(ptr(raw))
            Gtk.onMain { [weak self] in
                guard let self, !words.isEmpty, words != self.schedule.text else { return }
                self.change(ScheduleChange(text: words), done: Localized.text("Saved"))
            }
        }
        MachineRows.add(text, to: group)
        var facts = [machine]
        if let model = schedule.model { facts.append(Self.modelWords(model, profileID: profileID)) }
        if let effort = schedule.effort { facts.append(effort) }
        if let maker = schedule.createdBy { facts.append(Localized.text("made on %@", maker)) }
        MachineRows.add(MachineRows.row(Localized.text("Asked by"), subtitle: facts.joined(separator: " · ")), to: group)
        return group
    }

    /// The model as the pill would name it, read from what the machine last listed.
    static func modelWords(_ wire: String, profileID: String) -> String {
        let catalog = ModelCatalogStore.cached(profileID)
        if let slash = wire.firstIndex(of: "/") {
            let provider = String(wire[..<slash])
            let model = String(wire[wire.index(after: slash)...])
            if catalog.contains(where: { $0.providerID == provider && $0.id == model }) {
                return ModelBadge.word(for: ModelSelection(providerID: provider, modelID: model), in: catalog)
            }
        }
        if let row = catalog.first(where: { $0.id == wire }) { return ModelBadge.word(for: row.selection, in: catalog) }
        return wire
    }

    private func whenGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(Localized.text("When"))
        let when: String
        if schedule.isFinished {
            when = ScheduleWords.done
        } else if schedule.paused {
            when = ScheduleWords.paused + " · " + ScheduleWords.when(schedule.rule, calendar: calendar)
        } else {
            when = ScheduleWords.when(schedule.rule, calendar: calendar)
        }
        let next = schedule.next.map { ScheduleWords.next($0, calendar: calendar) }
        let row = MachineRows.row(when, subtitle: next)
        MachineRows.prefix("◷", css: "accent", on: row)
        MachineRows.suffixButton(Localized.text("Change…"), sensitive: !busy, on: row) { [weak self] in
            self?.changeWhen()
        }
        MachineRows.add(row, to: group)
        if schedule.rule.isRepeating {
            let conversation = SettingsRows.switchRow(
                title: ScheduleWords.oneConversation, subtitle: ScheduleWords.oneConversationDetail,
                value: schedule.thread == .continue
            ) { [weak self] on in
                Gtk.onMain { [weak self] in
                    guard let self, (self.schedule.thread == .continue) != on else { return }
                    self.change(ScheduleChange(thread: on ? .continue : .fresh), done: nil)
                }
            }
            MachineRows.add(conversation, to: group)
            let quiet = SettingsRows.switchRow(
                title: ScheduleWords.quiet, subtitle: ScheduleWords.quietDetail, value: schedule.quiet
            ) { [weak self] on in
                Gtk.onMain { [weak self] in
                    guard let self, self.schedule.quiet != on else { return }
                    self.change(ScheduleChange(quiet: on), done: nil)
                }
            }
            MachineRows.add(quiet, to: group)
        }
        return group
    }

    private func actionsGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let run = Gtk.button(ScheduleWords.runNow, css: ["suggested-action"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.runNow() }
        }
        let pause = Gtk.button(
            schedule.paused ? ScheduleWords.resume : ScheduleWords.pause, css: []
        ) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.change(
                    ScheduleChange(paused: !self.schedule.paused),
                    done: self.schedule.paused ? ScheduleWords.resume : ScheduleWords.paused)
            }
        }
        for button in [run, pause] {
            gtk_widget_set_sensitive(button, busy ? 0 : 1)
            gtk_box_append(ptr(buttons), button)
        }
        if let sessionID = schedule.sessionID ?? schedule.runs.first?.sessionID {
            gtk_box_append(
                ptr(buttons),
                Gtk.button(ScheduleWords.openConversation, css: ["flat"]) {
                    Gtk.onMain { mainWindow?.openSession(withID: sessionID) }
                })
        }
        MachineRows.add(MachineRows.wrapped(buttons, margin: 8), to: group)
        let delete = MachineRows.row(ScheduleWords.delete, subtitle: ScheduleWords.deleteDetail)
        MachineRows.suffixButton(Localized.text("Delete"), css: ["destructive-action"], sensitive: !busy, on: delete) {
            [weak self] in
            self?.confirmDelete()
        }
        MachineRows.add(delete, to: group)
        return group
    }

    private func historyGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(ScheduleWords.history)
        if schedule.runs.isEmpty {
            MachineRows.add(MachineRows.row(ScheduleWords.noHistory), to: group)
        }
        for run in schedule.runs {
            let reading = ScheduleWords.run(run, machine: machine, calendar: calendar)
            let row = MachineRows.row(reading.title, subtitle: reading.detail)
            MachineRows.prefix(reading.mark.glyph, css: MachineRows.markCSS(reading.mark), on: row)
            if let sessionID = run.sessionID {
                MachineRows.suffixButton(Localized.text("Open"), on: row) {
                    mainWindow?.openSession(withID: sessionID)
                }
            }
            MachineRows.add(row, to: group)
        }
        return group
    }

    func changeWhen() {
        AskLaterDialog.presentRule(
            machine: machine, title: schedule.title, parent: window
        ) { [weak self] rule, zone in
            Gtk.onMain { [weak self] in
                self?.change(ScheduleChange(rule: rule, timeZone: zone), done: Localized.text("Saved"))
            }
        }
    }

    func change(_ change: ScheduleChange, done: String?) {
        guard let scheduling, !busy else { return }
        busy = true
        render()
        let id = schedule.id
        Task { [weak self] in
            let outcome: Result<MachineSchedule, Error>
            do {
                outcome = .success(try await scheduling.updateSchedule(id, change))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let fresh):
                    self.schedule = fresh
                    if let done { self.toast(done) }
                case .failure(let error):
                    self.toast(Self.words(error))
                }
                self.render()
                SchedulesWindow.refreshAll()
            }
        }
    }

    func runNow() {
        guard let scheduling, !busy else { return }
        busy = true
        render()
        let id = schedule.id
        Task { [weak self] in
            let outcome: Result<MachineSchedule, Error>
            do {
                outcome = .success(try await scheduling.runSchedule(id))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let fresh):
                    self.schedule = fresh
                    self.toast(Localized.text("Asked on %@", self.machine))
                case .failure(let error):
                    self.toast(Self.words(error))
                }
                self.render()
                SchedulesWindow.refreshAll()
                Gtk.after(4_000) { [weak self] in self?.reload() }
            }
        }
    }

    func confirmDelete() {
        Dialogs.confirm(
            title: ScheduleWords.delete + "?", body: schedule.title + "\n\n" + ScheduleWords.deleteDetail,
            confirmLabel: Localized.text("Delete"), parent: window
        ) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let scheduling = self.scheduling else { return }
                let id = self.schedule.id
                Task { [weak self] in
                    do {
                        try await scheduling.deleteSchedule(id)
                        Gtk.onMain { [weak self] in
                            SchedulesWindow.refreshAll()
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
