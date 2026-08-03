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
        let controller = MainWindowController()
        controller.showWindow(nil)
        main = controller
        let menu = MainMenu(hub: controller)
        menu.install()
        self.menu = menu
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A Mac that slept holds sockets that look alive and deliver nothing; coming back to the
    /// app is the moment to re-dial the stream and re-list the chats.
    func applicationDidBecomeActive(_ notification: Notification) {
        main?.handleDidBecomeActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
