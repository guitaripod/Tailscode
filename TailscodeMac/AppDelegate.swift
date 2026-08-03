import AppKit
import TailscodeCore

/// Lifecycle only: activation, the menu bar, and the one window controller that is the app.
/// Everything the window does lives in `MainWindowController`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        SessionSeenStore.bootstrapIfNeeded()
        buildMenu()
        let controller = MainWindowController()
        controller.showWindow(nil)
        main = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A Mac that slept holds sockets that look alive and deliver nothing; coming back to the
    /// app is the moment to re-dial the stream and re-list the chats.
    func applicationDidBecomeActive(_ notification: Notification) {
        main?.handleDidBecomeActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: Localized.text("Quit Tailscode"), action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: Localized.text("Edit"))
        editMenu.addItem(withTitle: Localized.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: Localized.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: Localized.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: Localized.text("Select All"), action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
