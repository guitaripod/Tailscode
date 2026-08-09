import Foundation

/// A question is not a project, so a quick ask owes no form: the surface offers one composer,
/// aims itself, and sending is the whole ceremony. The aim is this device's memory of where the
/// last quick ask went — a preference, not a fact about any server — and the conversation it
/// mints is ordinary in every way except that it carries no project directory.
public enum QuickAskDefaults {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let serverKey = "tailscode.quickask.server"
    public static let didChange = Notification.Name("tailscode.quickask.didChange")

    public static var lastProfileID: String? {
        defaults.string(forKey: serverKey)
    }

    public static func record(profileID: String) {
        defaults.set(profileID, forKey: serverKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func clear() {
        defaults.removeObject(forKey: serverKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Which server answers a quick ask: the one the last quick ask used while it is still
    /// among the servers offered, else the caller's own fallback (the composer's aim, the only
    /// server), else the first server offered. Nil only when there are no servers at all — the
    /// surface's cue to offer setup instead of a dead text box.
    public static func target(among profileIDs: [String], fallback: String? = nil) -> String? {
        if let last = lastProfileID, profileIDs.contains(last) { return last }
        if let fallback, profileIDs.contains(fallback) { return fallback }
        return profileIDs.first
    }
}
