import Foundation

/// Whether this device is currently living in the scripted demo world. One defaults key on every
/// client, so `--demo`, first-run "Try the demo", and leaving when a real server is saved all
/// speak the same fact.
public enum DemoMode {
    public static let defaultsKey = "tailscode.demoMode"

    public static var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    public static func enter() { isActive = true }
    public static func leave() { isActive = false }
}
