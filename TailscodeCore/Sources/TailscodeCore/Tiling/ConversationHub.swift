import CodingAgentKit
import Foundation

/// One live conversation's address: the profile it lives under and the session.
public struct LiveKey: Hashable, Sendable {
    public let profileID: String
    public let sessionID: String

    public init(profileID: String, sessionID: String) {
        self.profileID = profileID
        self.sessionID = sessionID
    }
}

/// What a consumer wants from a conversation. It decides what the hub does, not what the consumer
/// sees: every lease is handed the newest state. `full` and `glance` keep the stream open;
/// `watching` keeps it only while the edge services need it.
public enum LiveInterest: Int, Comparable, Sendable {
    case watching = 0
    case glance = 1
    case full = 2

    public static func < (lhs: LiveInterest, rhs: LiveInterest) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The work that belongs to a conversation rather than to a pane showing it: notifications, the
/// send-queue drain, the presence ledger, the turn handoff. The hub calls it once per state per
/// conversation, however many panes show the chat, which is what ends duplicate notifications and
/// a queue head sent twice.
public protocol LiveEdges: Sendable {
    /// Called on the hub's stream task, in order, for every state the hub receives for `key`.
    func observe(_ key: LiveKey, _ state: ConversationState)

    /// Whether a conversation held only by `watching` leases still needs its stream: a held send
    /// queue, a turn the person asked to be told about. Called outside the hub's lock.
    func needsStream(_ key: LiveKey) -> Bool
}

extension LiveEdges {
    public func needsStream(_ key: LiveKey) -> Bool { true }
}

/// One state as a lease sees it, numbered per conversation so a consumer can tell it skipped some.
public struct LiveFrame: Sendable, Equatable {
    public let state: ConversationState
    public let sequence: UInt64

    public init(state: ConversationState, sequence: UInt64) {
        self.state = state
        self.sequence = sequence
    }
}

/// One live conversation per `(profile, session)`, process-wide, fanned out to every consumer
/// through a latest-wins mailbox each.
///
/// Every pane used to build its own `AgentConversation`, so two panes on one chat, or a pane and a
/// background watch, ran two reducers, two refresh chains and two persist chains and could each
/// send the queue's head. The hub owns the one conversation and its one `states()` subscription,
/// posts every state into each lease's mailbox (firing the lease's `dirty` once per clean-to-dirty
/// transition) and runs the edge services once. When nothing needs the stream any more it waits a
/// grace period, so a rebalance of densities does not redial, and then cancels the subscription,
/// which stops the Kit's run loop.
public final class ConversationHub: @unchecked Sendable {
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    /// How long a stream outlives its last lease.
    public static let defaultGrace: TimeInterval = 5

    /// Runs `work` after `delay` seconds on a background task; never on a main queue.
    public static let sleepScheduler: Scheduler = { delay, work in
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(max(0, delay)))
            work()
        }
    }

    private struct LeaseRecord {
        let mailbox: LatestWins<LiveFrame>
        let dirty: @Sendable () -> Void
        var interest: LiveInterest
    }

    private final class Entry {
        var opening: Task<AgentConversation?, Never>?
        var subscription: Task<Void, Never>?
        var subscriptionID: UInt64 = 0
        var leases: [UInt64: LeaseRecord] = [:]
        var latest: LiveFrame?
        var sequence: UInt64 = 0
        var releaseDue: TimeInterval?
        var graceID: UInt64 = 0
        var redials = 0
    }

    private let open: @Sendable (LiveKey) async -> AgentConversation?
    private let clock: HostClock
    private let edges: LiveEdges
    private let grace: TimeInterval
    private let schedule: Scheduler
    private let lock = NSLock()
    private var entries: [LiveKey: Entry] = [:]
    private var nextID: UInt64 = 0

    public init(
        open: @escaping @Sendable (LiveKey) async -> AgentConversation?,
        clock: HostClock,
        edges: LiveEdges,
        grace: TimeInterval = ConversationHub.defaultGrace,
        schedule: @escaping Scheduler = ConversationHub.sleepScheduler
    ) {
        self.open = open
        self.clock = clock
        self.edges = edges
        self.grace = grace
        self.schedule = schedule
    }

    /// Takes an interest in a conversation. The lease is handed the newest state the hub already
    /// holds at once, and every later one through its mailbox; `dirty` must be O(1) and callable on
    /// any thread.
    public func lease(
        _ key: LiveKey, interest: LiveInterest, dirty: @escaping @Sendable () -> Void
    ) -> LiveLease {
        let mailbox = LatestWins<LiveFrame>()
        lock.lock()
        nextID += 1
        let id = nextID
        let entry = entries[key] ?? Entry()
        entries[key] = entry
        if entry.opening == nil {
            let open = self.open
            entry.opening = Task { await open(key) }
        }
        entry.leases[id] = LeaseRecord(mailbox: mailbox, dirty: dirty, interest: interest)
        let held = entry.latest
        lock.unlock()
        if let held, mailbox.post(held) { dirty() }
        reconcile(key)
        return LiveLease(hub: self, key: key, id: id, mailbox: mailbox)
    }

    /// The shared conversation for a key something already holds a lease on, for sending through
    /// it. Nil when nothing does, or when the open failed.
    public func conversation(for key: LiveKey) async -> AgentConversation? {
        await opening(key)?.value
    }

    private func opening(_ key: LiveKey) -> Task<AgentConversation?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.opening
    }

    /// The newest state the hub holds for a key.
    public func latest(_ key: LiveKey) -> LiveFrame? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.latest
    }

    /// Whether the hub holds a subscription for a key, counting one inside its grace period.
    public func isStreaming(_ key: LiveKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.subscription != nil
    }

    /// Every key the hub holds anything for.
    public var keys: [LiveKey] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.keys)
    }

    public func leaseCount(_ key: LiveKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.leases.count ?? 0
    }

    /// Asks the hub to decide again whether a key needs its stream, after something the edge
    /// services read changed (a message queued, a notification asked for).
    public func reevaluate(_ key: LiveKey) {
        reconcile(key)
    }

    func setInterest(_ key: LiveKey, id: UInt64, interest: LiveInterest) {
        lock.lock()
        guard let entry = entries[key], entry.leases[id] != nil else {
            lock.unlock()
            return
        }
        entry.leases[id]?.interest = interest
        lock.unlock()
        reconcile(key)
    }

    func release(_ key: LiveKey, id: UInt64) {
        lock.lock()
        guard let entry = entries[key], entry.leases.removeValue(forKey: id) != nil else {
            lock.unlock()
            return
        }
        lock.unlock()
        reconcile(key)
    }

    /// The one place the stream is started, kept, put on grace or ended. The edge services are
    /// asked outside the lock, so an implementation may call back into the hub.
    private func reconcile(_ key: LiveKey) {
        lock.lock()
        guard let entry = entries[key] else {
            lock.unlock()
            return
        }
        let interests = entry.leases.values.map(\.interest)
        lock.unlock()
        let wants: Bool
        if interests.contains(where: { $0 >= .glance }) {
            wants = true
        } else if !interests.isEmpty {
            wants = edges.needsStream(key)
        } else {
            wants = false
        }
        lock.lock()
        defer { lock.unlock() }
        guard let current = entries[key], current === entry else { return }
        if wants {
            current.releaseDue = nil
            current.graceID &+= 1
            if current.subscription == nil { subscribe(key, entry: current) }
            return
        }
        guard current.subscription != nil else {
            if current.leases.isEmpty { drop(key, entry: current) }
            return
        }
        guard current.releaseDue == nil else { return }
        armGrace(key, entry: current, delay: grace)
    }

    private func armGrace(_ key: LiveKey, entry: Entry, delay: TimeInterval) {
        entry.graceID &+= 1
        let graceID = entry.graceID
        entry.releaseDue = clock.now() + delay
        schedule(delay) { [weak self] in self?.graceElapsed(key, graceID: graceID) }
    }

    /// The grace timer firing. A timer that fires early is re-armed for what is left, so the
    /// injected clock, not the scheduler, decides when the stream ends.
    private func graceElapsed(_ key: LiveKey, graceID: UInt64) {
        lock.lock()
        guard let entry = entries[key], entry.graceID == graceID, let due = entry.releaseDue else {
            lock.unlock()
            return
        }
        let remaining = due - clock.now()
        if remaining > 0 {
            armGrace(key, entry: entry, delay: remaining)
            entry.releaseDue = due
            lock.unlock()
            return
        }
        entry.releaseDue = nil
        entry.subscriptionID &+= 1
        let subscription = entry.subscription
        entry.subscription = nil
        if entry.leases.isEmpty { drop(key, entry: entry) }
        lock.unlock()
        subscription?.cancel()
    }

    private func drop(_ key: LiveKey, entry: Entry) {
        entry.subscription?.cancel()
        entry.subscription = nil
        entry.opening?.cancel()
        entries[key] = nil
    }

    private func subscribe(_ key: LiveKey, entry: Entry) {
        if entry.opening == nil {
            let open = self.open
            entry.opening = Task { await open(key) }
        }
        guard let opening = entry.opening else { return }
        entry.subscriptionID &+= 1
        let id = entry.subscriptionID
        entry.subscription = Task { [weak self] in
            guard let conversation = await opening.value, !Task.isCancelled else {
                self?.subscriptionEnded(key, id: id, opened: false)
                return
            }
            let stream = await conversation.states()
            for await state in stream {
                if Task.isCancelled { break }
                self?.receive(key, state, subscriptionID: id)
            }
            self?.subscriptionEnded(key, id: id, opened: true)
        }
    }

    /// A subscription that ended on its own — an open that failed, a stream that finished — leaves
    /// the entry ready for the next lease or reevaluation to try again, rather than looking live.
    /// A stream that opened and then ended while leases still hold the key is dialled again after a
    /// backoff (2, 4, 8 … 30 s, reset by a live state), because the Kit finishes its subscribers on
    /// a failure it calls terminal and a pane that is still showing the chat must not go quiet for
    /// good; an open that failed waits for the next lease, as a server nobody has configured does.
    private func subscriptionEnded(_ key: LiveKey, id: UInt64, opened: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.subscriptionID == id else { return }
        entry.subscription = nil
        if !opened { entry.opening = nil }
        if entry.leases.isEmpty {
            drop(key, entry: entry)
            return
        }
        guard opened else { return }
        entry.redials += 1
        let delay = min(Self.maxRedialDelay, pow(2, Double(min(entry.redials, 5))))
        schedule(delay) { [weak self] in self?.reconcile(key) }
    }

    /// The longest wait before a finished stream is dialled again.
    public static let maxRedialDelay: TimeInterval = 30

    private func receive(_ key: LiveKey, _ state: ConversationState, subscriptionID: UInt64) {
        lock.lock()
        guard let entry = entries[key], entry.subscriptionID == subscriptionID else {
            lock.unlock()
            return
        }
        entry.sequence &+= 1
        if state.connection == .live { entry.redials = 0 }
        let frame = LiveFrame(state: state, sequence: entry.sequence)
        entry.latest = frame
        let records = Array(entry.leases.values)
        let watchingOnly = !records.isEmpty && records.allSatisfy { $0.interest == .watching }
        lock.unlock()
        for record in records where record.mailbox.post(frame) {
            record.dirty()
        }
        edges.observe(key, state)
        if watchingOnly { reconcile(key) }
    }
}

/// A consumer's hold on one live conversation. Cancelled by hand, by its `PaneLifetime`, or when
/// it is released; cancelling twice is harmless.
public final class LiveLease: @unchecked Sendable {
    public let key: LiveKey
    private let hub: ConversationHub
    private let id: UInt64
    private let mailbox: LatestWins<LiveFrame>
    private let lock = NSLock()
    private var cancelled = false

    init(hub: ConversationHub, key: LiveKey, id: UInt64, mailbox: LatestWins<LiveFrame>) {
        self.hub = hub
        self.key = key
        self.id = id
        self.mailbox = mailbox
    }

    deinit {
        hub.release(key, id: id)
    }

    /// The newest frame since the last take, or nil when nothing new arrived. O(1).
    public func take() -> LiveFrame? {
        mailbox.take()
    }

    /// Whether a frame is waiting, for a drain slot's `hasWork`.
    public var hasFrame: Bool { mailbox.isDirty }

    public func set(interest: LiveInterest) {
        guard !isCancelled else { return }
        hub.setInterest(key, id: id, interest: interest)
    }

    /// The shared conversation, for sending through it.
    public func conversation() async -> AgentConversation? {
        await hub.conversation(for: key)
    }

    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first { hub.release(key, id: id) }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
