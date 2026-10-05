import CGtkShim
import Foundation
import Glibc
import TailscodeCore

/// What the main thread was doing when the loop stopped answering, read from the kernel by another
/// thread: its scheduler state (`R` running, `S` sleeping, `D` in uninterruptible IO), the CPU it
/// has burnt in clock ticks, and the kernel function it is waiting in. A loop stuck in `R` with the
/// ticks climbing is this app's own work; `D` with a `wchan` in the page-fault path is the machine.
struct MainThreadState: Sendable, Equatable {
    var state: String
    var ticks: UInt64
    var wchan: String

    /// The record's event tail, the kernel function first because a full slot keeps an event's
    /// head: `D folio_wait_bit cpu=812`.
    var line: String {
        "\(state) \(wchan) cpu=\(ticks)"
    }

    /// The main thread's task is the process's own id.
    static func read(pid: Int32 = getpid()) -> MainThreadState? {
        guard let stat = ProcFile.read("/proc/self/task/\(pid)/stat") else { return nil }
        return parse(stat: stat, wchan: ProcFile.read("/proc/self/task/\(pid)/wchan"))
    }

    /// Fields are counted after the command name's closing parenthesis, because the name itself
    /// may hold spaces and parentheses: the state is field 3, `utime` 14 and `stime` 15.
    static func parse(stat: String, wchan: String?) -> MainThreadState? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 12, let user = UInt64(fields[11]), let system = UInt64(fields[12]) else {
            return nil
        }
        let channel = wchan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MainThreadState(
            state: String(fields[0]), ticks: user + system,
            wchan: channel.isEmpty ? "?" : String(channel.prefix(40)))
    }
}

/// A helper thread that asks the main loop every half second whether it is still there.
///
/// The question is a `G_PRIORITY_DEFAULT` idle that stamps the time it ran; the answer is read
/// back as an atomic. Core's `StallWatch` turns silence into at most one stall and one deep event
/// per episode and a recovery when the loop answers again. The thread also carries the once-a-second
/// work that must keep going while the main loop is stuck — the pressure sensor and the flight
/// recorder — because a black box that stops writing when the loop freezes records everything
/// except the freeze. It never touches a widget.
final class Watchdog: @unchecked Sendable {
    private let condition = NSCondition()
    private var poked = false
    private var running = false
    private var watch = StallWatch()
    private var lastTick: TimeInterval = -.infinity

    /// Monotonic seconds, on the same clock the shim stamps answers with.
    static var now: TimeInterval { Double(g_get_monotonic_time()) / 1_000_000 }

    /// When the main loop last answered, in monotonic seconds.
    static var lastAnswer: TimeInterval { Double(tailscode_watchdog_answered()) / 1_000_000 }

    /// Starts the thread. `onStall` runs on it for each stall event with the main thread's state;
    /// `onTick` runs on it once a second, and at once after a ``poke()``, with whether it was poked.
    func start(
        onStall: @escaping @Sendable (StallWatch.Event, MainThreadState?) -> Void,
        onTick: @escaping @Sendable (_ now: TimeInterval, _ poked: Bool) -> Void
    ) {
        condition.lock()
        guard !running else {
            condition.unlock()
            return
        }
        running = true
        condition.unlock()
        tailscode_watchdog_ping()
        let thread = Thread { [self] in
            self.loop(onStall: onStall, onTick: onTick)
        }
        thread.name = "tailscode.watchdog"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Wakes the thread now rather than at the next half second: an event is waiting to be
    /// written.
    func poke() {
        condition.lock()
        poked = true
        condition.signal()
        condition.unlock()
    }

    private func loop(
        onStall: @Sendable (StallWatch.Event, MainThreadState?) -> Void,
        onTick: @Sendable (TimeInterval, Bool) -> Void
    ) {
        let ping = watch.policy.ping
        while true {
            condition.lock()
            if !poked { _ = condition.wait(until: Date(timeIntervalSinceNow: ping)) }
            let wasPoked = poked
            poked = false
            condition.unlock()

            let now = Self.now
            tailscode_watchdog_ping()
            if let event = watch.check(lastAnswer: Self.lastAnswer, now: now) {
                let state: MainThreadState?
                switch event {
                case .stall, .deep: state = MainThreadState.read()
                case .recovered: state = nil
                }
                onStall(event, state)
            }
            if wasPoked || now - lastTick >= 1 - ping / 4 {
                if !wasPoked { lastTick = now }
                onTick(now, wasPoked)
            }
        }
    }
}
