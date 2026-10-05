import Darwin
import Foundation
import TailscodeCore

/// What the main thread was doing when it stopped answering: the CPU it burned since it last
/// answered, and whether the scheduler had it running or waiting. A stall that burned its whole
/// length is a spin; one that burned nothing is a wait on a lock, a disk or the window server.
struct MainThreadState: Sendable, Equatable {
    var cpuSinceAnswer: TimeInterval
    var running: Bool

    /// `cpu 2.98 R` — short enough to ride inside the recorder's event.
    var summary: String {
        String(format: "cpu %.2f ", cpuSinceAnswer) + (running ? "R" : "W")
    }
}

/// The main thread's pulse, taken from a thread that is not the main thread.
///
/// A timer on a global queue pings `DispatchQueue.main` every half second, one ping in flight at
/// a time, and Core's `StallWatch` reads how long the answer has been coming: silent past three
/// seconds is a stall record carrying the main thread's CPU and run state (from `thread_info`) and
/// a hint the loop applies as shed level 4 the moment it answers again; silent past ten is a deep
/// record. It never touches a view — the whole point is that it still runs when the thread that
/// owns the views does not.
final class Watchdog: @unchecked Sendable {
    typealias Report = @Sendable (StallWatch.Event, MainThreadState?) -> Void

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let queue = DispatchQueue(label: "tailscode.watchdog", qos: .userInitiated)
    private var watch: StallWatch
    private var timer: DispatchSourceTimer?
    private var lastAnswer: TimeInterval = 0
    private var pinging = false
    private var hint = false
    private var mainThread: thread_act_t = 0
    private var cpuAtAnswer: TimeInterval?
    private let report: Report
    private let onResume: @MainActor @Sendable () -> Void

    /// - Parameters:
    ///   - report: called on the watchdog's own queue for every stall, deep stall and recovery.
    ///   - onResume: called on the main thread when it answers after a stall, so the level-4 hint
    ///     is applied at once rather than at the next sample.
    init(
        policy: StallPolicy = StallPolicy(),
        clock: @escaping @Sendable () -> TimeInterval = MachClock.now,
        report: @escaping Report,
        onResume: @escaping @MainActor @Sendable () -> Void
    ) {
        self.watch = StallWatch(policy: policy)
        self.clock = clock
        self.report = report
        self.onResume = onResume
    }

    deinit {
        timer?.cancel()
    }

    /// Starts pinging. Called on the main thread, whose port it keeps for `thread_info`; the port
    /// comes from `pthread_mach_thread_np`, which takes no reference that would need releasing.
    @MainActor
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        mainThread = pthread_mach_thread_np(pthread_self())
        lastAnswer = clock()
        cpuAtAnswer = Self.cpuState(of: mainThread)?.cpu
        let source = DispatchSource.makeTimerSource(queue: queue)
        let ping = watch.policy.ping
        source.schedule(
            deadline: .now() + ping, repeating: ping, leeway: .milliseconds(Int(ping * 100)))
        source.setEventHandler { @Sendable [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    /// Whether a stall happened since the last time anyone asked. Asking consumes it.
    func takeHint() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let held = hint
        hint = false
        return held
    }

    var isStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return watch.isStalled
    }

    private func tick() {
        let now = clock()
        lock.lock()
        if !pinging {
            pinging = true
            DispatchQueue.main.async { [weak self] in self?.answered() }
        }
        let event = watch.check(lastAnswer: lastAnswer, now: now)
        var state: MainThreadState?
        if let event {
            if case .stall = event { hint = true }
            if let sample = Self.cpuState(of: mainThread) {
                state = MainThreadState(
                    cpuSinceAnswer: max(0, sample.cpu - (cpuAtAnswer ?? sample.cpu)),
                    running: sample.running)
            }
        } else if !watch.isStalled, now - lastAnswer < watch.policy.ping * 2 {
            cpuAtAnswer = Self.cpuState(of: mainThread)?.cpu
        }
        lock.unlock()
        if let event { report(event, state) }
    }

    /// The answer also says which thread drains the main queue. In the app that is always the
    /// main thread; under `dispatchMain` — the selftest — it is whichever worker is free.
    private func answered() {
        let thread = pthread_mach_thread_np(pthread_self())
        lock.lock()
        mainThread = thread
        lastAnswer = clock()
        pinging = false
        let resumed = hint
        lock.unlock()
        guard resumed else { return }
        MainActor.assumeIsolated { onResume() }
    }

    /// User plus system time the thread has run, and whether it is on a core right now.
    static func cpuState(of thread: thread_act_t) -> (cpu: TimeInterval, running: Bool)? {
        guard thread != 0 else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system =
            Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return (user + system, info.run_state == TH_STATE_RUNNING)
    }

    /// The recorder's event for one moment of an episode: `stall 3012ms cpu 2.98 R`,
    /// `stall 10040ms D cpu 0.01 W`, `stall end 4.2s`.
    static func event(_ event: StallWatch.Event, _ state: MainThreadState?) -> String {
        let tail = state.map { " " + $0.summary } ?? ""
        switch event {
        case .stall(let seconds):
            return "stall \(Int((seconds * 1000).rounded()))ms" + tail
        case .deep(let seconds):
            return "stall \(Int((seconds * 1000).rounded()))ms D" + tail
        case .recovered(let seconds):
            return String(format: "stall end %.1fs", seconds)
        }
    }
}
