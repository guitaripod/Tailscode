import CGtkShim
import Foundation

/// The shell shows an app's icon only when it can match the window to a desktop entry — and on
/// Wayland the match key is the GApplication id, so the entry must be named after it exactly.
/// A `tailscode.desktop` next to a window whose app id is `com.guitaripod.tailscode` matches
/// nothing, and the taskbar draws the blank-page fallback. This installs the icon and the
/// correctly-named entry into the user's XDG data dirs on any launch that finds them missing or
/// stale, and removes the misnamed entry an earlier build left behind.
enum DesktopIntegration {
    static let appID = "com.guitaripod.tailscode"

    static func ensureInstalled() {
        let data = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share", isDirectory: true)
        let icon = data.appendingPathComponent("icons/hicolor/scalable/apps/\(appID).svg")
        let entry = data.appendingPathComponent("applications/\(appID).desktop")

        write(iconSVG, to: icon)
        write(desktopEntry(), to: entry)

        for legacy in [
            data.appendingPathComponent("applications/tailscode.desktop"),
            data.appendingPathComponent("icons/hicolor/scalable/apps/tailscode.svg"),
        ] where FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    private static func write(_ content: String, to target: URL) {
        guard (try? String(contentsOf: target, encoding: .utf8)) != content else { return }
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: target, atomically: true, encoding: .utf8)
    }

    /// Points Exec at the installed binary when there is one, so a dev build refreshing the entry
    /// never redirects the launcher into a `.build` directory that the next `swift build` replaces.
    private static func desktopEntry() -> String {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/tailscode").path
        let exec = FileManager.default.isExecutableFile(atPath: installed)
            ? installed : (CommandLine.arguments.first.map { URL(fileURLWithPath: $0).path } ?? "tailscode")
        return """
        [Desktop Entry]
        Type=Application
        Name=Tailscode
        Comment=Drive your coding agents over Tailscale
        Exec=\(exec)
        Icon=\(appID)
        Terminal=false
        Categories=Development;Network;
        StartupWMClass=\(appID)
        """
    }

    private static let iconSVG = """
        <svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <linearGradient id="bg" x1="0" y1="0" x2="1024" y2="1024" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="#4C8DFF"/>
              <stop offset="0.5" stop-color="#3355E6"/>
              <stop offset="1" stop-color="#6D28D9"/>
            </linearGradient>
            <filter id="cardShadow" x="-30%" y="-30%" width="160%" height="160%">
              <feDropShadow dx="0" dy="22" stdDeviation="30" flood-color="#10163A" flood-opacity="0.28"/>
            </filter>
          </defs>

          <rect width="1024" height="1024" fill="url(#bg)"/>

          <line x1="672" y1="672" x2="778" y2="778" stroke="#FFFFFF" stroke-width="18" stroke-linecap="round" opacity="0.38"/>
          <circle cx="800" cy="800" r="46" fill="#FFFFFF" opacity="0.92"/>

          <g filter="url(#cardShadow)">
            <path d="M 372 236 H 652 A 156 156 0 0 1 808 392 V 560 A 156 156 0 0 1 652 716 H 452 L 300 812 V 640 A 156 156 0 0 1 300 616 V 392 A 156 156 0 0 1 372 236 Z" fill="#FFFFFF"/>
          </g>

          <polyline points="404,392 540,478 404,564" fill="none" stroke="#2563EB" stroke-width="54" stroke-linecap="round" stroke-linejoin="round"/>
          <line x1="576" y1="560" x2="700" y2="560" stroke="#2563EB" stroke-width="54" stroke-linecap="round"/>
        </svg>
        """
}

/// Font scale as a live, keyboard-driven preference: `gtk-xft-dpi` multiplies every font in the
/// app — chrome and canvas alike — the way a terminal's Ctrl+= does, and it survives relaunch.
enum UIScale {
    private static let key = "tailscode.uiScale"

    static var factor: Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored == 0 ? 1.0 : stored
    }

    static func apply() {
        tailscode_set_text_scale(factor)
    }

    static func step(_ delta: Double) {
        let next = min(2.0, max(0.6, ((factor + delta) * 10).rounded() / 10))
        UserDefaults.standard.set(next, forKey: key)
        tailscode_set_text_scale(next)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        tailscode_set_text_scale(1.0)
    }
}
