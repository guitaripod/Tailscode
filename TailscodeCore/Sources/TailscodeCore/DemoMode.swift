import Foundation

/// Whether this device is currently living in the scripted demo world. One defaults key on every
/// client, so first-run "Try the demo" and leaving when a real server is saved speak the same
/// fact. A demo asked for on the command line is not that fact: it lasts as long as the process
/// that was asked, and leaves nothing behind for the next launch to find.
public enum DemoMode {
    public static let defaultsKey = "tailscode.demoMode"

    nonisolated(unsafe) private static var thisLaunch = false

    public static var isActive: Bool {
        get { thisLaunch || UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    public static func enter() {
        DemoNudge.reset()
        isActive = true
    }

    /// `--demo`: the world for this one launch. A screenshot, a recording or a check run with the
    /// flag shares its defaults with the app the person actually uses, so writing the choice down
    /// would put that app into the demo on its next launch, and every launch after.
    public static func enterForThisLaunch() {
        thisLaunch = true
    }

    public static func leave() {
        thisLaunch = false
        isActive = false
    }
}
