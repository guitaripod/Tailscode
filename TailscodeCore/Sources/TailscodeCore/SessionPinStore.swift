import Foundation

/// Chats a person keeps at the top of the list. Servers have no notion of a pin, so this is
/// deliberately local — it stores only identity, never a copy — and it remembers the order the
/// pins were made in, because a pinned section that shuffled itself would be worse than none.
public enum SessionPinStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let storageKey = "tailscode.pinned.sessions"
    static let stampsKey = "tailscode.pinned.at"

    /// Posted after every toggle. A client with more than one surface reading the pins — a list
    /// and a board at once — listens here instead of each surface re-rendering the others by hand.
    public static let didChange = Notification.Name("tailscode.pinned.didChange")

    /// Pins in the order they were made, oldest first.
    public static func all() -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    public static func contains(profileID: String, sessionID: String) -> Bool {
        all().contains(key(profileID, sessionID))
    }

    /// Where the pin sits in pin order, nil when it is not pinned.
    public static func rank(profileID: String, sessionID: String) -> Int? {
        all().firstIndex(of: key(profileID, sessionID))
    }

    @discardableResult
    public static func toggle(profileID: String, sessionID: String) -> Bool {
        var current = all()
        let id = key(profileID, sessionID)
        let pinned: Bool
        if let index = current.firstIndex(of: id) {
            current.remove(at: index)
            pinned = false
        } else {
            current.append(id)
            pinned = true
        }
        defaults.set(current, forKey: storageKey)
        var stamps = self.stamps()
        stamps[id] = pinned ? Date().timeIntervalSince1970 : nil
        defaults.set(stamps, forKey: stampsKey)
        MarkIntentStore.note(
            sessionID: sessionID, profileID: profileID, mark: .pinned, on: pinned)
        NotificationCenter.default.post(name: didChange, object: nil)
        return pinned
    }

    /// When each pin was made, by the clock that made it: this device's until the server that
    /// holds the conversation answers with its own. What orders the pins.
    public static func stamps() -> [String: Double] {
        defaults.dictionary(forKey: stampsKey) as? [String: Double] ?? [:]
    }

    /// Takes the order the servers settled on. Nothing is posted when it is the order already
    /// held, so a listing that agreed costs the screens nothing.
    public static func adopt(order: [String], stamps: [String: Double]) {
        let changed = order != all()
        defaults.set(order, forKey: storageKey)
        defaults.set(stamps, forKey: stampsKey)
        if changed { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    public static func key(_ profileID: String, _ sessionID: String) -> String {
        "\(profileID)/\(sessionID)"
    }
}
