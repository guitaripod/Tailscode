import AppKit
import CodingAgentKit
import QuartzCore
import TailscodeCore

/// The Mac's side of Core's `HostClock`: a monotonic clock and one display link that runs the
/// window's `TileDrain` once a frame, paused whenever nothing is dirty.
///
/// A stream used to hand every state to the main thread as it arrived and build it there and
/// then; now a state lands in its pane's latest-wins mailbox and the frame applies whatever is
/// newest, focused pane first, inside a 4 ms budget. A display link is not served to a window that
/// is occluded, on a sleeping screen or never shown, so a guard 100 ms after any request drains
/// anyway: a stream's last state can never wait on a frame that is not coming.
final class MacHostClock: NSObject, HostClock, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    weak var drain: TileDrain?
    /// Work that rides the same pass ahead of the panes: the edge services' newest states.
    @MainActor var beforePass: (() -> Void)?
    @MainActor private var link: CADisplayLink?
    @MainActor private var guardArmed = false
    @MainActor private var wakeArmed: TimeInterval?
    @MainActor private var lastRun: TimeInterval = 0
    /// A pass that overran the budget rests for twice as long as it ran before the next one, so
    /// applying states never takes more than a third of the main thread however heavy one apply
    /// is: the layout and paint it causes, input and every other clock keep the rest.
    @MainActor private var restUntil: TimeInterval = 0
    static let restFactor: TimeInterval = 2
    @MainActor private(set) var linkTicks = 0
    @MainActor private(set) var guardRuns = 0
    @MainActor private(set) var drainPasses = 0
    @MainActor private(set) var worstPass: TimeInterval = 0

    static let starvationGuard: TimeInterval = 0.1

    /// The view whose screen paces the link. Changing it retires the link it had.
    @MainActor weak var host: NSView? {
        didSet {
            guard host !== oldValue else { return }
            link?.invalidate()
            link = nil
        }
    }

    @MainActor override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(budgetChanged), name: MotionBudget.didChange, object: nil)
    }

    func now() -> TimeInterval { CACurrentMediaTime() }

    func requestDrain() {
        lock.lock()
        let first = !pending
        pending = true
        lock.unlock()
        guard first else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { arm() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.arm() } }
        }
    }

    private var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    /// Whether the link exists and is running, for a selftest that proves a settled window owns
    /// no clock.
    @MainActor var isTicking: Bool { link.map { !$0.isPaused } ?? false }

    /// Runs one pass now, whatever the frame is doing; the selftest's way of saying "one frame".
    @MainActor func drainNow() {
        runDrain()
    }

    /// The set host, or else the window on screen: a harness that never names one still gets
    /// frames.
    @MainActor private var pacing: NSView? {
        host ?? NSApp?.windows.first { $0.isVisible && $0.contentView != nil }?.contentView
    }

    @MainActor private func arm() {
        if link == nil, let host = pacing, host.window != nil {
            let made = host.displayLink(target: self, selector: #selector(tick))
            made.preferredFrameRateRange = Self.range
            made.add(to: .main, forMode: .common)
            link = made
        }
        if let link {
            link.isPaused = false
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.runIfPending() } }
        }
        armGuard()
    }

    @MainActor private func armGuard() {
        guard !guardArmed else { return }
        guardArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.starvationGuard) {
            MainActor.assumeIsolated { self.guardFired() }
        }
    }

    @MainActor private func guardFired() {
        guardArmed = false
        guard isPending else { return }
        if now() >= restUntil, now() - lastRun >= Self.starvationGuard {
            guardRuns += 1
            runDrain()
        }
        if isPending { armGuard() }
    }

    @MainActor private func runIfPending() {
        guard isPending else { return }
        let wait = restUntil - now()
        guard wait <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                MainActor.assumeIsolated { self.runIfPending() }
            }
            return
        }
        runDrain()
    }

    @objc private func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            linkTicks += 1
            guard now() >= restUntil else { return }
            runDrain()
        }
    }

    @MainActor private func runDrain() {
        lock.lock()
        pending = false
        lock.unlock()
        let start = now()
        lastRun = start
        beforePass?()
        let outcome = drain?.run()
        drainPasses += 1
        let took = now() - start
        worstPass = max(worstPass, took)
        restUntil = took > (drain?.budget ?? 0) ? now() + took * Self.restFactor : 0
        if !isPending { link?.isPaused = true }
        if let wakeAt = outcome?.wakeAt, wakeArmed.map({ wakeAt < $0 }) ?? true {
            wakeArmed = wakeAt
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wakeAt - now())) {
                MainActor.assumeIsolated {
                    self.wakeArmed = nil
                    self.requestDrain()
                }
            }
        }
    }

    /// The governor's tick cap, read the same way the cascade reads it.
    @MainActor private static var range: CAFrameRateRange { MotionBudget.cascadeRange }

    @objc private func budgetChanged() {
        MainActor.assumeIsolated { link?.preferredFrameRateRange = Self.range }
    }
}

/// The edge services' doorway out of the hub. The hub calls it on its stream task for every state;
/// one latest-wins box per conversation, read at the start of the frame's drain pass, means the
/// main thread is woken no more often than the frame and never sees more than the newest state —
/// waking it once per state, with nothing to draw, cost a run-loop pass and a commit every time.
final class MacLiveEdges: LiveEdges, @unchecked Sendable {
    private let lock = NSLock()
    private var boxes: [LiveKey: LatestWins<ConversationState>] = [:]
    private var dirty: [LiveKey] = []
    private let clock: HostClock

    init(clock: HostClock) {
        self.clock = clock
    }

    func observe(_ key: LiveKey, _ state: ConversationState) {
        lock.lock()
        let box = boxes[key] ?? LatestWins<ConversationState>()
        boxes[key] = box
        let fresh = box.post(state)
        if fresh { dirty.append(key) }
        lock.unlock()
        if fresh { clock.requestDrain() }
    }

    /// Every conversation's newest state since the last pass, once each.
    func take() -> [(LiveKey, ConversationState)] {
        lock.lock()
        let keys = dirty
        dirty = []
        let held = keys.compactMap { key in boxes[key].map { (key, $0) } }
        lock.unlock()
        return held.compactMap { key, box in box.take().map { (key, $0) } }
    }

    func forget(_ key: LiveKey) {
        lock.lock()
        boxes[key] = nil
        lock.unlock()
    }
}

/// The process's live conversations and the work that belongs to a conversation rather than to a
/// pane: one `AgentConversation` per chat however many panes, watches and warm-ups hold it, one
/// notification per state, one drain of the send queue, one presence reading for the list.
///
/// Every pane, the window's background watch and the hover warmer used to build an instance of
/// their own, so a chat in two panes ran two reducers and two persist chains, notified twice and
/// could send its queue's head twice. Here the hub owns the stream; `instances` is only how a pane
/// gets the same conversation synchronously for sending, and it forgets a chat once the hub has.
@MainActor
final class TileRuntime {
    static let shared = TileRuntime()

    let clock = MacHostClock()
    let drain: TileDrain
    let edges: MacLiveEdges
    let hub: ConversationHub

    private var instances: [LiveKey: AgentConversation] = [:]
    private var backends: [LiveKey: any CodingAgentBackend] = [:]
    private var entries: [LiveKey: SessionEntry] = [:]
    /// The panes holding each chat in the order they took it; the first drains its queue.
    private var holders: [LiveKey: [ObjectIdentifier]] = [:]
    private var watches: [LiveKey: LiveLease] = [:]
    private var watchReadings: [LiveKey: SessionPresence] = [:]
    private var handoffs: [LiveKey: TurnHandoff] = [:]
    private var draining: Set<LiveKey> = []
    private var redialDelay: [LiveKey: TimeInterval] = [:]
    private var redialArmed: Set<LiveKey> = []

    /// What each watched conversation's last state said, for the chat list's LIVE NOW, keyed the
    /// way the stores are keyed.
    private(set) var backgroundPresence: [String: SessionPresence] = [:]
    /// Told when a watched conversation's reading changes or its watch ends.
    var onPresenceChanged: (() -> Void)?
    /// States the edge services handled, per conversation: at most one per state the hub received,
    /// whatever the pane count.
    private(set) var edgeStates: [LiveKey: Int] = [:]

    private init() {
        drain = TileDrain(clock: clock)
        edges = MacLiveEdges(clock: clock)
        hub = ConversationHub(
            open: { key in await TileRuntime.shared.instance(for: key) },
            clock: clock, edges: edges)
        clock.drain = drain
        clock.beforePass = { [weak self] in self?.serviceEdges() }
    }

    private func serviceEdges() {
        for (key, state) in edges.take() { process(key, state) }
    }

    static func key(_ entry: SessionEntry) -> LiveKey {
        LiveKey(profileID: entry.profileID, sessionID: entry.session.id)
    }

    static func storeKey(_ key: LiveKey) -> String {
        SessionPinStore.key(key.profileID, key.sessionID)
    }

    private func instance(for key: LiveKey) -> AgentConversation? {
        if let held = instances[key] { return held }
        guard let backend = backends[key] else { return nil }
        let made = AgentConversation(
            backend: backend, sessionID: key.sessionID, cache: AppCache.sessionCache)
        instances[key] = made
        return made
    }

    /// The one conversation for a chat, made now if nobody holds it. Chats the hub has let go of
    /// are forgotten first, so a chat opened again later dials fresh the way an open always did.
    func conversation(for entry: SessionEntry, backend: any CodingAgentBackend) -> AgentConversation {
        sweep()
        let key = Self.key(entry)
        backends[key] = backend
        entries[key] = entry
        if let held = instances[key] { return held }
        let made = AgentConversation(
            backend: backend, sessionID: entry.session.id, cache: AppCache.sessionCache)
        instances[key] = made
        return made
    }

    private func sweep() {
        let live = Set(hub.keys)
        for key in instances.keys where !live.contains(key) && holders[key] == nil {
            instances[key] = nil
            backends[key] = nil
            entries[key] = nil
            edgeStates[key] = nil
            redialDelay[key] = nil
            edges.forget(key)
        }
    }

    /// An interest in a chat, with the conversation to send through.
    func lease(
        _ entry: SessionEntry, backend: any CodingAgentBackend, interest: LiveInterest,
        dirty: @escaping @Sendable () -> Void
    ) -> (LiveLease, AgentConversation) {
        let conversation = conversation(for: entry, backend: backend)
        return (hub.lease(Self.key(entry), interest: interest, dirty: dirty), conversation)
    }

    /// A pane taking a chat: a full lease whose every new state wakes the frame's drain.
    func attach(
        _ pane: AnyObject, entry: SessionEntry, backend: any CodingAgentBackend
    ) -> (LiveLease, AgentConversation) {
        let drain = self.drain
        let taken = lease(entry, backend: backend, interest: .full) { drain.wake() }
        let key = Self.key(entry)
        let id = ObjectIdentifier(pane)
        if !(holders[key]?.contains(id) ?? false) { holders[key, default: []].append(id) }
        return taken
    }

    func detach(_ pane: ObjectIdentifier, from key: LiveKey) {
        holders[key]?.removeAll { $0 == pane }
        if holders[key]?.isEmpty == true { holders[key] = nil }
    }

    /// Whether this pane is the one that drains its chat's queue: the first that took it. A chat in
    /// two panes drains once.
    func ownsQueue(_ pane: AnyObject, of key: LiveKey) -> Bool {
        holders[key]?.first == ObjectIdentifier(pane)
    }

    func paneCount(_ key: LiveKey) -> Int { holders[key]?.count ?? 0 }

    /// Keeps a chat's stream for its edge services after the pane showing it moved on, so a turn
    /// still in flight keeps its LIVE NOW seat, notifies when it ends and drains its queue.
    func watch(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        let key = Self.key(entry)
        guard watches[key] == nil else { return }
        let (taken, _) = lease(entry, backend: backend, interest: .watching) {}
        watches[key] = taken
        watchReadings[key] = .running(nil)
        handoffs[key] = TurnHandoff()
    }

    func isWatching(_ key: LiveKey) -> Bool { watches[key] != nil }

    func stopWatching(_ key: LiveKey) {
        watches.removeValue(forKey: key)?.cancel()
        watchReadings[key] = nil
        handoffs[key] = nil
        backgroundPresence[Self.storeKey(key)] = nil
    }

    /// One state, once per conversation however many panes show it.
    func process(_ key: LiveKey, _ state: ConversationState) {
        edgeStates[key, default: 0] += 1
        if let entry = entries[key] {
            MacNotifier.shared.observeConversation(
                profileID: key.profileID, sessionID: key.sessionID,
                title: MissedActivity.name(
                    title: entry.session.title,
                    latestPrompt: state.messages.last { $0.role == .user }?
                        .parts.compactMap(\.text).joined(separator: "\n")),
                state: state)
        }
        noteConnection(key, state)
        guard watches[key] != nil, paneCount(key) == 0 else { return }
        watchStep(key, state)
    }

    /// A stream the Kit gave up on ends, and the hub does not redial on its own; while anything
    /// still holds the chat it is asked again, backing off from 2 s to 30 s as a pane's own loop
    /// used to.
    private func noteConnection(_ key: LiveKey, _ state: ConversationState) {
        if state.connection == .live {
            redialDelay[key] = nil
            return
        }
        guard state.connection == .offline, !redialArmed.contains(key) else { return }
        let delay = redialDelay[key] ?? 2
        redialDelay[key] = min(30, delay * 2)
        redialArmed.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                let runtime = TileRuntime.shared
                runtime.redialArmed.remove(key)
                guard runtime.hub.leaseCount(key) > 0, !runtime.hub.isStreaming(key) else { return }
                runtime.hub.reevaluate(key)
            }
        }
    }

    private func watchStep(_ key: LiveKey, _ state: ConversationState) {
        var handoff = handoffs[key] ?? TurnHandoff()
        handoff.observe(state, sendsInFlight: draining.contains(key))
        handoffs[key] = handoff
        if drainHeld(key, state: state) { return }
        let reading = SessionPresence.reading(state, step: nil)
        let changed = reading != watchReadings[key]
        watchReadings[key] = reading
        backgroundPresence[Self.storeKey(key)] = reading
        if reading == .unobserved {
            stopWatching(key)
            onPresenceChanged?()
            return
        }
        if changed { onPresenceChanged?() }
    }

    /// A conversation no pane shows still owes its queue: the next waiting message goes the moment
    /// the turn yields, taken atomically from the store so nothing else can send the same head.
    /// The disk read and the send run off the main thread; the handoff opens at once so the next
    /// state cannot start a second drain.
    private func drainHeld(_ key: LiveKey, state: ConversationState) -> Bool {
        guard !draining.contains(key), let handoff = handoffs[key],
            SendQueueDrain.mayDrain(state, handoff: handoff),
            !SendQueueStore.queue(profileID: key.profileID, sessionID: key.sessionID).isEmpty,
            let conversation = instances[key]
        else { return false }
        draining.insert(key)
        handoffs[key]?.begin(after: state)
        Task.detached {
            guard let next = SendQueueStore.takeFirst(
                profileID: key.profileID, sessionID: key.sessionID)
            else {
                await TileRuntime.shared.drainEnded(key, sent: false)
                return
            }
            do {
                try await conversation.send(
                    next.text, model: next.model, reasoningEffort: next.effort,
                    attachments: next.attachments)
                await TileRuntime.shared.drainEnded(key, sent: true)
            } catch {
                var held = SendQueueStore.queue(profileID: key.profileID, sessionID: key.sessionID)
                held.requeueAtHead(next)
                SendQueueStore.save(held, profileID: key.profileID, sessionID: key.sessionID)
                await TileRuntime.shared.drainEnded(key, sent: false)
            }
        }
        return true
    }

    private func drainEnded(_ key: LiveKey, sent: Bool) {
        draining.remove(key)
        if !sent { handoffs[key]?.end() }
    }
}
