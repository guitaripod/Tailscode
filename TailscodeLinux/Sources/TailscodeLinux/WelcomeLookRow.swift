import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The one line the welcome says about how the app looks: the look a newcomer starts in beside
/// the theme this desktop wore before there was one, a press apart. Everything else about themes
/// is in Settings.
enum WelcomeLookRow {
    /// Called when the row changed what the app wears, so the window repaints with it.
    nonisolated(unsafe) static var onChanged: (@Sendable () -> Void)?

    static func welcomeLookRow() -> UnsafeMutablePointer<GtkWidget> {
        let look = ThemeSelection.welcomeLook
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(row, top: 10)
        gtk_box_append(ptr(row), Gtk.label(look.title, css: "dim", selectable: false))
        let ids = look.choices.map(\.id)
        let strip = SettingsRows.segmented(
            options: look.choices.map(\.title), selected: look.choices.firstIndex(where: \.isChosen) ?? -1
        ) { index in
            Gtk.onMain {
                guard ids.indices.contains(index), ThemeSelection.themeID != ids[index] else { return }
                Preferences.setTheme(AppTheme.named(ids[index]))
                MatrixTheme.install()
                onChanged?()
            }
        }
        gtk_box_append(ptr(row), strip)
        gtk_box_append(ptr(row), Gtk.label(look.caption, css: "dim", selectable: false))
        return row
    }
}
