/// What has to happen to a list of rows on screen for it to become another list of rows.
///
/// A transcript is not repainted, it is edited, and the edit is where the glitches live. Both
/// desktops grew the same hand-rolled applier: walk the old rows against the new ones, and at the
/// first pair that is not *equal* throw away everything from there down and rebuild it. That works
/// while a transcript only ever grows at the end, and a transcript does not only grow at the end —
/// a tool result lands on a call fifty rows back, a second TodoWrite demotes the row the previous
/// one had promoted, a picture finishes decoding. Each of those changes one row's value in the
/// middle and costs the entire tail below it: torn down, re-appended a batch per runloop hop, with
/// every intermediate state laid out and drawn. The transcript visibly collapses and regrows, and
/// nothing about it was an insertion.
///
/// The mistake is diffing by value. A row's *identity* says whether it is the same row; its value
/// says only whether it needs repainting. So the plan is computed from the keys alone: rows whose
/// key survives keep their widget wherever they moved to, and the caller repaints the ones whose
/// value changed. A value change can then never produce an insertion or a removal — which is the
/// property worth having, because it is exactly the case that used to rebuild the world.
///
/// Keys are matched in order and each old row is claimed at most once, so a duplicate key — which
/// is a bug, but one a transcript must survive rather than crash on — pairs first-with-first and
/// leaves the extra as an ordinary insertion.
public enum RowDiff {
    /// A row that survives the edit, at its index on each side.
    public struct Match: Equatable, Sendable {
        public let old: Int
        public let new: Int

        public init(old: Int, new: Int) {
            self.old = old
            self.new = new
        }
    }

    /// Remove `removals` from the old list, then insert `insertions` into it, and it is the new
    /// list. Both are ascending; `survivors` is in new order.
    public struct Plan: Equatable, Sendable {
        public let removals: [Int]
        public let insertions: [Int]
        public let survivors: [Match]

        public init(removals: [Int], insertions: [Int], survivors: [Match]) {
            self.removals = removals
            self.insertions = insertions
            self.survivors = survivors
        }

        /// Nothing moved, nothing arrived, nothing left — every row kept both its key and its
        /// place. The common case during a stream, and the one an applier may answer by repainting
        /// the rows whose values differ and touching nothing else.
        public var isOrderPreserving: Bool { removals.isEmpty && insertions.isEmpty }
    }

    public static func plan(from old: [String], to new: [String]) -> Plan {
        guard !old.isEmpty else {
            return Plan(removals: [], insertions: Array(new.indices), survivors: [])
        }
        guard !new.isEmpty else {
            return Plan(removals: Array(old.indices), insertions: [], survivors: [])
        }
        if old == new {
            return Plan(
                removals: [], insertions: [],
                survivors: new.indices.map { Match(old: $0, new: $0) })
        }

        var available: [String: [Int]] = [:]
        for (index, key) in old.enumerated().reversed() {
            available[key, default: []].append(index)
        }
        var paired: [Match] = []
        paired.reserveCapacity(min(old.count, new.count))
        for (index, key) in new.enumerated() {
            guard var queue = available[key], let claimed = queue.popLast() else { continue }
            available[key] = queue
            paired.append(Match(old: claimed, new: index))
        }

        let kept = Set(longestRun(paired))
        var survivors: [Match] = []
        survivors.reserveCapacity(kept.count)
        var keptOld = Set<Int>()
        var keptNew = Set<Int>()
        for (offset, match) in paired.enumerated() where kept.contains(offset) {
            survivors.append(match)
            keptOld.insert(match.old)
            keptNew.insert(match.new)
        }
        return Plan(
            removals: old.indices.filter { !keptOld.contains($0) },
            insertions: new.indices.filter { !keptNew.contains($0) },
            survivors: survivors)
    }

    /// The offsets into `paired` of the longest run whose old indices increase.
    ///
    /// Rows paired by key are already in new order; the ones whose old order agrees are the ones
    /// that can keep their widget without being moved, and the rest are cheaper to treat as having
    /// left and arrived. Picking the *longest* such run is what keeps a reordering from being
    /// answered by rebuilding the whole list — patience sorting, so a long transcript costs
    /// n log n rather than n².
    private static func longestRun(_ paired: [Match]) -> [Int] {
        guard !paired.isEmpty else { return [] }
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: paired.count)
        for (offset, match) in paired.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if paired[tails[middle]].old < match.old { low = middle + 1 } else { high = middle }
            }
            previous[offset] = low > 0 ? tails[low - 1] : -1
            if low == tails.count { tails.append(offset) } else { tails[low] = offset }
        }
        var run: [Int] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.append(cursor)
            cursor = previous[cursor]
        }
        return run.reversed()
    }
}
