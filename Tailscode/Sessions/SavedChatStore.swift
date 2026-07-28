import CodingAgentKit
import Foundation

/// A conversation the user chose to keep. Carries its own copy of everything
/// needed to draw a row, because the point of saving a chat is to still find it
/// when the server that hosts it is asleep, unreachable, or gone.
struct SavedChat: Codable, Hashable {
    let profileID: String
    let sessionID: String
    var title: String
    var profileName: String
    var backend: AgentType
    var directory: String?
    var updatedAt: Date
    var savedAt: Date

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentSession.isPlaceholderTitle(trimmed) else { return trimmed }
        return trimmed.isEmpty ? "Empty conversation" : "New conversation"
    }

    var projectName: String? {
        directory.map { ($0 as NSString).lastPathComponent }
    }

    static func == (lhs: SavedChat, rhs: SavedChat) -> Bool {
        lhs.profileID == rhs.profileID && lhs.sessionID == rhs.sessionID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(profileID)
        hasher.combine(sessionID)
    }
}

/// Saved chats, on this device. Servers have no notion of a bookmark, so this
/// is deliberately local: it is the user's own shortlist, not shared state.
enum SavedChatStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let key = "tailscode.saved.chats"
    private static let capacity = 200

    static let didChange = Notification.Name("tailscode.saved.didChange")

    /// Read far more often than written — every list render, every swipe row —
    /// so the decode is done once and held until this process writes again.
    nonisolated(unsafe) private static var cache: [SavedChat]?

    static func all() -> [SavedChat] {
        if let cache { return cache }
        guard let data = defaults.data(forKey: key),
            let saved = try? JSONDecoder().decode([SavedChat].self, from: data)
        else {
            cache = []
            return []
        }
        let sorted = saved.sorted { $0.savedAt > $1.savedAt }
        cache = sorted
        return sorted
    }

    static var isEmpty: Bool { all().isEmpty }

    static func contains(profileID: String, sessionID: String) -> Bool {
        all().contains { $0.profileID == profileID && $0.sessionID == sessionID }
    }

    static func contains(_ entry: SessionEntry) -> Bool {
        contains(profileID: entry.profileID, sessionID: entry.session.id)
    }

    @discardableResult
    static func toggle(_ entry: SessionEntry) -> Bool {
        if contains(entry) {
            remove(profileID: entry.profileID, sessionID: entry.session.id)
            return false
        }
        save(entry)
        return true
    }

    static func save(_ entry: SessionEntry) {
        var list = all().filter {
            !($0.profileID == entry.profileID && $0.sessionID == entry.session.id)
        }
        list.insert(
            SavedChat(
                profileID: entry.profileID,
                sessionID: entry.session.id,
                title: entry.session.title,
                profileName: entry.profileName,
                backend: entry.backendType,
                directory: entry.session.directory,
                updatedAt: entry.session.updatedAt,
                savedAt: Date()),
            at: 0)
        write(Array(list.prefix(capacity)))
    }

    static func remove(profileID: String, sessionID: String) {
        let list = all()
        let trimmed = list.filter { !($0.profileID == profileID && $0.sessionID == sessionID) }
        guard trimmed.count != list.count else { return }
        write(trimmed)
    }

    /// Drops every bookmark belonging to a server the user disconnected. A saved
    /// chat on a server that no longer exists can never be opened again.
    static func removeAll(profileID: String) {
        let list = all()
        let trimmed = list.filter { $0.profileID != profileID }
        guard trimmed.count != list.count else { return }
        write(trimmed)
    }

    /// Re-snapshots saved chats from a fresh listing, so a renamed or advanced
    /// conversation reads correctly here even while its server is later offline.
    /// Silent by design — this runs on every list load and must not churn the UI.
    static func reconcile(with entries: [SessionEntry]) {
        let live = Dictionary(
            entries.map { ("\($0.profileID)\u{1}\($0.session.id)", $0) },
            uniquingKeysWith: { first, _ in first })
        var list = all()
        var changed = false
        for index in list.indices {
            guard let entry = live["\(list[index].profileID)\u{1}\(list[index].sessionID)"]
            else { continue }
            let refreshed = SavedChat(
                profileID: list[index].profileID,
                sessionID: list[index].sessionID,
                title: entry.session.title,
                profileName: entry.profileName,
                backend: entry.backendType,
                directory: entry.session.directory,
                updatedAt: entry.session.updatedAt,
                savedAt: list[index].savedAt)
            if refreshed.title != list[index].title
                || refreshed.updatedAt != list[index].updatedAt
                || refreshed.profileName != list[index].profileName
                || refreshed.directory != list[index].directory
            {
                list[index] = refreshed
                changed = true
            }
        }
        guard changed else { return }
        write(list, notify: false)
    }

    private static func write(_ list: [SavedChat], notify: Bool = true) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
        cache = list.sorted { $0.savedAt > $1.savedAt }
        if notify {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
