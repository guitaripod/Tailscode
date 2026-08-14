import AppKit
import TailscodeCore

/// Lifecycle only: activation, reconnect-on-active, and the one window controller that is the
/// app. Everything the window does lives in `MainWindowController`; the menu bar lives in
/// `MainMenu`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindowController?
    private var menu: MainMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        SessionSeenStore.bootstrapIfNeeded()
        DraftStore.warm()
        ThemeSelection.fallbackID = ThemeSelection.systemID
        NSApp.appearance = MacTheme.Chrome.appearance
        let controller = MainWindowController()
        controller.showWindow(nil)
        main = controller
        let menu = MainMenu(hub: controller)
        menu.install()
        self.menu = menu
        MacGameCenter.shared.start()
        MacSummon.shared.start { [weak controller] in controller?.summonQuickAsk() }
        MacNotifier.shared.activate()
        MacNotifier.shared.onOpen = { [weak controller] sessionID in
            controller?.openSession(withID: sessionID)
        }
        FirstRunWindow.presentIfNeeded { [weak controller] in
            Task { [weak controller] in await controller?.sidebar.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        openRequestedSession()
        openRequestedSurface()
        MacShot.schedule()
    }

    /// `TAILSCODE_OPEN_SESSION=<id>` — the same headless hook the iOS harness has: land the
    /// window on one named chat once the listing exists, so a `--shot` can look at a
    /// conversation instead of the picker.
    private func openRequestedSession() {
        guard let id = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SESSION"] else {
            return
        }
        Task { [weak main] in
            try? await Task.sleep(for: .seconds(2))
            main?.openSession(withID: id)
        }
    }

    /// `--open <surface>` — the same hook one step further in: land on a named window once the
    /// listing behind it exists, so `--shot` and `--tree` can look at a sheet or a panel rather
    /// than only at the window a launch already draws.
    private func openRequestedSurface() {
        guard let surface = MacShot.surface else { return }
        Task { [weak main] in
            try? await Task.sleep(for: .seconds(2))
            main?.openSurface(named: surface)
        }
    }

    /// A Mac that slept holds sockets that look alive and deliver nothing; coming back to the
    /// app is the moment to re-dial the stream and re-list the chats.
    func applicationDidBecomeActive(_ notification: Notification) {
        main?.handleDidBecomeActive()
    }

    /// Switching away is the ordinary way this app stops being asked, and the one people do
    /// dozens of times a day: whatever is half-typed goes to disk here rather than waiting for
    /// the store's quiet moment to come around.
    func applicationWillResignActive(_ notification: Notification) {
        stashDrafts()
    }

    /// The last chance there is. Quitting must never be what eats a prompt, so every open pane's
    /// composer is written before the process goes.
    func applicationWillTerminate(_ notification: Notification) {
        stashDrafts()
    }

    private func stashDrafts() {
        main?.stashComposerDrafts()
        DraftStore.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Closing the window is closing the app — unless a settings, servers or analytics window is
    /// keeping the process alive, in which case the conversations have just gone somewhere with no
    /// way back: there is no File ▸ New Window to rebuild the hub from. The Dock icon is that way
    /// back, and it is the only one.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        main?.showWindow(nil)
        return true
    }
}
