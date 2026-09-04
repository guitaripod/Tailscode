import CodingAgentKit
import Foundation

/// A conversation the user chose to keep. Carries its own copy of everything
/// needed to draw a row, because the point of saving a chat is to still find it
/// when the server that hosts it is asleep, unreachable, or gone.
public struct SavedChat: Codable, Hashable, Sendable {
    public let profileID: String
    public let sessionID: String
    public var title: String
    public var profileName: String
    public var backend: AgentType
    public var directory: String?
    public var updatedAt: Date
    public var savedAt: Date

    public init(
        profileID: String,
        sessionID: String,
        title: String,
        profileName: String,
        backend: AgentType,
        directory: String?,
        updatedAt: Date,
        savedAt: Date
    ) {
        self.profileID = profileID
        self.sessionID = sessionID
        self.title = title
        self.profileName = profileName
        self.backend = backend
        self.directory = directory
        self.updatedAt = updatedAt
        self.savedAt = savedAt
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentSession.isPlaceholderTitle(trimmed) else { return trimmed }
        return trimmed.isEmpty
            ? Localized.text("Empty conversation")
            : Localized.text("New conversation")
    }

    public var projectName: String? {
        directory.map { ($0 as NSString).lastPathComponent }
    }

    public static func == (lhs: SavedChat, rhs: SavedChat) -> Bool {
        lhs.profileID == rhs.profileID && lhs.sessionID == rhs.sessionID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(profileID)
        hasher.combine(sessionID)
    }
}

/// A bookmark this device has made or dropped and the server has not been told about yet.
public struct PendingSaveIntent: Codable, Hashable, Sendable {
    public let profileID: String
    public let sessionID: String
    public let saved: Bool
    public let at: Date

    public init(profileID: String, sessionID: String, saved: Bool, at: Date = Date()) {
        self.profileID = profileID
        self.sessionID = sessionID
        self.saved = saved
        self.at = at
    }

    public var key: String { "\(profileID)\u{1}\(sessionID)" }
}

/// Saved chats: the list is device-local, the bookmark is the server's.
///
/// A bookmark is a fact about a conversation rather than about the phone that made it — a chat
/// saved from the couch is what a person goes looking for at the desk an hour later — so a server
/// that can keep one (``BackendCapabilities/supportsSavedChats``) is the authority, and every
/// client reading its listing sees the same shortlist. The list stays written here anyway, whole:
/// the point of a saved chat is to still find it when its server is asleep, unreachable or gone,
/// which is exactly when there is nobody to ask.
///
/// A mark made while that server could not be reached is not lost and not silently reverted: it is
/// held as a ``PendingSaveIntent`` that outranks whatever the listing says until the server has
/// been told, and ``SavedChatSync`` is what tells it. A server with no notion of a bookmark leaves
/// the mark where it has always been — on the device — and the intent is retired unsent.
public enum SavedChatStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let storageKey = "tailscode.saved.chats"
    static let pendingKey = "tailscode.saved.pending"
    private static let capacity = 200

    public static let didChange = Notification.Name("tailscode.saved.didChange")

    /// Read far more often than written — every list render, every swipe row —
    /// so the decode is done once and held until this process writes again.
    nonisolated(unsafe) private static var cache: [SavedChat]?
    nonisolated(unsafe) private static var pendingCache: [PendingSaveIntent]?

    /// The process cache is what makes the list cheap to read on every render, so a suite that
    /// emptied `UserDefaults` behind it would be testing a list this process no longer believes in.
    static func forgetForTesting() {
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: pendingKey)
        cache = nil
        pendingCache = nil
    }

    public static func all() -> [SavedChat] {
        if let cache { return cache }
        guard let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode([SavedChat].self, from: data)
        else {
            cache = []
            return []
        }
        let sorted = saved.sorted { $0.savedAt > $1.savedAt }
        cache = sorted
        return sorted
    }

    public static var isEmpty: Bool { all().isEmpty }

    public static func contains(profileID: String, sessionID: String) -> Bool {
        all().contains { $0.profileID == profileID && $0.sessionID == sessionID }
    }

    public static func contains(_ entry: SessionEntry) -> Bool {
        contains(profileID: entry.profileID, sessionID: entry.session.id)
    }

    @discardableResult
    public static func toggle(_ entry: SessionEntry) -> Bool {
        if contains(entry) {
            remove(profileID: entry.profileID, sessionID: entry.session.id)
            return false
        }
        save(entry)
        return true
    }

    public static func save(_ entry: SessionEntry) {
        note(PendingSaveIntent(profileID: entry.profileID, sessionID: entry.session.id, saved: true))
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

    public static func remove(profileID: String, sessionID: String) {
        note(PendingSaveIntent(profileID: profileID, sessionID: sessionID, saved: false))
        let list = all()
        let trimmed = list.filter { !($0.profileID == profileID && $0.sessionID == sessionID) }
        guard trimmed.count != list.count else { return }
        write(trimmed)
    }

    /// Drops every bookmark belonging to a server the user disconnected. A saved
    /// chat on a server that no longer exists can never be opened again.
    public static func removeAll(profileID: String) {
        let list = all()
        for chat in list where chat.profileID == profileID {
            forget(profileID: profileID, sessionID: chat.sessionID)
        }
        let trimmed = list.filter { $0.profileID != profileID }
        guard trimmed.count != list.count else { return }
        write(trimmed)
    }

    /// Re-snapshots saved chats from a fresh listing, so a renamed or advanced
    /// conversation reads correctly here even while its server is later offline.
    /// Silent by design — this runs on every list load and must not churn the UI.
    public static func reconcile(with entries: [SessionEntry]) {
        let live = Dictionary(
            entries.map { ("\($0.profileID)\u{1}\($0.session.id)", $0) },
            uniquingKeysWith: { first, _ in first })
        var list = all()
        var changed = false
        var membershipChanged = false
        let held = Set(pending().map(\.key))
        for entry in entries {
            guard let saved = entry.session.saved else { continue }
            let key = "\(entry.profileID)\u{1}\(entry.session.id)"
            guard !held.contains(key) else { continue }
            let index = list.firstIndex {
                $0.profileID == entry.profileID && $0.sessionID == entry.session.id
            }
            switch (saved, index) {
            case (true, nil):
                list.insert(
                    SavedChat(
                        profileID: entry.profileID, sessionID: entry.session.id,
                        title: entry.session.title, profileName: entry.profileName,
                        backend: entry.backendType, directory: entry.session.directory,
                        updatedAt: entry.session.updatedAt, savedAt: entry.session.updatedAt),
                    at: 0)
                changed = true
                membershipChanged = true
            case (false, .some(let index)):
                list.remove(at: index)
                changed = true
                membershipChanged = true
            default:
                break
            }
        }
        list = Array(list.prefix(capacity))
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
        write(list, notify: membershipChanged)
    }

    /// What this device has decided and its server has not been told.
    public static func pending() -> [PendingSaveIntent] {
        if let pendingCache { return pendingCache }
        guard let data = defaults.data(forKey: pendingKey),
            let stored = try? JSONDecoder().decode([PendingSaveIntent].self, from: data)
        else {
            pendingCache = []
            return []
        }
        pendingCache = stored
        return stored
    }

    /// Records what this device just decided, replacing any earlier undelivered decision about the
    /// same conversation — the last press is the one the server has to hear about.
    private static func note(_ intent: PendingSaveIntent) {
        writePending(pending().filter { $0.key != intent.key } + [intent])
    }

    /// Retires an intent: either the server has been told, or it turned out to have no notion of a
    /// bookmark and never will be.
    public static func forget(profileID: String, sessionID: String) {
        let key = "\(profileID)\u{1}\(sessionID)"
        let kept = pending().filter { $0.key != key }
        guard kept.count != pending().count else { return }
        writePending(kept)
    }

    private static func writePending(_ intents: [PendingSaveIntent]) {
        pendingCache = intents
        guard let data = try? JSONEncoder().encode(intents) else { return }
        defaults.set(data, forKey: pendingKey)
    }

    private static func write(_ list: [SavedChat], notify: Bool = true) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: storageKey)
        cache = list.sorted { $0.savedAt > $1.savedAt }
        if notify {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
