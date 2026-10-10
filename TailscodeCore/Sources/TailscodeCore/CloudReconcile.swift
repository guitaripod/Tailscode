import Foundation

/// One read mark as a device holds it: when the person had last looked, and when they decided so.
public struct CloudSeen: Codable, Sendable, Equatable {
    public var value: Double
    public var decidedAt: Double?

    public init(value: Double, decidedAt: Double? = nil) {
        self.value = value
        self.decidedAt = decidedAt
    }
}

/// Everything a device holds that follows a person, already spelled in ledger keys. Conversations
/// whose server this device has no profile for are simply absent here; they are not removed, only
/// not held.
public struct CloudLocal: Codable, Sendable, Equatable {
    public var seen: [String: CloudSeen]
    public var saved: [String: CloudChat]
    public var pinned: [String]
    public var archived: Set<String>

    public init(
        seen: [String: CloudSeen] = [:], saved: [String: CloudChat] = [:],
        pinned: [String] = [], archived: Set<String> = []
    ) {
        self.seen = seen
        self.saved = saved
        self.pinned = pinned
        self.archived = archived
    }
}

/// What the ledger says this device should now hold that it does not. Everything in it is a fact
/// the ledger already settled; applying it makes the device agree and decides nothing.
public struct CloudPatch: Sendable, Equatable {
    public var seen: [String: CloudSeen] = [:]
    public var saveAdds: [String: CloudChat] = [:]
    public var saveRemoves: Set<String> = []
    public var pinOrder: [String] = []
    public var pinAdds: Set<String> = []
    public var pinRemoves: Set<String> = []
    public var archiveAdds: Set<String> = []
    public var archiveRemoves: Set<String> = []

    public var isEmpty: Bool {
        seen.isEmpty && saveAdds.isEmpty && saveRemoves.isEmpty && pinAdds.isEmpty
            && pinRemoves.isEmpty && archiveAdds.isEmpty && archiveRemoves.isEmpty
    }
}

/// The decision of what to keep, as arithmetic over values. Three things go in — what the device
/// holds now, what it held when it last agreed with the ledger (`base`), and the ledger itself
/// beside whatever the cloud sent — and two come out: the ledger every device should now hold, and
/// the patch that brings this one into line with it.
///
/// What this device did is read from the difference between `local` and `base`, never from the
/// store's own history: a thing present now and absent then was added, a thing present then and
/// absent now was removed, and a thing this device never held says nothing about whether a person
/// wants it. That is what keeps a server added next week from being read as a year of deletions.
public enum CloudReconciler {
    public struct Result: Sendable, Equatable {
        public var ledger: CloudLedger
        public var patch: CloudPatch
    }

    /// - Parameter legacy: whether this device has never agreed with a ledger before. What it
    ///   already holds is then older than anything the cloud may say about the same thing, so it is
    ///   stamped as of the beginning of time and any real decision elsewhere outranks it.
    public static func reconcile(
        local: CloudLocal, base: CloudLocal, ledger: CloudLedger, remote: CloudLedger, now: Double,
        legacy: Bool = false
    ) -> Result {
        var mine = ledger
        recordSeen(local: local.seen, base: base.seen, into: &mine.seen, now: now)
        recordSaved(local: local.saved, base: base.saved, into: &mine.saved, now: now)
        recordPins(local: local.pinned, base: Set(base.pinned), into: &mine.pinned, now: now, legacy: legacy)
        recordMembers(
            local: local.archived, base: base.archived, into: &mine.archived, now: now,
            legacy: legacy)
        let settled = CloudLedger.merged(mine, remote).pruned(now: now)
        return Result(ledger: settled, patch: patch(for: settled, local: local))
    }

    private static let seenEpsilon = 0.5
    private static let refreshInterval = 600.0

    private static func recordSeen(
        local: [String: CloudSeen], base: [String: CloudSeen], into marks: inout [String: CloudMark],
        now: Double
    ) {
        for (id, seen) in local {
            let before = base[id]
            if let before, abs(before.value - seen.value) <= seenEpsilon { continue }
            let at = seen.decidedAt ?? (before == nil ? seen.value : now)
            marks[id] = CloudMark(at: at, on: true, value: seen.value)
        }
    }

    private static func recordSaved(
        local: [String: CloudChat], base: [String: CloudChat], into marks: inout [String: CloudMark],
        now: Double
    ) {
        for (key, chat) in local {
            if base[key] == nil {
                let reopened = marks[key] != nil
                marks[key] = CloudMark(at: reopened ? now : chat.savedAt, on: true, chat: chat)
            } else if var held = marks[key], held.on, let kept = held.chat, worthRefreshing(kept, chat) {
                held.chat = chat
                marks[key] = held
            }
        }
        for key in base.keys where local[key] == nil {
            marks[key] = CloudMark(at: now, on: false)
        }
    }

    private static func worthRefreshing(_ kept: CloudChat, _ fresh: CloudChat) -> Bool {
        kept.title != fresh.title || kept.directory != fresh.directory
            || kept.serverName != fresh.serverName
            || fresh.updatedAt - kept.updatedAt > refreshInterval
    }

    private static func recordPins(
        local: [String], base: Set<String>, into marks: inout [String: CloudMark], now: Double,
        legacy: Bool
    ) {
        for (index, key) in local.enumerated() where !base.contains(key) {
            marks[key] = CloudMark(at: legacy ? 1 + Double(index) : now, on: true)
        }
        for key in base.subtracting(local) {
            marks[key] = CloudMark(at: now, on: false)
        }
    }

    private static func recordMembers(
        local: Set<String>, base: Set<String>, into marks: inout [String: CloudMark], now: Double,
        legacy: Bool
    ) {
        for key in local.subtracting(base) {
            marks[key] = CloudMark(at: legacy ? 1 : now, on: true)
        }
        for key in base.subtracting(local) {
            marks[key] = CloudMark(at: now, on: false)
        }
    }

    private static func patch(for ledger: CloudLedger, local: CloudLocal) -> CloudPatch {
        var patch = CloudPatch()
        for (id, mark) in ledger.seen where mark.on {
            guard let value = mark.value else { continue }
            let held = local.seen[id]
            if held == nil || abs((held?.value ?? 0) - value) > seenEpsilon {
                patch.seen[id] = CloudSeen(value: value, decidedAt: mark.at)
            }
        }
        for (key, mark) in ledger.saved {
            if mark.on, let chat = mark.chat, local.saved[key] == nil {
                patch.saveAdds[key] = chat
            } else if !mark.on, local.saved[key] != nil {
                patch.saveRemoves.insert(key)
            }
        }
        let held = Set(local.pinned)
        for (key, mark) in ledger.pinned {
            if mark.on, !held.contains(key) { patch.pinAdds.insert(key) }
            if !mark.on, held.contains(key) { patch.pinRemoves.insert(key) }
        }
        patch.pinOrder = ledger.pinned.filter { $0.value.on }
            .sorted { ($0.value.at, $0.key) < ($1.value.at, $1.key) }.map(\.key)
        for (key, mark) in ledger.archived {
            if mark.on, !local.archived.contains(key) { patch.archiveAdds.insert(key) }
            if !mark.on, local.archived.contains(key) { patch.archiveRemoves.insert(key) }
        }
        return patch
    }
}

extension CloudLocal {
    /// This device after a patch has been applied to it: the value the next pass will call its
    /// `base`, and what a test holds in place of a phone.
    public func applying(_ patch: CloudPatch, resolvable: (String) -> Bool = { _ in true })
        -> CloudLocal
    {
        var out = self
        for (id, seen) in patch.seen { out.seen[id] = seen }
        for key in patch.saveRemoves { out.saved[key] = nil }
        for (key, chat) in patch.saveAdds where resolvable(key) { out.saved[key] = chat }
        let removed = patch.pinRemoves
        let wanted = patch.pinOrder.filter { resolvable($0) }
        let wantedSet = Set(wanted)
        let strays = out.pinned.filter { !wantedSet.contains($0) && !removed.contains($0) }
        out.pinned = wanted + strays
        out.archived.subtract(patch.archiveRemoves)
        out.archived.formUnion(patch.archiveAdds.filter(resolvable))
        return out
    }
}
