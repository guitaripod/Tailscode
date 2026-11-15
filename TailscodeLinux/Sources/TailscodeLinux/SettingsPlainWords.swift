import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The one row whose subtitle says how a check of the server went, held so the answer can be
/// written to it after the request comes back.
final class PlainWordsCheckHeld: @unchecked Sendable {
    var hold: Gtk.WeakWidget?
}

/// Plain words: the opt-in that lets a model the person runs themselves say the few commands the
/// built-in rules could not read. Off until the switch is turned on, and then nothing to type: the
/// model row finds a model on this machine, proves it with one line and uses it, and asks before
/// starting one that a server would have to stop another model for. A server elsewhere on the
/// network is an address under Another server, vetted as it is typed. The wall rebuilds its model
/// from the settings after every change.
enum SettingsPlainWords {
    static func add(to page: UnsafeMutablePointer<GtkWidget>) {
        let group = SettingsRows.group(Localized.text("Plain words"), on: page)
        let setup = PlainWordsSetup()
        SettingsRows.keep(setup, alive: group)
        let toggle = SettingsRows.switchRow(
            title: Localized.text("Let a local model say unusual commands"),
            subtitle: Localized.text(
                "Off by default. Only a command the built-in rules could not read is sent, as text with secrets taken out, to a model on this machine or your private network. Lines it writes are marked ✦. Never used for approvals."
            ),
            value: Preferences.plainWords
        ) { [setup] value in
            Preferences.setPlainWords(value)
            changed()
            Gtk.onMain { setup.switched(on: value) }
        }
        adw_action_row_set_subtitle_lines(ptr(toggle), 0)
        SettingsRows.add(toggle, to: group)
        SettingsRows.add(setup.build(), to: group)

        let other = adw_expander_row_new()!
        adw_preferences_row_set_title(ptr(other), Localized.text("Another server"))
        adw_expander_row_set_subtitle(ptr(other), Localized.text("A model on another machine of yours, by its address"))
        let address = entryRow(
            title: Localized.text("Server address"), placeholder: Localized.text("http://127.0.0.1:8080/v1"),
            text: Preferences.plainWordsAddress
        ) { [setup] text, row in
            Preferences.setPlainWordsAddress(text)
            judge(text, on: row)
            setup.typed()
            changed()
        }
        judge(Preferences.plainWordsAddress, on: address)
        adw_expander_row_add_row(ptr(other), address)
        let model = entryRow(
            title: Localized.text("Model"), placeholder: Localized.text("First one the server lists"),
            text: Preferences.plainWordsModel
        ) { [setup] text, _ in
            Preferences.setPlainWordsModel(text)
            setup.typed()
            changed()
        }
        adw_expander_row_add_row(ptr(other), model)
        setup.entries = (Gtk.WeakWidget(address), Gtk.WeakWidget(model))
        let held = PlainWordsCheckHeld()
        let check = SettingsRows.buttonRow(
            Localized.text("Check"), label: Localized.text("Check")
        ) {
            Gtk.onMain { runCheck(held) }
        }
        held.hold = Gtk.WeakWidget(check)
        adw_expander_row_add_row(ptr(other), check)
        adw_expander_row_set_expanded(ptr(other), Preferences.plainWordsFound ? 0 : (Preferences.plainWordsAddress.isEmpty ? 0 : 1))
        SettingsRows.add(other, to: group)
        setup.opened()
    }

    static func changed() {
        Gtk.onMain { AgentsWindow.current?.plainWordsChanged() }
    }

    static func entryRow(
        title: String, placeholder: String, text: String,
        onChange: @escaping @Sendable (String, UnsafeMutablePointer<GtkWidget>) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(entry), placeholder)
        gtk_editable_set_text(op(entry), text)
        gtk_editable_set_width_chars(op(entry), 30)
        gtk_widget_set_valign(entry, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), entry)
        adw_action_row_set_activatable_widget(ptr(row), entry)
        g_object_set_data(UnsafeMutableRawPointer(row).assumingMemoryBound(to: GObject.self), "tailscode-entry", entry)
        let entryBits = UInt(bitPattern: entry)
        let rowBits = UInt(bitPattern: row)
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") {
            guard let entry = UnsafeMutablePointer<GtkWidget>(bitPattern: entryBits),
                let row = UnsafeMutablePointer<GtkWidget>(bitPattern: rowBits),
                let raw = gtk_editable_get_text(op(entry))
            else { return }
            guard g_object_get_data(UnsafeMutableRawPointer(entry).assumingMemoryBound(to: GObject.self), "tailscode-quiet") == nil
            else { return }
            onChange(String(cString: raw), row)
        }
        return row
    }

    /// Writes what the finder chose into an entry row without it counting as the person typing.
    static func fill(_ row: UnsafeMutablePointer<GtkWidget>?, _ text: String) {
        guard let row,
            let raw = g_object_get_data(UnsafeMutableRawPointer(row).assumingMemoryBound(to: GObject.self), "tailscode-entry")
        else { return }
        let entry = raw.assumingMemoryBound(to: GtkWidget.self)
        let object = UnsafeMutableRawPointer(entry).assumingMemoryBound(to: GObject.self)
        g_object_set_data(object, "tailscode-quiet", UnsafeMutableRawPointer(bitPattern: 1))
        gtk_editable_set_text(op(entry), text)
        g_object_set_data(object, "tailscode-quiet", nil)
        judge(text, on: row)
    }

    /// Marks the address row when what was typed is not on this machine or the person's network.
    static func judge(_ text: String, on row: UnsafeMutablePointer<GtkWidget>) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let refused = !trimmed.isEmpty && PlainModel.endpoint(trimmed) == nil
        adw_action_row_set_subtitle(ptr(row), refused ? Localized.text("Not on this machine or your network") : "")
        if refused {
            gtk_widget_add_css_class(row, "error")
        } else {
            gtk_widget_remove_css_class(row, "error")
        }
    }

    private static func runCheck(_ held: PlainWordsCheckHeld) {
        guard let widget = held.hold?.widget else { return }
        guard let endpoint = PlainModel.endpoint(Preferences.plainWordsAddress) else {
            adw_action_row_set_subtitle(ptr(widget), Localized.text("Not on this machine or your network"))
            return
        }
        adw_action_row_set_subtitle(ptr(widget), Localized.text("Checking…"))
        Task {
            let result = await PlainWordsModel.check(endpoint: endpoint)
            Gtk.onMain {
                guard let widget = held.hold?.widget else { return }
                adw_action_row_set_subtitle(ptr(widget), reading(result))
            }
        }
    }

    static func reading(_ result: Result<[String], Error>) -> String {
        guard case .success(let ids) = result else { return Localized.text("Could not reach it") }
        return ids.count == 1
            ? Localized.text("Reachable · 1 model") : Localized.text("Reachable · %d models", ids.count)
    }
}

/// The model row and what it is doing: idle, looking, using a model it proved, or asking before
/// one is started. It keeps nothing but weak handles on its widgets and the model it asks about.
final class PlainWordsSetup: @unchecked Sendable {
    private var row: Gtk.WeakWidget?
    private var spinner: Gtk.WeakWidget?
    private var button: Gtk.WeakWidget?
    var entries: (address: Gtk.WeakWidget, model: Gtk.WeakWidget)?
    private var asking: PlainModelScout.Model?
    private var looking = false
    private(set) var outcome: PlainWordsScout.Outcome?
    var scout: () -> PlainWordsScout = { PlainWordsScout() }

    func build() -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_action_row_set_subtitle_lines(ptr(row), 0)
        let spinner = gtk_spinner_new()!
        gtk_widget_set_valign(spinner, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(spinner, 0)
        adw_action_row_add_suffix(ptr(row), spinner)
        let button = Gtk.button(Localized.text("Find"), css: ["flat"]) { [self] in
            Gtk.onMain { self.pressed() }
        }
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), button)
        self.row = Gtk.WeakWidget(row)
        self.spinner = Gtk.WeakWidget(spinner)
        self.button = Gtk.WeakWidget(button)
        return row
    }

    /// What the row says when the page opens: the model in use, or that one will be found.
    func opened() {
        if Preferences.plainWords, Preferences.plainWordsAddress.isEmpty {
            find()
            return
        }
        if !Preferences.plainWordsAddress.isEmpty {
            let label = Preferences.plainWordsLabel
            show(
                title: label.isEmpty ? Localized.text("Model") : label,
                subtitle: Localized.text("Using %@", Self.place(Preferences.plainWordsAddress, Preferences.plainWordsModel)),
                button: Localized.text("Find again"))
            return
        }
        show(
            title: Localized.text("Model"),
            subtitle: Localized.text("Turn the switch on and a model on this machine is found and tried"),
            button: Localized.text("Find"))
    }

    func switched(on: Bool) {
        guard on, Preferences.plainWordsAddress.isEmpty, !looking else { return }
        find()
    }

    /// The person typed an address or a model: that is theirs now, and the row says so.
    func typed() {
        Preferences.setPlainWordsFound(label: nil)
        asking = nil
        guard !looking else { return }
        let address = Preferences.plainWordsAddress
        show(
            title: Localized.text("Model"),
            subtitle: address.isEmpty
                ? Localized.text("Turn the switch on and a model on this machine is found and tried")
                : Localized.text("Using %@", Self.place(address, Preferences.plainWordsModel)),
            button: Localized.text("Find again"))
    }

    private func pressed() {
        if let model = asking {
            start(model)
        } else {
            find()
        }
    }

    func find() {
        guard !looking else { return }
        looking = true
        asking = nil
        show(title: Localized.text("Model"), subtitle: Localized.text("Looking on this machine…"), button: nil)
        let scout = scout()
        Task { [self] in
            let outcome = await scout.settle()
            Gtk.onMain { self.landed(outcome) }
        }
    }

    private func start(_ model: PlainModelScout.Model) {
        guard !looking else { return }
        looking = true
        asking = nil
        show(
            title: Self.label(model), subtitle: Localized.text("Starting it and asking for one line…"), button: nil)
        let scout = scout()
        Task { [self] in
            let outcome = await scout.start(model)
            Gtk.onMain { self.landed(outcome) }
        }
    }

    func landed(_ outcome: PlainWordsScout.Outcome) {
        looking = false
        self.outcome = outcome
        switch outcome {
        case .ready(let model, let line, let seconds):
            let label = Self.label(model)
            Preferences.setPlainWordsAddress(model.base.absoluteString)
            Preferences.setPlainWordsModel(model.id)
            Preferences.setPlainWordsFound(label: label)
            if let entries {
                SettingsPlainWords.fill(entries.address.widget, model.base.absoluteString)
                SettingsPlainWords.fill(entries.model.widget, model.id)
            }
            show(
                title: label,
                subtitle: Localized.text(
                    "Answers in %@ s: “%@”", String(format: seconds < 1 ? "%.2f" : "%.1f", seconds), line),
                button: Localized.text("Find again"))
            SettingsPlainWords.changed()
        case .ask(let model):
            asking = model
            show(
                title: Self.label(model),
                subtitle: Localized.text(
                    "Not running yet. %@ starts it when asked, and may stop another model to make room unless the two share a group.",
                    model.kind.title),
                button: Localized.text("Start it"))
        case .silent(let servers):
            show(
                title: Localized.text("No model wrote one plain line"),
                subtitle: Localized.text(
                    "%@ answered, but none of its models wrote one plain line. Load a small instruct model there, or give an address under Another server.",
                    servers.joined(separator: ", ")),
                button: Localized.text("Find again"))
        case .none:
            show(
                title: Localized.text("No model server on this machine"),
                subtitle: Localized.text(
                    "Looked for Ollama, LM Studio, llama.cpp, llama-swap, vLLM and others on this machine. Start one, or give an address under Another server."),
                button: Localized.text("Find again"))
        }
    }

    private func show(title: String, subtitle: String, button label: String?) {
        if let row = row?.widget {
            adw_preferences_row_set_title(ptr(row), title)
            adw_action_row_set_subtitle(ptr(row), subtitle)
        }
        if let spinner = spinner?.widget {
            gtk_widget_set_visible(spinner, label == nil ? 1 : 0)
            if label == nil { gtk_spinner_start(op(spinner)) } else { gtk_spinner_stop(op(spinner)) }
        }
        if let button = button?.widget {
            gtk_widget_set_visible(button, label == nil ? 0 : 1)
            if let label { gtk_button_set_label(ptr(button), label) }
        }
    }

    static func label(_ model: PlainModelScout.Model) -> String {
        model.title + " · " + model.kind.title
    }

    static func place(_ address: String, _ model: String) -> String {
        let host = URL(string: address).map { ($0.host ?? address) + ($0.port.map { ":\($0)" } ?? "") } ?? address
        return model.isEmpty ? host : model + " · " + host
    }
}
