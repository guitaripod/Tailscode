import CGtkShim
import Foundation
import TailscodeCore

/// The app left standing with no window, because the chord it claimed from the whole machine is
/// only as good as the process behind it. A shortcut the desktop granted stops answering the
/// moment this process ends, and a person who closes the chat list has not asked to lose the one
/// gesture the whole feature exists for.
///
/// So the process holds itself open (`g_application_hold`), the window's close hides rather than
/// destroys, and an autostart entry brings the app back at every login — hidden, with the ring
/// already in place for the chord. Closing the window is therefore not quitting: the menu's Quit
/// is, and it stays one press away in the app's own menu.
enum BackgroundAgent {
    static let launchFlag = "--background"

    /// The person's own no, kept beside the summon's own preference: once somebody has turned the
    /// login entry off, a later launch must not quietly put it back.
    private static let offKey = "tailscode.agent.autostart.off"

    nonisolated(unsafe) private static var held = false

    /// A launch the desktop made at login rather than a person: the window stays in the background
    /// until it is asked for.
    static var startsHidden: Bool {
        Arguments.contains(launchFlag)
            || ProcessInfo.processInfo.environment["TAILSCODE_BACKGROUND"] == "1"
    }

    /// How far the claimed chord reaches: an autostart entry is the difference between a key that
    /// answers until the next reboot and one that answers at every login.
    static var reach: SummonReach { isInstalled ? .readyInBackground : .whileRunning }

    /// The process is the app now, window or not. Called once the window exists; the app's own
    /// activation still runs on every later launch, which is what raises the window again.
    static func hold() {
        guard !held else { return }
        held = true
        g_application_hold(ptr(app))
    }

    static func release() {
        guard held else { return }
        held = false
        g_application_release(ptr(app))
    }

    static var entryURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let config = environment["XDG_CONFIG_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
        return config.appendingPathComponent("autostart", isDirectory: true)
            .appendingPathComponent("\(DesktopIntegration.appID).desktop")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: entryURL.path)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(!on, forKey: offKey)
        SettingsFile.capture()
        if on {
            install()
        } else {
            try? FileManager.default.removeItem(at: entryURL)
        }
        Summon.shared.refresh()
    }

    /// A copy that is installed will be opened again tomorrow, so it puts itself back at login the
    /// first time it runs — unless the person said no or this build is one an agent made. A build
    /// under `.build/` or a Flatpak sandbox is not the app the next login should start: the first
    /// disappears with the next compile and the second cannot write a file the host session reads.
    static func adoptOnInstalledCopy() {
        guard !DesktopGuard.isDevelopmentBuild else { return }
        guard ProcessInfo.processInfo.environment["FLATPAK_ID"] == nil,
            !FileManager.default.fileExists(atPath: "/.flatpak-info")
        else { return }
        guard !UserDefaults.standard.bool(forKey: offKey) else { return }
        guard SummonSettings.isEnabled else { return }
        install()
    }

    static func install() {
        let exec = DesktopGuard.executablePath
        guard !exec.isEmpty, !exec.contains("/.build/") else { return }
        try? FileManager.default.createDirectory(
            at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? entryText(exec: exec).write(to: entryURL, atomically: true, encoding: .utf8)
    }

    static func entryText(exec: String) -> String {
        """
        [Desktop Entry]
        Type=Application
        Name=Tailscode
        Comment=Ask your coding agents from anywhere
        Exec=\(exec) \(launchFlag)
        Icon=\(DesktopIntegration.appID)
        Terminal=false
        StartupNotify=false
        X-GNOME-Autostart-enabled=true
        """
    }
}
