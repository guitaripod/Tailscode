import AppKit
import CodingAgentKit
import TailscodeCore

/// Where a `tailscode://` address opened from outside the app is read. The pairing link a machine
/// prints is handed to first run, which decides with Core's plan whether it is a first machine, one
/// to add, or one already added; anything else this scheme was asked for is refused in the words
/// Core gives for it. The address itself can carry the machine's password, so nothing here logs it.
@MainActor
enum ConnectLinkDoor {
    static func open(_ urls: [URL], main: MainWindowController) {
        for url in urls where url.scheme?.lowercased() == PairingLink.scheme {
            switch ConnectLink.read(url: url) {
            case .link(let link):
                AppLogger.connection.info("open link \(ConnectLink.logLine(link))")
                FirstRunWindow.receive(link: url.absoluteString)
            case .rejected(let rejection):
                AppLogger.connection.info("open \(ConnectLink.logLine(rejection: rejection))")
                refuse(rejection, on: main)
            }
        }
    }

    /// A server the link named is one this Mac already has: the main window comes forward, says
    /// so, and offers a chat on it.
    static func show(serverID: String, main: MainWindowController) {
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let profile = ServerDirectory.shared.profiles.first(where: { $0.id == serverID })
        else { return }
        main.toast(ConnectLinkReading.alreadyAdded(profile.name))
        main.presentNewChat(on: profile)
    }

    private static func refuse(_ rejection: ConnectLink.Rejection, on main: MainWindowController) {
        let message = ConnectLinkReading.rejection(rejection)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message.title
        alert.informativeText = message.detail
        NSApp.activate(ignoringOtherApps: true)
        guard let window = main.window, window.isVisible else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }
}
