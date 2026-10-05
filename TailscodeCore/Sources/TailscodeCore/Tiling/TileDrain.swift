import Foundation

/// Who goes first when a frame cannot apply everything. The focused pane is what the person is
/// reading; a pane waiting on them or failed is news; then the other full panes; glance tiles last.
public enum DrainPriority: Int, Sendable, Comparable, CaseIterable {
    case focused = 0
    case attention = 1
    case full = 2
    case glance = 3

    public static func < (lhs: DrainPriority, rhs: DrainPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One consumer of the frame's time: a pane with a mailbox to read and a way to apply it.
public struct DrainSlot: Sendable {
    public let pane: PaneID
    public let priority: DrainPriority
    /// The shortest gap between two applies; a glance tile's rate is a minimum interval here.
    public let minInterval: TimeInterval
    /// Must be O(1) and callable on the drain's thread: usually `mailbox.isDirty`.
    public let hasWork: @Sendable () -> Bool
    public let apply: @Sendable () -> Void

    public init(
        pane: PaneID, priority: DrainPriority, minInterval: TimeInterval = 0,
        hasWork: @escaping @Sendable () -> Bool, apply: @escaping @Sendable () -> Void
    ) {
        self.pane = pane
        self.priority = priority
        self.minInterval = minInterval
        self.hasWork = hasWork
        self.apply = apply
    }
}

/// A registration, ended by `cancel()` or by the drain going away. Idempotent, so it can sit in a
/// `PaneLifetime` beside the paths that also end it by hand.
public final class DrainToken: @unchecked Sendable {
    public let id: UInt64
    private weak var drain: TileDrain?

    init(id: UInt64, drain: TileDrain) {
        self.id = id
        self.drain = drain
    }

    public func cancel() {
        drain?.unregister(id)
        drain = nil
    }
}

/// What one drain pass did, for the recorder and for a host that schedules its own wake.
public struct DrainOutcome: Sendable, Equatable {
    /// Slots applied this pass, in order.
    public var applied: [PaneID]
    /// Slots that were ready and did not run because the deadline came first.
    public var leftover: Int
    /// The earliest moment a slot held back only by its rate becomes ready, when nothing else is
    /// waiting. A host arms one timer for it instead of draining every frame until then.
    public var wakeAt: TimeInterval?

    public init(applied: [PaneID] = [], leftover: Int = 0, wakeAt: TimeInterval? = nil) {
        self.applied = applied
        self.leftover = leftover
        self.wakeAt = wakeAt
    }
}

/// One per window, run by the frame: applies the panes' latest states in priority order inside a
/// budget, and leaves the rest for the next frame.
///
/// Settled means silent: with no dirty slot a pass applies nothing and asks for nothing, so an idle
/// window owns no tick, no timer and no wake.
public final class TileDrain: @unchecked Sendable {
    public let budget: TimeInterval
    private let clock: HostClock
    private let lock = NSLock()
    private var slots: [UInt64: DrainSlot] = [:]
    private var order: [UInt64] = []
    private var lastApplied: [UInt64: TimeInterval] = [:]
    private var rotation: [DrainPriority: UInt64] = [:]
    private var nextID: UInt64 = 0

    public init(clock: HostClock, budget: TimeInterval = 0.004) {
        self.clock = clock
        self.budget = budget
    }

    public func register(_ slot: DrainSlot) -> DrainToken {
        lock.lock()
        nextID += 1
        let id = nextID
        slots[id] = slot
        order.append(id)
        lock.unlock()
        if slot.hasWork() { clock.requestDrain() }
        return DrainToken(id: id, drain: self)
    }

    /// Replaces a registration's slot in place, keeping its rate history, for a pane whose priority
    /// moved (focus, attention, density).
    public func update(_ token: DrainToken, to slot: DrainSlot) {
        lock.lock()
        guard slots[token.id] != nil else {
            lock.unlock()
            return
        }
        slots[token.id] = slot
        lock.unlock()
        if slot.hasWork() { clock.requestDrain() }
    }

    /// Tells the drain a slot became dirty. The same as the host calling `requestDrain` itself.
    public func wake() {
        clock.requestDrain()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.count
    }

    func unregister(_ id: UInt64) {
        lock.lock()
        slots[id] = nil
        lastApplied[id] = nil
        order.removeAll { $0 == id }
        lock.unlock()
    }

    /// A pass bounded by the drain's own budget from now.
    @discardableResult
    public func run() -> DrainOutcome {
        run(until: clock.now() + budget)
    }

    /// Applies ready slots in priority order until `deadline`, rotating the first slot within a
    /// class so peers of equal rank take turns. At least one ready slot always runs, whatever the
    /// deadline, so a frame that arrives late still makes progress. A ready slot left over asks for
    /// another drain; a slot held back only by its rate is reported as `wakeAt` instead.
    @discardableResult
    public func run(until deadline: TimeInterval) -> DrainOutcome {
        let now = clock.now()
        let plan = schedule()
        var outcome = DrainOutcome()
        var ranAny = false
        for (id, slot) in plan {
            guard slot.hasWork() else { continue }
            if let last = lastAppliedAt(id), slot.minInterval > 0, now - last < slot.minInterval {
                let due = last + slot.minInterval
                outcome.wakeAt = min(outcome.wakeAt ?? due, due)
                continue
            }
            if ranAny, clock.now() >= deadline {
                outcome.leftover += 1
                continue
            }
            markApplied(id, slot: slot, at: now)
            slot.apply()
            ranAny = true
            outcome.applied.append(slot.pane)
        }
        if outcome.leftover > 0 {
            outcome.wakeAt = nil
            clock.requestDrain()
        }
        return outcome
    }

    /// Slots ordered by priority, each class starting just after the slot that ran first in that
    /// class last time.
    private func schedule() -> [(UInt64, DrainSlot)] {
        lock.lock()
        defer { lock.unlock() }
        var plan: [(UInt64, DrainSlot)] = []
        for priority in DrainPriority.allCases {
            let members = order.filter { slots[$0]?.priority == priority }
            guard !members.isEmpty else { continue }
            var start = 0
            if let after = rotation[priority], let index = members.firstIndex(of: after) {
                start = (index + 1) % members.count
            }
            for offset in 0..<members.count {
                let id = members[(start + offset) % members.count]
                if let slot = slots[id] { plan.append((id, slot)) }
            }
        }
        return plan
    }

    private func lastAppliedAt(_ id: UInt64) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return lastApplied[id]
    }

    /// The class's rotation follows the last slot applied in it, so a pass cut short by the
    /// deadline starts the next one at the first peer it left waiting.
    private func markApplied(_ id: UInt64, slot: DrainSlot, at now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard slots[id] != nil else { return }
        lastApplied[id] = now
        rotation[slot.priority] = id
    }
}
