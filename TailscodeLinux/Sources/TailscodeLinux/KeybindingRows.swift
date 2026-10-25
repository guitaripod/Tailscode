import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Keys drawn as the caps a person presses. The Keyboard page and its capture dialog show a
/// binding the same way, so what is recorded in the dialog is what the list then reads back.
enum Keycaps {
    static func cap(_ text: String, classes: [String]) -> UnsafeMutablePointer<GtkWidget> {
        let widget = gtk_label_new(text)!
        let label: OpaquePointer = op(widget)
        gtk_label_set_xalign(label, 0.5)
        gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_NONE)
        gtk_label_set_selectable(label, 0)
        for name in classes { gtk_widget_add_css_class(widget, name) }
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        return widget
    }

    static func chord(_ chord: KeyChord) -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 3)
        for text in chord.caps(on: .linux) { gtk_box_append(ptr(box), cap(text, classes: ["keycap"])) }
        return box
    }

    /// One or two chords in a row, with a quiet "then" between them.
    static func sequence(_ chords: [KeyChord]) -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.groupBox(
            GTK_ORIENTATION_HORIZONTAL, spacing: 6, spoken: KeySpec.display(chords))
        for (index, item) in chords.enumerated() {
            if index > 0 {
                gtk_box_append(ptr(box), cap(Localized.text("then"), classes: ["keycap-then"]))
            }
            gtk_box_append(ptr(box), chord(item))
        }
        return box
    }

    /// A key as the file holds it: caps when the grammar reads it, the raw text in a red cap when
    /// it does not, so a typo in the file is visible instead of silently missing.
    static func key(_ key: ShortcutKey) -> UnsafeMutablePointer<GtkWidget> {
        guard key.isReadable else {
            let bad = cap(key.spec, classes: ["keycap", "keycap-bad"])
            gtk_widget_set_tooltip_text(bad, Localized.text("Not a shortcut I can read"))
            return bad
        }
        return sequence(key.chords)
    }

    /// Every key of an action, with "or" between them, or "Not set" when it has none.
    static func strip(_ keys: [ShortcutKey]) -> UnsafeMutablePointer<GtkWidget> {
        guard !keys.isEmpty else {
            return cap(Localized.text("Not set"), classes: ["keycap-unset"])
        }
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        for (index, item) in keys.enumerated() {
            if index > 0 { gtk_box_append(ptr(box), cap(Localized.text("or"), classes: ["keycap-or"])) }
            gtk_box_append(ptr(box), key(item))
        }
        return box
    }
}

/// The rows of the Keyboard page that stand for one action.
enum KeybindingRows {
    /// The words under an action's name: where its keys apply when that is narrower than the
    /// action itself, each distinct scope once.
    static func scopes(of entry: ShortcutEntry) -> String? {
        var seen: [String] = []
        for key in entry.keys {
            if let scope = key.scope, !seen.contains(scope) { seen.append(scope) }
        }
        return seen.isEmpty ? nil : seen.joined(separator: " · ")
    }

    static func row(
        for entry: ShortcutEntry, onOpen: @escaping @Sendable () -> Void,
        onRestore: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), entry.definition.title)
        if let scopes = scopes(of: entry) { adw_action_row_set_subtitle(ptr(row), scopes) }
        let strip = Keycaps.strip(entry.keys)
        gtk_widget_set_valign(strip, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), strip)
        if entry.isCustomized {
            let restore = gtk_button_new_from_icon_name("edit-undo-symbolic")!
            gtk_widget_add_css_class(restore, "flat")
            gtk_widget_set_valign(restore, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(restore, Localized.text("Restore the default keys"))
            Gtk.connect(UnsafeMutableRawPointer(restore), "clicked", onRestore)
            adw_action_row_add_suffix(ptr(row), restore)
        }
        gtk_list_box_row_set_activatable(ptr(UnsafeMutableRawPointer(row)), 1)
        Gtk.connect(UnsafeMutableRawPointer(row), "activated", onOpen)
        return row
    }

    static func issueRow(_ issue: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), issue)
        adw_action_row_set_title_lines(ptr(row), 0)
        let icon = gtk_image_new_from_icon_name(AppIcon.warning.name)!
        adw_action_row_add_prefix(ptr(row), icon)
        gtk_list_box_row_set_activatable(ptr(UnsafeMutableRawPointer(row)), 0)
        return row
    }
}
