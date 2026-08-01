import CAdw
import CGtkShim
import Foundation

/// `--selftest` never opens a display: a headless box, a tty, or a build loop over ssh has no
/// Wayland or X to render into, and that is exactly where this app most needs to be checked.
if SelfTest.isRequested {
    Task { await SelfTest.run() }
    dispatchMain()
}

/// The window is built inside `activate`, never before it: GTK widgets cannot be constructed
/// until the toolkit has initialised, and one made at top level segfaults inside `gtk_box_new`
/// before the app has run a line of its own.
nonisolated(unsafe) var mainWindow: MainWindow?
nonisolated(unsafe) let app = adw_application_new("com.guitaripod.tailscode", GApplicationFlags(rawValue: 0))!

Gtk.connect(UnsafeMutableRawPointer(app), "activate") {
    let window = MainWindow()
    mainWindow = window
    window.present(in: app)
}

let status = g_application_run(ptr(app), 0, nil)
g_object_unref(app)
exit(status)
