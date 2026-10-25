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
/// built-in rules could not read. Off until the switch is turned on; the address is vetted as it is
/// typed, and the wall rebuilds its model from the settings after every change.
enum SettingsPlainWords {
    static func add(to page: UnsafeMutablePointer<GtkWidget>) {
        let group = SettingsRows.group(Localized.text("Plain words"), on: page)
        let toggle = SettingsRows.switchRow(
            title: Localized.text("Let a local model say unusual commands"),
            subtitle: Localized.text(
                "Off by default. Only a command the built-in rules could not read is sent, as text with secrets taken out, to the address below, and only if it is on this machine or your private network. Lines it writes are marked ✦. Never used for approvals."
            ),
            value: Preferences.plainWords
        ) { value in
            Preferences.setPlainWords(value)
            changed()
        }
        adw_action_row_set_subtitle_lines(ptr(toggle), 0)
        SettingsRows.add(toggle, to: group)

        let address = entryRow(
            title: Localized.text("Server address"), placeholder: Localized.text("http://127.0.0.1:8080/v1"),
            text: Preferences.plainWordsAddress
        ) { text, row in
            Preferences.setPlainWordsAddress(text)
            judge(text, on: row)
            changed()
        }
        judge(Preferences.plainWordsAddress, on: address)
        SettingsRows.add(address, to: group)

        SettingsRows.add(
            entryRow(
                title: Localized.text("Model"), placeholder: Localized.text("First one the server lists"),
                text: Preferences.plainWordsModel
            ) { text, _ in
                Preferences.setPlainWordsModel(text)
                changed()
            }, to: group)

        let held = PlainWordsCheckHeld()
        let check = SettingsRows.buttonRow(
            Localized.text("Check"), label: Localized.text("Check")
        ) {
            Gtk.onMain { runCheck(held) }
        }
        held.hold = Gtk.WeakWidget(check)
        SettingsRows.add(check, to: group)
    }

    private static func changed() {
        Gtk.onMain { AgentsWindow.current?.plainWordsChanged() }
    }

    private static func entryRow(
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
        let entryBits = UInt(bitPattern: entry)
        let rowBits = UInt(bitPattern: row)
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") {
            guard let entry = UnsafeMutablePointer<GtkWidget>(bitPattern: entryBits),
                let row = UnsafeMutablePointer<GtkWidget>(bitPattern: rowBits),
                let raw = gtk_editable_get_text(op(entry))
            else { return }
            onChange(String(cString: raw), row)
        }
        return row
    }

    /// Marks the address row when what was typed is not on this machine or the person's network.
    private static func judge(_ text: String, on row: UnsafeMutablePointer<GtkWidget>) {
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
