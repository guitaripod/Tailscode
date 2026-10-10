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
        reconcilePins(reporting)
        reconcileArchive(reporting)
        reconcileReads(entries)
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
