import CAdw
import CGtkShim
import Foundation

/// `--selftest` never opens a display: a headless box, a tty, or a build loop over ssh has no
/// Wayland or X to render into, and that is exactly where this app most needs to be checked.
/// Read before anything asks a preference: the durable copy of the app's own state lives in a
/// file, not in the executable-keyed defaults store a reinstall abandons.
SettingsFile.load()

if SelfTest.isRequested {
    Task { await SelfTest.run() }
    dispatchMain()
}

/// Anything that is not a request to open a window is answered before GApplication registers on
/// the session bus. An unrecognised flag that reaches `g_application_run` starts a headless
/// instance that owns the name forever, and every launch after it remote-activates that zombie and
/// exits without a window.
if CommandLine.arguments.contains("--version") {
    print("tailscode \(TailscodeVersion.current)")
    exit(0)
}

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print(TailscodeVersion.usage)
    exit(0)
}

let knownOptions: Set<String> = [
    "--selftest", "--connect", "--password", "--name", "--opencode", "--version", "--help", "-h",
]
if let stray = CommandLine.arguments.dropFirst().first(where: {
    $0.hasPrefix("-") && !knownOptions.contains($0)
}) {
    print("unknown option \(stray)\n\n\(TailscodeVersion.usage)")
    exit(2)
}

if Connect.isRequested {
    Task { await Connect.run() }
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
