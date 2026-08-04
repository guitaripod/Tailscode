import Foundation

/// Whose screen a window opens on.
///
/// A build under `.build/` was made by whoever is working on the app, and the desktop it would
/// open on belongs to whoever is using it — usually not the same person at the same moment. An
/// agent iterating on the Linux client used to put a window on the real screen every time it
/// wanted to look at something, on top of whatever was there. So a development build renders on
/// the harness's own X display (`scripts/dev-linuxapp.sh`) or it does not render at all, and the
/// refusal names both ways forward rather than just failing.
///
/// The installed binary is exempt: `~/.local/bin/tailscode` is what the person launches, and it
/// has every right to the screen it was launched from.
enum DesktopGuard {
    static let harnessVariable = "TAILSCODE_DEV_DISPLAY"
    static let overrideFlag = "--force-desktop"

    static func enforce() {
        guard isDevelopmentBuild, !isHarnessed, !isOverridden else { return }
        FileHandle.standardError.write(Data(message.utf8))
        exit(3)
    }

    private static var isDevelopmentBuild: Bool {
        executablePath.contains("/.build/")
    }

    private static var isHarnessed: Bool {
        ProcessInfo.processInfo.environment[harnessVariable]?.isEmpty == false
    }

    private static var isOverridden: Bool {
        Arguments.contains(overrideFlag)
    }

    /// `argv[0]` is whatever the caller typed and can be relative, a symlink, or a bare name off
    /// `PATH`; the kernel's own answer is none of those.
    private static var executablePath: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"))
            ?? Arguments.all.first ?? ""
    }

    private static var message: String {
        """
        tailscode: refusing to open a development build on this desktop.

          scripts/dev-linuxapp.sh start     headless — its own X display and session bus
          scripts/dev-linuxapp.sh shot      what it looks like, as a png
          scripts/install-linuxapp.sh       when the change is meant to be used for real

        Pass \(overrideFlag) to open a window here anyway.

        """
    }
}
