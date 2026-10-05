import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import Synchronization
import TailscodeCore

/// The host end of Core's tiling runtime on GTK: a monotonic clock and a drain request that lands
/// on the shim's drain seat, an idle below the frame clock's paint with a 100 ms starvation guard.
/// This is the only place the runtime reaches the main context.
final class GtkHostClock: HostClock, @unchecked Sendable {
    private var seat: OpaquePointer?
    private weak var drain: TileDrain?

    init() {
        let box = Unmanaged.passRetained(self).toOpaque()
        seat = tailscode_drain_new(
            { raw, one in
                guard let raw else { return }
                Unmanaged<GtkHostClock>.fromOpaque(raw).takeUnretainedValue().run(one: one != 0)
            }, box)
    }

    func attach(_ drain: TileDrain) {
        self.drain = drain
    }

    func now() -> TimeInterval {
        Double(g_get_monotonic_time()) / 1_000_000
    }

    func requestDrain() {
        tailscode_drain_request(seat)
    }

    /// One pass: the whole budget from the idle, exactly one ready slot from the guard.
    ///
    /// While the window's frame clock is running, a pass from the idle that would be painted by a
    /// frame between the tempo's grid frames waits one frame, so what it applies is painted by the
    /// frame every breathing mark and the reveal already paint rather than costing a frame of its
    /// own — under a renderer that repaints the window for any damage, each apply between grid
    /// frames was a whole extra paint. The wait is at most one frame; the guard never waits.
    private func run(one: Bool) {
        guard let drain else { return }
        let began = now()
        if !one, let delay = gridDelay(at: began) {
            Gtk.after(delay) { [weak self] in self?.requestDrain() }
            return
        }
        let outcome = one ? drain.run(until: began) : drain.run()
        let spent = now() - began
        LiveDrainStats.record(
            applied: outcome.applied.count, leftover: outcome.leftover, seconds: spent,
            guarded: one)
        if let wakeAt = outcome.wakeAt, armedWake.map({ wakeAt < $0 - 0.002 }) ?? true {
            armedWake = wakeAt
            let wait = UInt32(max(0, wakeAt - now()) * 1000) + 1
            Gtk.after(wait) { [weak self] in
                guard let self else { return }
                if let armed = self.armedWake, armed <= wakeAt + 0.002 { self.armedWake = nil }
                self.requestDrain()
            }
        }
    }

    /// The widget whose frame clock paints the window, read when a pass runs.
    weak var frames: MainWindow?

    /// How long to wait, in whole milliseconds, for the frame after the next one when the next one
    /// is not a grid frame; nil when the pass may run now. A clock that has not produced a frame for
    /// two refresh intervals is idle, and the apply starts a frame of its own.
    private func gridDelay(at time: TimeInterval) -> UInt32? {
        guard let widget = frames?.windowWidget, let clock = gtk_widget_get_frame_clock(widget)
        else { return nil }
        let lastMicros = gdk_frame_clock_get_frame_time(clock)
        var interval: gint64 = 0
        var presentation: gint64 = 0
        gdk_frame_clock_get_refresh_info(clock, lastMicros, &interval, &presentation)
        let last = Double(lastMicros) / 1_000_000
        let step = interval > 0 ? Double(interval) / 1_000_000 : 1.0 / 60
        guard time - last < step * 2 else { return nil }
        let next = last + step
        guard ActivityTuning.frameSlot(at: next) == ActivityTuning.frameSlot(at: last) else {
            return nil
        }
        return UInt32(((next - time + step * 0.25) * 1000).rounded(.up))
    }

    /// The one timer armed for a slot held back by its rate, so a pass every frame does not arm a
    /// timer every frame. Main loop only.
    private var armedWake: TimeInterval?
}

/// What the drain did over a window, for the soak line and the flight recorder: how many passes
/// ran, how long they took (total, worst and the 95th percentile), how many came from the
/// starvation guard, and the most slots that were ready at once — the deepest the mailboxes got.
enum LiveDrainStats {
    struct Window: Sendable {
        var passes = 0
        var guarded = 0
        var applied = 0
        var seconds = 0.0
        var worst = 0.0
        var ready = 0
        var samples: [Double] = []

        var p95: Double {
            guard !samples.isEmpty else { return 0 }
            let sorted = samples.sorted()
            return sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        }
    }

    private static let soak = Mutex(Window())
    private static let flight = Mutex(Window())

    static func record(applied: Int, leftover: Int, seconds: Double, guarded: Bool) {
        guard applied > 0 || leftover > 0 else { return }
        soak.withLock { add(&$0, applied: applied, leftover: leftover, seconds: seconds, guarded: guarded) }
        flight.withLock {
            add(&$0, applied: applied, leftover: leftover, seconds: seconds, guarded: guarded)
        }
    }

    private static func add(
        _ window: inout Window, applied: Int, leftover: Int, seconds: Double, guarded: Bool
    ) {
        window.passes += 1
        if guarded { window.guarded += 1 }
        window.applied += applied
        window.seconds += seconds
        window.worst = max(window.worst, seconds)
        window.ready = max(window.ready, applied + leftover)
        if window.samples.count < 4096 { window.samples.append(seconds) }
    }

    /// The soak's window, emptied.
    static func takeSoak() -> Window {
        soak.withLock { window in
            defer { window = Window() }
            return window
        }
    }

    /// The recorder's window, emptied.
    static func takeFlight() -> Window {
        flight.withLock { window in
            defer { window = Window() }
            return window
        }
    }
}

/// One per process: the window's drain and its clock, the one `ConversationHub` every pane and
/// background watch leases from, and the edge services that run once per conversation.
final class LiveRuntime: @unchecked Sendable {
    let clock = GtkHostClock()
    let drain: TileDrain
    let edges = LiveEdgeService()
    let hub: ConversationHub

    init() {
        drain = TileDrain(clock: clock)
        clock.attach(drain)
        hub = ConversationHub(open: LiveRuntime.open, clock: clock, edges: edges)
        edges.hub = hub
    }

    /// Who the edges hand work to on the main loop: the window that owns the panes.
    func attach(window: MainWindow) {
        guard edges.window !== window else { return }
        edges.window = window
        clock.frames = window
        CascadeBudget.onChange = { [weak window] in
            window?.splitHost?.eachPane { $0.restateDrainSlot() }
        }
    }

    /// The conversation for a key, built exactly as a pane used to build its own: the profile
    /// resolved through the directory (reloaded once if it is still empty), its backend, and the
    /// shared session cache.
    @Sendable static func open(_ key: LiveKey) async -> AgentConversation? {
        if await ServerDirectory.shared.profiles().isEmpty {
            await ServerDirectory.shared.reload()
        }
        guard
            let profile = await ServerDirectory.shared.profiles().first(where: {
                $0.id == key.profileID
            }), let backend = await ServerDirectory.shared.backend(for: profile)
        else { return nil }
        return AgentConversation(
            backend: backend, sessionID: key.sessionID, cache: AppCache.sessionCache)
    }
}

extension LiveKey {
    init(_ entry: SessionEntry) {
        self.init(profileID: entry.profileID, sessionID: entry.session.id)
    }

    /// The window's key for the same conversation, as the sidebar and the stores spell it.
    var pinKey: String { SessionPinStore.key(profileID, sessionID) }
}
