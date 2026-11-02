import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Ask later: five chips said the way people say them and a field for a phrase of one's own, with
/// what was understood always shown as a date before anything is saved — the state is Core's
/// `AskLaterSheet`, so this dialog says exactly what the phone and the Mac say. The machine keeps
/// what it makes; a machine that keeps no schedules is said to be one and offers no save.
final class AskLaterDialog: @unchecked Sendable {
    struct Target: Sendable {
        let profile: ConnectionProfile
        let backend: any CodingAgentBackend
        let model: ModelSelection?
        let effort: String?
        let directory: String?
        let sessionID: String?
    }

    enum Purpose {
        case create(Target, onSaved: @Sendable () -> Void)
        case rule(onPicked: @Sendable (ScheduleRule, String) -> Void)
    }

    nonisolated(unsafe) static var current: AskLaterDialog?

    var sheet: AskLaterSheet
    let purpose: Purpose
    var window: UnsafeMutablePointer<GtkWidget>?
    var chipButtons: [(AskLaterSheet.Chip, UnsafeMutablePointer<GtkWidget>)] = []
    var phraseEntry: UnsafeMutablePointer<GtkWidget>?
    var headline: UnsafeMutablePointer<GtkWidget>?
    var detail: UnsafeMutablePointer<GtkWidget>?
    var switches: UnsafeMutablePointer<GtkWidget>?
    var failureLabel: UnsafeMutablePointer<GtkWidget>?
    var confirmButton: UnsafeMutablePointer<GtkWidget>?
    var saving = false
    var syncingChips = false

    /// Opens the sheet for words about to be sent, on the machine and model they were aimed at.
    static func present(
        text: String, target: Target, parent: UnsafeMutablePointer<GtkWidget>?,
        onSaved: @escaping @Sendable () -> Void = {}
    ) {
        let parentBits = parent.map { UInt(bitPattern: $0) }
        Task {
            let keeps = await MachineFeatures.read(target.backend).schedules
            Gtk.onMain {
                let parent: UnsafeMutablePointer<GtkWidget>? = parentBits.flatMap {
                    UnsafeMutableRawPointer(bitPattern: $0).map { ptr($0) }
                }
                let modelWord = target.model.map {
                    ModelBadge.word(for: $0, in: ModelCatalogStore.cached(target.profile.id))
                }
                let sheet = AskLaterSheet(
                    text: text, machine: target.profile.name, modelWord: modelWord, machineKeepsSchedules: keeps)
                let dialog = AskLaterDialog(sheet: sheet, purpose: .create(target, onSaved: onSaved))
                dialog.build(parent: parent)
            }
        }
    }

    /// Opens the same chips and phrase to change when an existing schedule asks.
    static func presentRule(
        machine: String, title: String, parent: UnsafeMutablePointer<GtkWidget>?,
        onPicked: @escaping @Sendable (ScheduleRule, String) -> Void
    ) {
        let sheet = AskLaterSheet(text: title, machine: machine)
        let dialog = AskLaterDialog(sheet: sheet, purpose: .rule(onPicked: onPicked))
        dialog.build(parent: parent)
    }

    init(sheet: AskLaterSheet, purpose: Purpose) {
        self.sheet = sheet
        self.purpose = purpose
    }

    var isRuleOnly: Bool {
        if case .rule = purpose { return true }
        return false
    }

    func build(parent: UnsafeMutablePointer<GtkWidget>?) {
        let (window, content, actions) = Dialogs.windowWithActions(
            title: isRuleOnly ? Localized.text("Change when") : ScheduleWords.askLater, parent: parent, width: 520)
        self.window = window

        let quote = Gtk.label("\u{201C}\(sheet.text)\u{201D}", css: "row-detail", wrap: true, selectable: false)
        gtk_label_set_xalign(op(quote), 0)
        gtk_label_set_lines(op(quote), 3)
        gtk_label_set_ellipsize(op(quote), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(content), quote)

        var chips: [UnsafeMutablePointer<GtkWidget>] = []
        for chip in AskLaterSheet.Chip.allCases {
            let words = AskLaterSheet.words(chip)
            let title = [words.title, words.time].compactMap { $0 }.joined(separator: " ")
            let button = gtk_toggle_button_new_with_label(title)!
            gtk_toggle_button_set_active(ptr(button), sheet.chip == chip ? 1 : 0)
            let bits = UInt(bitPattern: button)
            Gtk.onNotify(UnsafeMutableRawPointer(button), property: "active") { [weak self] in
                guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                let on = gtk_toggle_button_get_active(ptr(raw)) != 0
                Gtk.onMain { [weak self] in self?.chipToggled(chip, on: on) }
            }
            chipButtons.append((chip, button))
            chips.append(button)
        }
        let once = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let repeats = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        for (index, chip) in chips.enumerated() {
            gtk_box_append(ptr(index < 3 ? once : repeats), chip)
        }
        gtk_box_append(ptr(content), once)
        gtk_box_append(ptr(content), repeats)

        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(entry), ScheduleWords.sayWhen)
        let entryBits = UInt(bitPattern: entry)
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") { [weak self] in
            guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits),
                let text = gtk_editable_get_text(op(raw))
            else { return }
            let typed = String(cString: text)
            Gtk.onMain { [weak self] in self?.typed(typed) }
        }
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.confirm() }
        }
        phraseEntry = entry
        gtk_box_append(ptr(content), entry)

        let understood = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(understood, "card")
        Gtk.margins(understood, top: 0, bottom: 0)
        let headline = Gtk.label("", css: "heading", wrap: true, selectable: false)
        let detail = Gtk.label("", css: "dim-label", wrap: true, selectable: false)
        for label in [headline, detail] {
            gtk_label_set_xalign(op(label), 0)
            Gtk.margins(label, top: 2, bottom: 2, leading: 12, trailing: 12)
            gtk_box_append(ptr(understood), label)
        }
        Gtk.margins(headline, top: 10, bottom: 0, leading: 12, trailing: 12)
        Gtk.margins(detail, top: 0, bottom: 10, leading: 12, trailing: 12)
        self.headline = headline
        self.detail = detail
        gtk_box_append(ptr(content), understood)

        if !isRuleOnly {
            let list = gtk_list_box_new()!
            Gtk.addClass(list, "boxed-list")
            gtk_list_box_set_selection_mode(op(list), GTK_SELECTION_NONE)
            gtk_list_box_append(op(list), SettingsRows.switchRow(
                title: ScheduleWords.oneConversation, subtitle: ScheduleWords.oneConversationDetail,
                value: sheet.oneConversation
            ) { [weak self] on in Gtk.onMain { [weak self] in self?.sheet.oneConversation = on } })
            gtk_list_box_append(op(list), SettingsRows.switchRow(
                title: ScheduleWords.quiet, subtitle: ScheduleWords.quietDetail, value: sheet.quiet
            ) { [weak self] on in Gtk.onMain { [weak self] in self?.sheet.quiet = on } })
            switches = list
            gtk_box_append(ptr(content), list)

            let reach = Gtk.label(
                sheet.machineKeepsSchedules
                    ? ScheduleWords.reach(sheet.machine) : ScheduleWords.cannotKeep(sheet.machine),
                css: sheet.machineKeepsSchedules ? "dim-label" : "fact-warn", wrap: true, selectable: false)
            gtk_label_set_xalign(op(reach), 0)
            gtk_box_append(ptr(content), reach)
        }

        let failure = Gtk.label("", css: "fact-bad", wrap: true, selectable: true)
        gtk_label_set_xalign(op(failure), 0)
        gtk_widget_set_visible(failure, 0)
        failureLabel = failure
        gtk_box_append(ptr(content), failure)

        let windowBits = UInt(bitPattern: window)
        gtk_box_append(
            ptr(actions),
            Gtk.button(Localized.text("Cancel"), css: ["flat"]) {
                guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
                gtk_window_destroy(ptr(raw))
            })
        let confirm = Gtk.button(ScheduleWords.askLater, css: ["suggested-action"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.confirm() }
        }
        confirmButton = confirm
        gtk_box_append(ptr(actions), confirm)

        Self.current = self
        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") {
            if Self.current?.window.map({ UInt(bitPattern: $0) }) == windowBits { Self.current = nil }
        }
        Gtk.observe(UnsafeMutableRawPointer(window), "destroy") {
            if Self.current?.window.map({ UInt(bitPattern: $0) }) == windowBits { Self.current = nil }
        }
        refresh()
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(entry)
    }

    func chipToggled(_ chip: AskLaterSheet.Chip, on: Bool) {
        guard !syncingChips else { return }
        if on {
            sheet.pick(chip)
            if let phraseEntry, !Dialogs.entryText(phraseEntry).isEmpty {
                syncingChips = true
                gtk_editable_set_text(op(phraseEntry), "")
                syncingChips = false
            }
        } else if sheet.chip == chip {
            sheet.chip = nil
        }
        refresh()
    }

    func typed(_ phrase: String) {
        guard !syncingChips else { return }
        sheet.type(phrase)
        refresh()
    }

    /// Puts a phrase in the field as if it had been typed, for the drive verb and the selftest.
    func type(_ phrase: String) {
        guard let phraseEntry else { return }
        gtk_editable_set_text(op(phraseEntry), phrase)
        typed(phrase)
    }

    func refresh() {
        syncingChips = true
        for (chip, button) in chipButtons {
            gtk_toggle_button_set_active(ptr(button), sheet.chip == chip ? 1 : 0)
        }
        syncingChips = false
        let line = sheet.understoodLine()
        if let headline {
            gtk_label_set_text(op(headline), line?.headline ?? Localized.text("Pick when, or say it"))
            Gtk.setTone(headline, line?.headline == ScheduleWords.notUnderstood ? "fact-warn" : nil, from: ["fact-warn"])
        }
        if let detail {
            let words = line?.detail ?? ""
            gtk_label_set_text(op(detail), words.isEmpty ? ScheduleWords.reach(sheet.machine) : words)
        }
        if let switches {
            let repeats = sheet.showsRepeatSwitches()
            gtk_widget_set_sensitive(switches, repeats ? 1 : 0)
            gtk_widget_set_tooltip_text(switches, repeats ? nil : Localized.text("Only a repeat runs more than once"))
        }
        if let confirmButton {
            let ready = sheet.understanding() != nil && (isRuleOnly || sheet.canSave) && !saving
            gtk_button_set_label(ptr(confirmButton), isRuleOnly ? Localized.text("Save") : sheet.confirmTitle())
            gtk_widget_set_sensitive(confirmButton, ready ? 1 : 0)
        }
    }

    func confirm() {
        guard !saving, let understood = sheet.understanding() else { return }
        switch purpose {
        case .rule(let onPicked):
            onPicked(understood.rule, TimeZone.current.identifier)
            closeWindow()
        case .create(let target, let onSaved):
            guard let scheduling = target.backend as? any MachineScheduling,
                let draft = sheet.draft(
                    model: target.model,
                    wireModel: target.model.map { QuickAskLaterHandoff.wireModel($0, backend: target.backend) },
                    effort: target.effort, directory: target.directory, sessionID: target.sessionID,
                    device: MachineFeatures.deviceName)
            else { return }
            saving = true
            refresh()
            let machine = sheet.machine
            let next = ScheduleWords.next(understood.next)
            Task { [weak self] in
                do {
                    _ = try await scheduling.createSchedule(draft)
                    Gtk.onMain { [weak self] in
                        self?.closeWindow()
                        onSaved()
                        mainWindow?.toast(Localized.text("Scheduled on %@ · %@", machine, next))
                        SchedulesWindow.refreshAll()
                    }
                } catch {
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.saving = false
                        if let failureLabel = self.failureLabel {
                            gtk_label_set_text(op(failureLabel), MachineWindow.words(error))
                            gtk_widget_set_visible(failureLabel, 1)
                        }
                        self.refresh()
                    }
                }
            }
        }
    }

    func closeWindow() {
        guard let window else { return }
        self.window = nil
        if Self.current === self { Self.current = nil }
        gtk_window_destroy(ptr(window))
    }
}
