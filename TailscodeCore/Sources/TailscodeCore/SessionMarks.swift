import CodingAgentKit
import Foundation

/// A decision about a conversation that a server keeps besides the bookmark: pinned, archived,
/// and whether the person has looked at it since it last moved.
public enum SessionMark: String, Codable, Sendable, CaseIterable {
    case pinned
    case archived
    case read
}

/// A decision this device has made and the server that holds the conversation has not been told.
///
/// Every press answers instantly from the device and may be made with no server in reach, so it
/// never waits on the wire. It leaves one of these behind; the intent outranks whatever a listing
/// says about the same mark until it is delivered, and ``SessionMarkSync`` delivers it. `on` is the
/// new state for a pin or an archive, and for a read mark it is `true` for "I have looked" and
/// `false` for "set this aside as unread".
public struct MarkIntent: Codable, Hashable, Sendable {
    public let sessionID: String
    public var profileID: String?
    public let mark: SessionMark
    public let on: Bool
    public let at: Date

    public init(
        sessionID: String, profileID: String?, mark: SessionMark, on: Bool, at: Date = Date()
    ) {
        self.sessionID = sessionID
        self.profileID = profileID
        self.mark = mark
        self.on = on
        self.at = at
    }

    var key: String { "\(sessionID)\u{1}\(mark.rawValue)" }

    /// The wire form of this one decision, stamped with when it was made.
    public var change: SessionMarkChange {
        switch mark {
        case .pinned: return SessionMarkChange(pinned: on, at: at)
        case .archived: return SessionMarkChange(archived: on, at: at)
        case .read: return SessionMarkChange(read: on ? .seen : .unread, at: at)
        }
    }
}

/// The decisions waiting to be told, newest per mark per conversation. Safe to touch from any
/// thread: the press that makes an intent is on the main thread and the delivery that retires one
/// is not.
public enum MarkIntentStore {
    static let storageKey = "tailscode.marks.pending"
    private static let capacity = 400
    private static let lifetime: TimeInterval = 14 * 24 * 3600

    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [MarkIntent]?

    public static func all() -> [MarkIntent] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    /// Records what the person just decided, replacing any earlier undelivered decision about the
    /// same mark of the same conversation — the last press is the one the server has to hear.
    public static func note(
        sessionID: String, profileID: String? = nil, mark: SessionMark, on: Bool,
        at: Date = Date()
    ) {
        let intent = MarkIntent(
            sessionID: sessionID, profileID: profileID, mark: mark, on: on, at: at)
        lock.lock()
        var list = load().filter { $0.key != intent.key }
        list.append(intent)
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        store(list)
        lock.unlock()
        SessionMarkSync.shared.schedule()
    }

    /// Retires an intent that was delivered or refused for good. An intent that has been replaced
    /// by a newer press while it was in flight stays: only the one that was sent is done.
    ///
    /// A delivered one is remembered for a few seconds more (``holding(_:)``): a listing that was
    /// asked for before the server heard the press can land after it, and would read the old
    /// answer as the server's last word.
    public static func forget(_ intent: MarkIntent, delivered: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let list = load()
        let kept = list.filter { !($0.key == intent.key && $0.at == intent.at) }
        if kept.count != list.count { store(kept) }
        if delivered {
            recent[intent.key] = (intent.sessionID, intent.mark, Date())
        }
    }

    /// How long a delivered decision still outranks a listing.
    static let settling: TimeInterval = 6

    nonisolated(unsafe) private static var recent: [String: (String, SessionMark, Date)] = [:]

    /// Drops every undelivered decision about a conversation that no longer exists.
    public static func discard(sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        let list = load()
        let kept = list.filter { $0.sessionID != sessionID }
        if kept.count != list.count { store(kept) }
    }

    /// The conversations with an undelivered decision about `mark` — the ones a listing must not
    /// be allowed to overrule.
    public static func holding(_ mark: SessionMark) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var held = Set(load().lazy.filter { $0.mark == mark }.map(\.sessionID))
        let cutoff = Date().addingTimeInterval(-settling)
        recent = recent.filter { $0.value.2 > cutoff }
        for value in recent.values where value.1 == mark { held.insert(value.0) }
        return held
    }

    static func forgetAllForTesting() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
        cache = nil
        recent = [:]
    }

    private static func load() -> [MarkIntent] {
        if let cache { return cache }
        guard let data = defaults.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode([MarkIntent].self, from: data)
        else {
            cache = []
            return []
        }
        let fresh = stored.filter { Date().timeIntervalSince($0.at) < lifetime }
        cache = fresh
        return fresh
    }

    private static func store(_ list: [MarkIntent]) {
        cache = list
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Which server a conversation lives on, as far as the listings read so far say. A press that
/// names only a session — marking a chat read is `markSeen(sessionID)`, from a dozen places — is
/// delivered to the profile this remembers, and waits for a listing when it does not know yet.
public enum SessionOwners {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var owners: [String: String] = [:]
    private static let capacity = 4000

    public static func remember(_ entries: some Sequence<SessionEntry>) {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries { owners[entry.session.id] = entry.profileID }
        if owners.count > capacity { owners = [:] }
    }

    public static func profile(of sessionID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return owners[sessionID]
    }

    static func forgetAllForTesting() {
        lock.lock()
        defer { lock.unlock() }
        owners = [:]
    }
}
