import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// `--selftest` never opens a display: a headless box, a tty, or a build loop over ssh has no
/// Wayland or X to render into, and that is exactly where this app most needs to be checked.
/// Read before anything asks a preference: the durable copy of the app's own state lives in a
/// file, not in the executable-keyed defaults store a reinstall abandons.
SettingsFile.load()

if SelfTest.isRequested {
    Task { await SelfTest.run() }
    dispatchMain()
}

if ProbeNewChat.isRequested {
    Task { await ProbeNewChat.run() }
    dispatchMain()
}

/// Anything that is not a request to open a window is answered before GApplication registers on
/// the session bus. An unrecognised flag that reaches `g_application_run` starts a headless
/// instance that owns the name forever, and every launch after it remote-activates that zombie and
/// exits without a window.
if Arguments.contains("--version") {
    print("tailscode \(TailscodeVersion.current)")
    exit(0)
}

if Arguments.contains("--help") || Arguments.contains("-h") {
    print(TailscodeVersion.usage)
    exit(0)
}

/// The catalog as data — every theme, both appearances, the colours as corrected rather than as
/// authored, with each slot's measured contrast. A theme is judged by how it reads, and this is
/// how anything without eyes on the window reads it.
if Arguments.contains("--themes") {
    print(ThemeReport.text())
    exit(0)
}

let knownOptions: Set<String> = [
    "--selftest", "--probe-newchat", "--connect", "--password", "--name", "--opencode",
    "--version", "--help", "-h", "--themes", "--force-desktop", "--demo",
]
if let stray = Arguments.flags.first(where: {
    $0.hasPrefix("-") && !knownOptions.contains($0)
}) {
    print("unknown option \(stray)\n\n\(TailscodeVersion.usage)")
    exit(2)
}

if Connect.isRequested {
    Task { await Connect.run() }
    dispatchMain()
}

if Arguments.contains("--demo") {
    DemoMode.enter()
}

DesktopGuard.enforce()

/// The window is built inside `activate`, never before it: GTK widgets cannot be constructed
/// until the toolkit has initialised, and one made at top level segfaults inside `gtk_box_new`
/// before the app has run a line of its own.
nonisolated(unsafe) var mainWindow: MainWindow?
nonisolated(unsafe) let app = adw_application_new("com.guitaripod.tailscode", GApplicationFlags(rawValue: 0))!

/// A second launch is a request to see the window that already exists, not to build another one.
/// This app is single-instance on the session bus, so every later launch — a `.desktop` click, a
/// terminal, an agent checking a change — remote-activates the running process and lands here.
/// Building a fresh `MainWindow` each time stacked a whole second app inside the one process —
/// sidebar, tiling tree, terminal, polling timers, every session's stream — and let go of none of
/// it, so the window count and the memory both only ever went up.
Gtk.connect(UnsafeMutableRawPointer(app), "activate") {
    if let existing = mainWindow {
        existing.raise()
        return
    }
    let window = MainWindow()
    mainWindow = window
    window.present(in: app)
}

let status = g_application_run(ptr(app), 0, nil)
g_object_unref(app)
exit(status)
