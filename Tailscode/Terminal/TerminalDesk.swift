import CodingAgentKit
import TailscodeCore
import UIKit

/// The shells this device has open, one per server, kept for as long as the app runs.
///
/// A terminal screen that is closed lets go of nothing: coming back to it from the same chat, or
/// from another chat on the same machine, shows the same shell with its scrollback. The shell
/// itself is the server's and outlives the app.
@MainActor
enum TerminalDesk {
    private static var sessions: [String: TerminalSession] = [:]

    static var name: String {
        TerminalDeskName.current(client: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
    }

    static var colors: TerminalColors {
        let dark =
            ThemeSelection.appearance.pinnedDark
            ?? (UITraitCollection.current.userInterfaceStyle == .dark)
        return ThemePalette.current.map(TerminalColors.init(palette:)) ?? TerminalColors.plain(dark: dark)
    }

    /// The shell on a chat's server, walked to that chat's folder.
    static func session(
        profileID: String, server: String, backend: any CodingAgentBackend, directory: String?,
        sessionID: String
    ) -> TerminalSession {
        if let held = sessions[profileID] {
            held.follow(directory: directory)
            return held
        }
        let session = TerminalSession(
            backend: backend, target: .init(server: server, directory: directory, sessionID: sessionID),
            desk: name, colors: colors)
        sessions[profileID] = session
        session.start()
        return session
    }

    static func recolour() {
        let colors = colors
        for session in sessions.values { session.screen?.apply(colors) }
    }
}
