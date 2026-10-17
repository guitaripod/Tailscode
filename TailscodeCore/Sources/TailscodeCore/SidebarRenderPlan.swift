import CodingAgentKit
import Foundation

/// The arithmetic of drawing a list no more often than anybody can read it. A request either runs
/// at once (nothing ran lately), is promised a single trailing run at the end of the interval, or
/// is covered by the run already promised — so a burst of any length costs the one run that went
/// first and the one that closes it, and the last request is never lost.
///
/// A promise is a token. The timer that fires it hands the token back, and a run that happened
/// some other way in the meantime (a flush, a longer interval) has already spent it, so a timer
/// that outlives its purpose does nothing.
public struct RenderCoalescer: Sendable {
    public enum Verdict: Equatable, Sendable {
        case runNow
        case wait(TimeInterval, token: Int)
        case covered
    }

    private var lastRun: TimeInterval?
    private var promised: Int?
    private var issued = 0

    public init() {}

    public var isWaiting: Bool { promised != nil }

    public mutating func request(at now: TimeInterval, interval: TimeInterval) -> Verdict {
        guard promised == nil else { return .covered }
        guard let lastRun, now - lastRun < interval else {
            lastRun = now
            return .runNow
        }
        issued += 1
        promised = issued
        return .wait(max(0, lastRun + interval - now), token: issued)
    }

    /// The timer for `token` fired: true when the run it was promised is still owed.
    public mutating func fire(token: Int, at now: TimeInterval) -> Bool {
        guard promised == token else { return false }
        promised = nil
        lastRun = now
        return true
    }

    /// A run is happening right now whatever was asked: it satisfies every request so far.
    public mutating func flush(at now: TimeInterval) {
        promised = nil
        lastRun = now
    }

    public mutating func reset() {
        promised = nil
        lastRun = nil
    }
}

/// How long the chat list waits between two draws.
public enum SidebarCadence {
    /// A window nobody can see still has to notice a turn ending, so it is drawn on a slow clock
    /// rather than not at all; one that can be seen stretches with the governor's shed level.
    public static func interval(at level: ShedLevel, visible: Bool) -> TimeInterval {
        guard visible else { return 1 }
        switch level {
        case .calm, .busy: return 0.1
        case .loaded: return 0.25
        case .strained: return 0.5
        case .critical: return 1
        }
    }

    /// The gather for list pushes: the same 80 ms the phone folds a burst of list changes into.
    public static let listGather: TimeInterval = 0.08
}

extension SessionPresence {
    /// What a row can show of this reading. A running step that says nothing is the same row as
    /// one with no step.
    public var sidebarReading: SessionPresence {
        if case .running(let step) = self, step?.isEmpty == true { return .running(nil) }
        return self
    }
}

/// The row models of the last pass, kept by session, so a pass over a thousand chats rebuilds the
/// few whose inputs moved. A model is derived from the listing's entry, the flags the stores hold
/// and what this device is watching, and each of those is compared before a model is trusted;
/// the age is compared as the string the row draws, so a column that ticks over still redraws.
public struct SessionRowModelCache: Sendable {
    private struct Slot: Sendable {
        var entry: SessionEntry
        var unreachable: Bool
        var unread: Bool
        var saved: Bool
        var pinned: Bool
        var presence: SessionPresence
        var age: String
        var pass: Int
        var model: SessionRowModel
    }

    private var slots: [String: Slot] = [:]
    private var pass = 0
    private var rebuilt: Set<String> = []

    public private(set) var hits = 0
    public private(set) var misses = 0

    public init() {}

    public mutating func beginPass() {
        pass += 1
        hits = 0
        misses = 0
    }

    public mutating func model(
        for entry: SessionEntry, unreachable: Bool, unread: Bool, saved: Bool, pinned: Bool,
        presence: SessionPresence, observedAt: Date?, now: Date = Date()
    ) -> SessionRowModel {
        model(
            for: entry, key: SessionPinStore.key(entry.profileID, entry.session.id),
            unreachable: unreachable, unread: unread, saved: saved, pinned: pinned,
            presence: presence, observedAt: observedAt, now: now)
    }

    /// The same, for a caller that already holds the entry's key and would otherwise build it twice.
    public mutating func model(
        for entry: SessionEntry, key: String, unreachable: Bool, unread: Bool, saved: Bool,
        pinned: Bool, presence: SessionPresence, observedAt: Date?, now: Date = Date()
    ) -> SessionRowModel {
        let reading = presence.sidebarReading
        let age = SessionRowModel.age(
            of: entry.session.updatedAt, asOf: unreachable ? (observedAt ?? now) : now)
        if var slot = slots[key], slot.entry.session == entry.session,
            slot.entry.profileName == entry.profileName, slot.entry.host == entry.host, slot.entry.backendType == entry.backendType,
            slot.unreachable == unreachable, slot.unread == unread, slot.saved == saved,
            slot.pinned == pinned, slot.presence == reading, slot.age == age,
            entry.session.backgroundWork?.since == nil
        {
            slot.pass = pass
            slots[key] = slot
            hits += 1
            return slot.model
        }
        let model = SessionRowModel(
            entry: entry, unreachable: unreachable, unread: unread, saved: saved, pinned: pinned,
            presence: presence, observedAt: observedAt, now: now)
        slots[key] = Slot(
            entry: entry, unreachable: unreachable, unread: unread, saved: saved, pinned: pinned,
            presence: reading, age: age, pass: pass, model: model)
        rebuilt.insert(key)
        misses += 1
        return model
    }

    /// Forgets the chats the last pass did not ask about.
    public mutating func sweep() {
        guard slots.count > hits + misses else { return }
        slots = slots.filter { $0.value.pass == pass }
    }

    /// The keys whose model was rebuilt since this was last taken: what a drawn list has to
    /// compare, because every other row is the model it already drew.
    public mutating func takeRebuilt() -> Set<String> {
        defer { rebuilt = [] }
        return rebuilt
    }
}

/// The newest-first listing, kept in order by placing one change rather than sorting the lot.
public enum SessionListOrder {
    public static func isNewestFirst(_ entries: [SessionEntry]) -> Bool {
        var previous: Date?
        for entry in entries {
            if let previous, entry.session.updatedAt > previous { return false }
            previous = entry.session.updatedAt
        }
        return true
    }

    /// What replacing the chat and sorting by recency would give, found by placing the one entry:
    /// after every chat as recent as it is, which is where a stable sort would leave an entry
    /// appended at the end. The listing must already be newest-first.
    public static func upsert(_ entry: SessionEntry, into entries: inout [SessionEntry]) {
        let updated = entry.session.updatedAt
        if let index = entries.firstIndex(where: {
            $0.profileID == entry.profileID && $0.session.id == entry.session.id
        }) {
            let settled =
                entries[index].session.updatedAt == updated
                && (index + 1 == entries.count || entries[index + 1].session.updatedAt < updated)
            if settled {
                entries[index] = entry
                return
            }
            entries.remove(at: index)
        }
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].session.updatedAt < updated {
                high = middle
            } else {
                low = middle + 1
            }
        }
        entries.insert(entry, at: low)
    }

    public static func remove(profileID: String, sessionID: String, from entries: inout [SessionEntry]) {
        entries.removeAll { $0.profileID == profileID && $0.session.id == sessionID }
    }
}
