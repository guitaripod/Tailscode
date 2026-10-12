import CodingAgentKit
import Foundation

/// Brings what this device holds about conversations into line with what their servers say.
///
/// Called with a listing the server has just answered, or with the rows its stream has just
/// pushed — never with rows read back from a cache, which describe an hour ago and would undo a
/// press delivered since. For each mark a server reports, the server's answer is adopted unless
/// this device is holding an undelivered decision about it, which outranks the listing until the
/// server has been told. A server that reports nothing for a mark (opencode, a bridge older than
/// marks) is left alone: the mark is the device's own.
public enum SessionMarks {
    public static func reconcile(with entries: [SessionEntry]) {
        guard !entries.isEmpty else { return }
        SessionOwners.remember(entries)
        SavedChatStore.reconcile(with: entries)
        let reporting = entries.filter { $0.session.reportsMarks }
        offerLocalDecisions(toProfiles: Set(reporting.map(\.profileID)))
        reconcilePins(reporting)
        reconcileArchive(reporting)
        reconcileReads(entries)
    }

    /// A decision older than any a person could have made, which a server applies only to a mark
    /// it holds no decision about: the bridge keeps the later of two decisions, so offering this
    /// can fill a gap and can never overrule anything.
    static let beforeAnyDecision = Date(timeIntervalSince1970: 946_684_800)

    /// Hands a server the pins and archives this device made while it could not keep them.
    ///
    /// A server that begins reporting marks — a bridge just updated, or restarted onto a build that
    /// has them — answers `pinned: false` for every chat it has never heard about, and adopting that
    /// answer would erase the pins a person made on this device in the meantime. So the first time a
    /// profile is seen reporting, each local pin and archive for it is offered as the decision it
    /// always was: the pin at the moment it was made, the archive before any decision (the device
    /// never recorded when). Each leaves an intent, which outranks the listing until it is
    /// delivered, so nothing is lost on the way, and the server weighs it against anything it was
    /// told since, so nothing is overruled either. Offered once per profile.
    static func offerLocalDecisions(toProfiles profiles: Set<String>) {
        let fresh = profiles.subtracting(MarkOffers.made())
        guard !fresh.isEmpty else { return }
        let stamps = SessionPinStore.stamps()
        for key in SessionPinStore.all() {
            guard let (profile, session) = split(key), fresh.contains(profile) else { continue }
            let at = stamps[key].map(Date.init(timeIntervalSince1970:)) ?? beforeAnyDecision
            MarkIntentStore.note(
                sessionID: session, profileID: profile, mark: .pinned, on: true, at: at)
        }
        for key in ArchivedChatStore.all() {
            guard let (profile, session) = split(key), fresh.contains(profile) else { continue }
            MarkIntentStore.note(
                sessionID: session, profileID: profile, mark: .archived, on: true,
                at: beforeAnyDecision)
        }
        MarkOffers.record(fresh)
    }

    private static func split(_ key: String) -> (profile: String, session: String)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        return (String(key[..<slash]), String(key[key.index(after: slash)...]))
    }

    /// What to tell a person whose pin or archive will not leave this device, or nil when it will.
    ///
    /// A server that reports no marks (opencode, a bridge older than 1.14 — or one still running a
    /// binary built before it) keeps nothing a person decides, and says so only by silence, so a pin
    /// made on it is on this device and nowhere else. Without a word, that reads as a sync that
    /// does not work.
    public static func deviceOnlyNotice(for entry: SessionEntry) -> String? {
        guard !entry.session.reportsMarks else { return nil }
        return Localized.text(
            "Kept on this device only — %@ cannot keep pins or archives yet",
            ServerLabel.display(name: entry.profileName, backend: entry.backendType))
    }

    private static func reconcilePins(_ entries: [SessionEntry]) {
        guard !entries.isEmpty else { return }
        let reports = entries.compactMap { entry -> MarkReconcile.PinReport? in
            guard let pinned = entry.session.pinned else { return nil }
            return MarkReconcile.PinReport(
                key: SessionPinStore.key(entry.profileID, entry.session.id),
                sessionID: entry.session.id, pinned: pinned,
                at: entry.session.pinnedAt?.timeIntervalSince1970)
        }
        guard
            let plan = MarkReconcile.pins(
                current: SessionPinStore.all(), stamps: SessionPinStore.stamps(), reports: reports,
                held: MarkIntentStore.holding(.pinned), now: Date().timeIntervalSince1970)
        else { return }
        SessionPinStore.adopt(order: plan.order, stamps: plan.stamps)
    }

    private static func reconcileArchive(_ entries: [SessionEntry]) {
        guard !entries.isEmpty else { return }
        let reports = entries.compactMap { entry -> MarkReconcile.ArchiveReport? in
            guard let archived = entry.session.archived else { return nil }
            return MarkReconcile.ArchiveReport(
                key: ArchivedChatStore.key(entry.profileID, entry.session.id),
                sessionID: entry.session.id, archived: archived)
        }
        let plan = MarkReconcile.archive(
            current: ArchivedChatStore.all(), reports: reports,
            held: MarkIntentStore.holding(.archived))
        guard !plan.add.isEmpty || !plan.remove.isEmpty else { return }
        ArchivedChatStore.adopt(add: plan.add, remove: plan.remove)
    }

    private static func reconcileReads(_ entries: [SessionEntry]) {
        let reports = entries.compactMap { entry -> (sessionID: String, readAt: Double)? in
            entry.session.readAt.map { (entry.session.id, $0.timeIntervalSince1970) }
        }
        guard !reports.isEmpty else { return }
        let changes = MarkReconcile.reads(
            local: SessionSeenStore.values(), reports: reports,
            held: MarkIntentStore.holding(.read))
        SessionSeenStore.adopt(changes)
    }
}

/// The decisions behind ``SessionMarks/reconcile(with:)``, as values.
enum MarkReconcile {
    struct PinReport: Equatable {
        let key: String
        let sessionID: String
        let pinned: Bool
        let at: Double?
    }

    struct PinPlan: Equatable {
        var order: [String]
        var stamps: [String: Double]
    }

    struct ArchiveReport: Equatable {
        let key: String
        let sessionID: String
        let archived: Bool
    }

    /// The pins in the order every device reads them in: by when each was pinned, which the server
    /// stamps. A pin made here and not yet delivered is stamped with this device's clock until the
    /// server's arrives; a pin on a server that stamps nothing keeps the place it was made in,
    /// ahead of nothing. Nil when nothing changes.
    static func pins(
        current: [String], stamps: [String: Double], reports: [PinReport], held: Set<String>,
        now: Double
    ) -> PinPlan? {
        var order = current
        var stamps = stamps
        var members = Set(current)
        var changed = false
        for report in reports where !held.contains(report.sessionID) {
            if report.pinned {
                if members.insert(report.key).inserted {
                    order.append(report.key)
                    changed = true
                }
                let at = report.at ?? stamps[report.key] ?? now
                if stamps[report.key] != at {
                    stamps[report.key] = at
                    changed = true
                }
            } else if members.remove(report.key) != nil {
                order.removeAll { $0 == report.key }
                stamps[report.key] = nil
                changed = true
            }
        }
        let ranked = order.enumerated().sorted { lhs, rhs in
            let left = stamps[lhs.element] ?? -.infinity
            let right = stamps[rhs.element] ?? -.infinity
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
        guard changed || ranked != current else { return nil }
        return PinPlan(order: ranked, stamps: stamps)
    }

    static func archive(
        current: Set<String>, reports: [ArchiveReport], held: Set<String>
    ) -> (add: Set<String>, remove: Set<String>) {
        var add = Set<String>()
        var remove = Set<String>()
        for report in reports where !held.contains(report.sessionID) {
            let has = current.contains(report.key)
            if report.archived, !has { add.insert(report.key) }
            if !report.archived, has { remove.insert(report.key) }
        }
        return (add, remove)
    }

    /// The read marks to take from the server: those it holds that differ from this device's, for
    /// conversations nobody here has an undelivered decision about. The server's clock is the
    /// one a chat's last change is read on, so its time is taken over this device's own.
    static func reads(
        local: [String: Double], reports: [(sessionID: String, readAt: Double)], held: Set<String>
    ) -> [String: Double] {
        var changes: [String: Double] = [:]
        for report in reports where !held.contains(report.sessionID) {
            if let mine = local[report.sessionID], abs(mine - report.readAt) <= 0.5 { continue }
            changes[report.sessionID] = report.readAt
        }
        return changes
    }
}

/// The profiles whose servers have been offered this device's pins and archives, so an offer is
/// made once and not at every listing.
enum MarkOffers {
    static let storageKey = "tailscode.marks.offered"
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    static func made() -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func record(_ profiles: Set<String>) {
        defaults.set(made().union(profiles).sorted(), forKey: storageKey)
    }
}
