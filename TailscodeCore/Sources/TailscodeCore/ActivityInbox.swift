import Foundation

/// One thing that happened while you were not looking, kept until you have looked.
public struct MissedActivity: Codable, Hashable, Sendable, Identifiable {
    public enum Reason: String, Codable, Hashable, Sendable {
        case turnEnded
        case turnFailed
        case needsApproval
        case needsAnswer
    }

    public let identifier: String
    public let profileID: String
    public let sessionID: String
    public let title: String
    public let body: String
    public let reason: Reason
    public let at: Date

    public init(
        identifier: String, profileID: String, sessionID: String, title: String, body: String,
        reason: Reason, at: Date = Date()
    ) {
        self.identifier = identifier
        self.profileID = profileID
        self.sessionID = sessionID
        self.title = title
        self.body = body
        self.reason = reason
        self.at = at
    }

    public var id: String { identifier }

    /// What the row says about itself, in the same vocabulary the status band uses.
    public var kindLabel: String {
        switch reason {
        case .turnEnded: return Localized.text("finished")
        case .turnFailed: return Localized.text("failed")
        case .needsApproval: return Localized.text("needs approval")
        case .needsAnswer: return Localized.text("has a question")
        }
    }

    public var isBlocking: Bool { reason == .needsApproval || reason == .needsAnswer }
}

/// What happened while you were away.
///
/// `ActivityWatch` finds the edges worth raising and the client turns each into a desktop or
/// system notification — which is a thing that appears for a few seconds and is then gone whether
/// or not anybody saw it. A notification missed is the whole event lost: an agent that finished an
/// hour ago and a question asked twenty minutes ago leave no trace anywhere in the app, and the
/// only way to find them is to open every chat. So every alert the client raises is also written
/// down here, and stays written down until it is either answered on the server (the same
/// withdrawal that takes the notification back) or actually looked at.
///
/// Device-local on purpose, like the archive and the seen marks: two machines watching the same
/// tailnet have each missed different things, and "what I have not looked at" is a fact about a
/// person at a screen, not about a session on a server.
public enum ActivityInbox {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let storageKey = "tailscode.activity.missed"

    /// How many edges are worth keeping. A day of a busy fleet is hundreds, and a list nobody can
    /// read to the end is the same as no list — the newest are the ones still worth acting on.
    public static let limit = 60

    public static let didChange = Notification.Name("tailscode.activity.missed.didChange")

    public static func all() -> [MissedActivity] {
        guard let data = defaults.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode([MissedActivity].self, from: data)
        else { return [] }
        return stored
    }

    public static var count: Int { all().count }

    /// What a list should show: the ones still blocking a turn first, then the rest by when they
    /// happened, and only as many as can be read in one look. Shared because all three clients
    /// were about to answer this question the same way, and a list that ordered itself differently
    /// on one desk would be a different feature wearing the same name.
    public static func ordered(limit: Int) -> (shown: [MissedActivity], total: Int) {
        let entries = all()
        let sorted = entries.sorted { lhs, rhs in
            if lhs.isBlocking != rhs.isBlocking { return lhs.isBlocking }
            return lhs.at > rhs.at
        }
        return (Array(sorted.prefix(limit)), entries.count)
    }

    /// Records what the client just raised. Same identifier as the notification it accompanies, so
    /// a repeat render cannot stack duplicates and a withdrawal can take both back by name.
    public static func record(_ alerts: [ActivityAlert], at now: Date = Date()) {
        record(
            alerts.map {
                MissedActivity(
                    identifier: $0.identifier, profileID: $0.profileID, sessionID: $0.sessionID,
                    title: $0.title, body: $0.body, reason: Reason.from($0.reason), at: now)
            })
    }

    /// The same, for a client that raises its notifications from its own state rather than through
    /// `ActivityWatch`. What matters is that the list and the notifications are written by one
    /// decision — a notice suppressed by preference was never raised, so it was never missed.
    public static func record(_ entries: [MissedActivity]) {
        guard !entries.isEmpty else { return }
        var current = all()
        var changed = false
        for entry in entries where !current.contains(where: { $0.identifier == entry.identifier }) {
            current.insert(entry, at: 0)
            changed = true
        }
        guard changed else { return }
        write(Array(current.prefix(limit)))
    }

    /// A request answered on the server is no longer something you missed. The notifier withdraws
    /// the notice for exactly this reason, and a list left holding it would send someone to a chat
    /// that is waiting on nothing.
    public static func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let dropped = Set(identifiers)
        let current = all()
        let kept = current.filter { !dropped.contains($0.identifier) }
        guard kept.count != current.count else { return }
        write(kept)
    }

    /// Opening a chat is looking at it, which is the only thing that clears its edges — a glance at
    /// the list is not, or the list would empty itself the moment it was drawn.
    public static func clear(sessionID: String) {
        let current = all()
        let kept = current.filter { $0.sessionID != sessionID }
        guard kept.count != current.count else { return }
        write(kept)
    }

    public static func clearAll() {
        guard !all().isEmpty else { return }
        write([])
    }

    private static func write(_ entries: [MissedActivity]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private enum Reason {
        static func from(_ reason: ActivityAlert.Reason) -> MissedActivity.Reason {
            switch reason {
            case .turnEnded: return .turnEnded
            case .turnFailed: return .turnFailed
            case .needsApproval: return .needsApproval
            case .needsAnswer: return .needsAnswer
            }
        }
    }
}
