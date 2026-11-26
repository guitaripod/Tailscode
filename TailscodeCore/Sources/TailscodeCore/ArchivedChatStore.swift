import Foundation

/// Chats set aside so the list stays short. Servers have no notion of an archive, so this is
/// deliberately local — and it stores only identity, never a copy: an archived chat is hidden,
/// not kept, and the listing remains the truth about what it says when it comes back.
public enum ArchivedChatStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let storageKey = "tailscode.archived.sessions"

    /// A conversation's identity as two strings rather than one joined key: a board walks a fleet
    /// of thousands on every refresh, and building a "profile/session" line for each one just to
    /// ask a set whether it holds it was most of a refresh's CPU.
    public struct ChatKey: Hashable, Sendable {
        public let profileID: String
        public let sessionID: String

        public init(profileID: String, sessionID: String) {
            self.profileID = profileID
            self.sessionID = sessionID
        }
    }

    /// Posted after every toggle. A client with more than one surface reading the archive —
    /// a board, a list and an archived view at once — listens here instead of each surface
    /// re-rendering the others by hand.
    public static let didChange = Notification.Name("tailscode.archived.didChange")

    public static func all() -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    /// The archive as identities, for a reader that asks once per row.
    public static func keys() -> Set<ChatKey> {
        Set(
            (defaults.stringArray(forKey: storageKey) ?? []).compactMap { line in
                guard let slash = line.firstIndex(of: "/") else { return nil }
                return ChatKey(
                    profileID: String(line[..<slash]),
                    sessionID: String(line[line.index(after: slash)...]))
            })
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
        MarkIntentStore.note(
            sessionID: sessionID, profileID: profileID, mark: .archived, on: archived)
        StoreNotice.post(didChange)
        return archived
    }

    /// Applies what the servers settled: these in, these out. Silent when that changes nothing
    /// here, and never an intent of this device's own — the server already knows.
    public static func adopt(add: Set<String>, remove: Set<String>) {
        let current = all()
        let next = current.union(add).subtracting(remove)
        guard next != current else { return }
        defaults.set(next.sorted(), forKey: storageKey)
        StoreNotice.post(didChange)
    }

    public static func key(_ profileID: String, _ sessionID: String) -> String {
        "\(profileID)/\(sessionID)"
    }
}
