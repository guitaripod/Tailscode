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
        if let png = Data(base64Encoded: iconPNGBase64.split(separator: "\n").joined()) {
            let raster = data.appendingPathComponent("icons/hicolor/256x256/apps/\(appID).png")
            if (try? Data(contentsOf: raster)) != png {
                try? FileManager.default.createDirectory(
                    at: raster.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? png.write(to: raster)
            }
        }
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
            ? installed : (Arguments.all.first.map { URL(fileURLWithPath: $0).path } ?? "tailscode")
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


    /// A 256px PNG of the same icon: KDE's launcher and taskbar resolve fixed-size PNGs reliably
    /// where an SVG depends on which gdk-pixbuf/Qt loaders the machine happens to have.
    private static let iconPNGBase64 = """
        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
        """

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
