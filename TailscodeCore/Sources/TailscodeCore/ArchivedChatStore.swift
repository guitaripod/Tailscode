import Foundation

/// Chats set aside so the list stays short. Servers have no notion of an archive, so this is
/// deliberately local — and it stores only identity, never a copy: an archived chat is hidden,
/// not kept, and the listing remains the truth about what it says when it comes back.
public enum ArchivedChatStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let storageKey = "tailscode.archived.sessions"

    public static func all() -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    public static func contains(profileID: String, sessionID: String) -> Bool {
        all().contains(key(profileID, sessionID))
    }

    @discardableResult
    public static func toggle(profileID: String, sessionID: String) -> Bool {
        var current = all()
        let id = key(profileID, sessionID)
        let archived: Bool
        if current.contains(id) {
            current.remove(id)
            archived = false
        } else {
            current.insert(id)
            archived = true
        }
        defaults.set(current.sorted(), forKey: storageKey)
        return archived
    }

    public static func key(_ profileID: String, _ sessionID: String) -> String {
        "\(profileID)/\(sessionID)"
    }
}
