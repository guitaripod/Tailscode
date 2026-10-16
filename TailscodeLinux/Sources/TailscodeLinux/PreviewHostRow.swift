import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The line a configured server earns on the server screen when the machine also runs a preview
/// host. It is built hidden and asks once, off the main thread: a server with no preview host
/// shows nothing at all, never an error, because most servers will never have one.
final class PreviewHostRow: @unchecked Sendable {
    let row = adw_action_row_new()!
    let passwordRow = adw_password_entry_row_new()!
    private let button: UnsafeMutablePointer<GtkWidget>
    private let host: String
    private let secrets: any SecretStore = FileSecretStore()
    private var reach: PreviewReach = .unknown
    private var task: Task<Void, Never>?

    init(host: String) {
        self.host = host
        button = Gtk.button(Localized.text("Use for previews"), css: []) {}
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), Localized.text("Preview host"))
        adw_action_row_set_subtitle_lines(ptr(row), 0)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), button)
        adw_preferences_row_set_use_markup(ptr(passwordRow), 0)
        adw_preferences_row_set_title(ptr(passwordRow), Localized.text("Password"))
        gtk_widget_set_visible(row, 0)
        gtk_widget_set_visible(passwordRow, 0)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.choose() }
        }
        Gtk.connect(UnsafeMutableRawPointer(passwordRow), "entry-activated") { [weak self] in
            Gtk.onMain { [weak self] in self?.choose() }
        }
        check(password: storedPassword)
    }

    deinit {
        task?.cancel()
    }

    func add(to expander: UnsafeMutablePointer<GtkWidget>) {
        adw_expander_row_add_row(ptr(expander), row)
        adw_expander_row_add_row(ptr(expander), passwordRow)
    }

    var isShown: Bool { gtk_widget_get_visible(row) != 0 }
    var subtitle: String {
        adw_action_row_get_subtitle(ptr(row)).map(String.init(cString:)) ?? ""
    }

    private var access: PreviewAccess {
        PreviewAccessStore.access(host: host) ?? PreviewAccess(host: host)
    }

    private var storedPassword: String? {
        (try? secrets.value(for: access.secretKey)) ?? nil
    }

    private func check(password: String?) {
        let access = access
        task?.cancel()
        task = Task { [weak self] in
            let found = await PreviewProbe.probe(access, password: password)
            Gtk.onMain { [weak self] in self?.settle(found) }
        }
    }

    private func settle(_ found: PreviewReach) {
        reach = found
        let present = found.isAnswering || found.asksForPassword
        gtk_widget_set_visible(row, present ? 1 : 0)
        gtk_widget_set_visible(passwordRow, found.asksForPassword ? 1 : 0)
        guard present else { return }
        adw_action_row_set_subtitle(ptr(row), found.line)
        let known = PreviewAccessStore.access(host: host) != nil
        gtk_widget_set_sensitive(button, known && found.isAnswering ? 0 : 1)
    }

    private func choose() {
        let typed = passwordRow.withText
        if reach.asksForPassword, typed.isEmpty, storedPassword == nil {
            gtk_widget_grab_focus(passwordRow)
            return
        }
        let access = access
        let password = typed.isEmpty ? storedPassword : typed
        task?.cancel()
        task = Task { [weak self] in
            let found = await PreviewProbe.probe(access, password: password)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if found.isAnswering {
                    PreviewAccessStore.remember(access)
                    if !typed.isEmpty { try? self.secrets.setValue(typed, for: access.secretKey) }
                }
                self.settle(found)
            }
        }
    }
}

private extension UnsafeMutablePointer where Pointee == GtkWidget {
    var withText: String {
        gtk_editable_get_text(OpaquePointer(self)).map(String.init(cString:)) ?? ""
    }
}
