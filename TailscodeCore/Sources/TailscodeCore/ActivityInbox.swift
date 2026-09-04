import CodingAgentKit
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

    /// A notice raised before the server had named the conversation — every first turn, because
    /// the name is written from the answer the turn is still producing. The row is a way back into
    /// a chat, so a name it cannot be recognised by is the one thing it must not keep.
    public var hasPlaceholderTitle: Bool { AgentSession.isPlaceholderTitle(title) }

    /// What to call a conversation in a notice about it.
    ///
    /// The first turn is the one most worth telling someone about and the one the server has not
    /// named yet — it writes the name *from* that turn, after it ends — so a notice raised on time
    /// is a notice raised too early to know what to call it. The prompt is the next best name and
    /// the one the person will recognise, because they wrote it; only a chat with neither gets a
    /// stand-in. Shared so a banner, a row and a desktop notice never disagree about a chat.
    public static func name(title: String, latestPrompt: String?) -> String {
        guard AgentSession.isPlaceholderTitle(title) else { return title }
        guard let prompt = latestPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty
        else { return Localized.text("New conversation") }
        let named = AgentSession.provisionalTitle(fromPrompt: prompt)
        return AgentSession.isPlaceholderTitle(named) ? Localized.text("New conversation") : named
    }

    /// The same notice under the name the conversation goes by now. The event is the identifier
    /// and the moment; the title was only ever a copy of something the server owns.
    public func retitled(_ title: String) -> MissedActivity {
        MissedActivity(
            identifier: identifier, profileID: profileID, sessionID: sessionID, title: title,
            body: body, reason: reason, at: at)
    }
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

    /// Deliberately under the list's own key rather than beside it: the desktop's durable settings
    /// file captures state by key prefix, and a horizon that evaporated on the next launch would
    /// resurrect everything the person cleared that morning.
    static let clearedKey = "tailscode.activity.missed.cleared"

    /// How many edges are worth keeping. A day of a busy fleet is hundreds, and a list nobody can
    /// read to the end is the same as no list — the newest are the ones still worth acting on.
    public static let limit = 60

    /// How long a clear is remembered for. A notice's identifier is derived from stable data — the
    /// session, the permission, the question — so it names the same event forever, and a horizon
    /// kept forever would be a list of every notice the app ever raised. A day outlives every way
    /// a cleared notice comes back (a banner still in Notification Center, a request still pending
    /// through a relaunch) and nothing beyond that is still the same news.
    static let clearedHorizon: TimeInterval = 86_400

    public static let didChange = Notification.Name("tailscode.activity.missed.didChange")

    /// Read on every render of every surface that shows the list, written only when something
    /// happens, so the decode is done once and held until this process writes again.
    nonisolated(unsafe) private static var cache: [MissedActivity]?
    nonisolated(unsafe) private static var clearedCache: [String: Date]?
    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    /// The process cache is what makes the list cheap to read on every render, so a suite that
    /// emptied `UserDefaults` behind it would be testing a list this process no longer believes in.
    static func forgetForTesting() {
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: clearedKey)
        cache = nil
        clearedCache = nil
    }

    public static func all() -> [MissedActivity] {
        if let cache { return cache }
        guard let data = defaults.data(forKey: storageKey),
            let stored = try? decoder.decode([MissedActivity].self, from: data)
        else {
            cache = []
            return []
        }
        cache = stored
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
    /// The same, for notices read back from somewhere that kept them while the app was gone — a
    /// system notification centre, most of all — where the news may already be out of date.
    ///
    /// A turn that ended is news until that conversation is working again: the agent answered, was
    /// answered from another machine and is off doing the next thing, and a row saying it finished
    /// sends someone back to something they have already dealt with. Only a settled conversation
    /// can be missed. A request still waiting on a person is not covered by this — a live turn is
    /// exactly what a question blocks — so blocking notices are filed whatever the listing says.
    public static func record(_ entries: [MissedActivity], liveSessionIDs: Set<String>) {
        record(entries.filter { $0.isBlocking || !liveSessionIDs.contains($0.sessionID) })
    }

    public static func record(_ entries: [MissedActivity]) {
        guard !entries.isEmpty else { return }
        var current = all()
        let horizon = cleared()
        var changed = false
        for entry in entries
        where !current.contains(where: { $0.identifier == entry.identifier })
            && !wasCleared(entry, horizon: horizon)
        {
            current.insert(entry, at: 0)
            changed = true
        }
        guard changed else { return }
        write(Array(current.prefix(limit)))
    }

    /// Whether a notice is the one that was already dismissed rather than a new one wearing the
    /// same name.
    ///
    /// Every producer names its notice after the thing it is about — the session, the permission,
    /// the question — so the identifier alone cannot tell a re-raise from a repeat. The moment can:
    /// a notice is dismissed *after* it happened, so anything stamped at or before the clear is the
    /// same news coming back and anything after it is genuinely newer. This is what makes clearing
    /// stick against a banner still sitting in the system's own notification list, a request still
    /// pending across a relaunch, and a second client that never saw the clear.
    static func wasCleared(_ entry: MissedActivity, horizon: [String: Date]) -> Bool {
        guard let at = horizon[entry.identifier] else { return false }
        return entry.at <= at
    }

    static func cleared() -> [String: Date] {
        if let clearedCache { return clearedCache }
        let stored = defaults.dictionary(forKey: clearedKey) as? [String: Double] ?? [:]
        let horizon = stored.mapValues(Date.init(timeIntervalSince1970:))
        clearedCache = horizon
        return horizon
    }

    /// Records that these notices were dismissed, and forgets the dismissals old enough that the
    /// event behind them cannot still be in flight.
    private static func markCleared(_ identifiers: [String], at now: Date) {
        guard !identifiers.isEmpty else { return }
        var horizon = cleared()
        let floor = now.addingTimeInterval(-clearedHorizon)
        horizon = horizon.filter { $0.value > floor }
        for identifier in identifiers { horizon[identifier] = now }
        clearedCache = horizon
        defaults.set(horizon.mapValues(\.timeIntervalSince1970), forKey: clearedKey)
    }

    /// Holds the list against what the servers are saying right now.
    ///
    /// A notice is a pointer at a conversation, not a copy of it, and it is written at the worst
    /// possible moment to copy anything: the turn has just ended, so the name the server derives
    /// from that turn does not exist yet and the row reads "New chat" until it is tapped. The same
    /// staleness runs deeper — the chat may have been deleted since, or answered from another
    /// machine and be running again, and a list that keeps saying otherwise sends someone to old
    /// news. So every listing refresh is also a chance to be honest: adopt the name the server now
    /// gives each conversation, drop what no longer exists, and drop finished-news for a session
    /// that is working again. A request still waiting on a person stays whatever else is true —
    /// only being answered withdraws it.
    ///
    /// - Parameter authoritativeProfileIDs: the servers this listing actually heard from. An
    ///   unreachable server says nothing about its sessions, and treating its silence as deletion
    ///   would empty the list exactly when the app can least afford to lose it.
    public static func reconcile(
        _ rows: [ActivityObservation], authoritativeProfileIDs: Set<String>
    ) {
        let current = all()
        guard let next = reconciled(current, rows: rows, authoritative: authoritativeProfileIDs)
        else { return }
        write(next)
    }

    /// The decision behind ``reconcile(_:authoritativeProfileIDs:)``, as a value: the new list, or
    /// nil when nothing about it changed — a refresh that changes nothing must not post.
    static func reconciled(
        _ entries: [MissedActivity], rows: [ActivityObservation], authoritative: Set<String>
    ) -> [MissedActivity]? {
        guard !entries.isEmpty else { return nil }
        var known: [String: ActivityObservation] = [:]
        for row in rows { known["\(row.profileID)/\(row.sessionID)"] = row }
        var next: [MissedActivity] = []
        var changed = false
        for entry in entries {
            guard let row = known["\(entry.profileID)/\(entry.sessionID)"] else {
                if authoritative.contains(entry.profileID) { changed = true; continue }
                next.append(entry)
                continue
            }
            if row.isActive, !entry.isBlocking {
                changed = true
                continue
            }
            guard !AgentSession.isPlaceholderTitle(row.title), row.title != entry.title else {
                next.append(entry)
                continue
            }
            next.append(entry.retitled(row.title))
            changed = true
        }
        return changed ? next : nil
    }

    /// A request answered on the server is no longer something you missed. The notifier withdraws
    /// the notice for exactly this reason, and a list left holding it would send someone to a chat
    /// that is waiting on nothing.
    public static func withdraw(_ identifiers: [String], at now: Date = Date()) {
        guard !identifiers.isEmpty else { return }
        let dropped = Set(identifiers)
        let current = all()
        let kept = current.filter { !dropped.contains($0.identifier) }
        markCleared(identifiers, at: now)
        guard kept.count != current.count else { return }
        write(kept)
    }

    /// Opening a chat is looking at it, which is the only thing that clears its edges — a glance at
    /// the list is not, or the list would empty itself the moment it was drawn.
    public static func clear(sessionID: String, at now: Date = Date()) {
        let current = all()
        let kept = current.filter { $0.sessionID != sessionID }
        markCleared(
            current.filter { $0.sessionID == sessionID }.map(\.identifier), at: now)
        guard kept.count != current.count else { return }
        write(kept)
    }

    public static func clearAll(at now: Date = Date()) {
        let current = all()
        guard !current.isEmpty else { return }
        markCleared(current.map(\.identifier), at: now)
        write([])
    }

    private static func write(_ entries: [MissedActivity]) {
        cache = entries
        if let data = try? encoder.encode(entries) {
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
