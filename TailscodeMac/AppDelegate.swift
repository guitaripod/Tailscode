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
        MacNotifier.shared.activate()
        MacNotifier.shared.onOpen = { [weak controller] sessionID in
            controller?.openSession(withID: sessionID)
        }
        FirstRunWindow.presentIfNeeded { [weak controller] in
            Task { [weak controller] in await controller?.sidebar.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        MacShot.schedule()
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
}
