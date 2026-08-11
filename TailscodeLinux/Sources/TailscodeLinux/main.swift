import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// `--selftest` never opens a display: a headless box, a tty, or a build loop over ssh has no
/// Wayland or X to render into, and that is exactly where this app most needs to be checked.
/// Read before anything asks a preference: the durable copy of the app's own state lives in a
/// file, not in the executable-keyed defaults store a reinstall abandons.
SettingsFile.load()

/// Read after the file and before anything opens a composer, in that order: the store adopts what
/// 1.9 left in the defaults, and only then is the settings file told to stop carrying keys that
/// have moved out of it into the store's own.
DraftStore.warm()
SettingsFile.forget(prefix: "tailscode.draft.")

/// The two video sites' tokens belong wherever this box keeps a secret, which on a session with no
/// keyring is a 0600 file. Handed over before anything reads an account: an uninstalled store makes
/// every account read as signed out, which is a feature quietly missing rather than a failure.
MediaAccounts.install(FileSecretStore())

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
    "--version", "--help", "-h", "--themes", "--force-desktop", "--demo", "--ask",
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
/// Whether this launch is a question rather than a visit. A summon that arrives before the app is
/// standing opens the window and the composer on top of it; one that arrives after is carried to
/// the process that already exists as an action rather than as a second app.
nonisolated(unsafe) var wantsAsk = Arguments.contains("--ask")

Gtk.connect(UnsafeMutableRawPointer(app), "activate") {
    if let existing = mainWindow {
        existing.raise()
    } else {
        let window = MainWindow()
        mainWindow = window
        window.present(in: app)
        Summon.shared.start { mainWindow?.summonQuickAsk() }
    }
    if wantsAsk {
        wantsAsk = false
        mainWindow?.summonQuickAsk()
    }
}

/// The one thing this app can be asked to do from outside its own window. GApplication proxies an
/// action to the instance that already holds the session bus name, which is what lets a chord bound
/// anywhere on the desktop reach the running app instead of starting a second one.
AppActions.installAsk(on: UnsafeMutableRawPointer(app)) {
    if mainWindow == nil {
        g_application_activate(ptr(app))
    }
    mainWindow?.summonQuickAsk()
}

/// A `--ask` that finds the name already taken hands the request over and gets out of the way.
/// Registering here rather than inside `run` is what makes that answerable at all: `is_remote` has
/// no meaning until the application has tried for the name.
if wantsAsk {
    var registerError: UnsafeMutablePointer<GError>?
    g_application_register(ptr(app), nil, &registerError)
    if let registerError { g_error_free(registerError) }
    if g_application_get_is_remote(ptr(app)) != 0 {
        g_action_group_activate_action(op(UnsafeMutableRawPointer(app)), "ask", nil)
        if let connection = g_application_get_dbus_connection(ptr(app)) {
            g_dbus_connection_flush_sync(connection, nil, nil)
        }
        exit(0)
    }
}

/// Whatever the last window did not get to write. `close-request` covers the ordinary quit while
/// the composers still exist to be read; this is the backstop for every other way the loop ends,
/// and it touches no widget because by here there may be none left.
Gtk.connect(UnsafeMutableRawPointer(app), "shutdown") {
    DraftStore.flush()
}

let status = g_application_run(ptr(app), 0, nil)
g_object_unref(app)
exit(status)
