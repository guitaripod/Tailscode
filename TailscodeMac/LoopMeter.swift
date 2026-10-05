import CoreFoundation
import Darwin
import Foundation
import TailscodeCore

/// Monotonic seconds from mach time, the clock every seatbelt shares. It stops while the Mac
/// sleeps, so a lid closed for an hour is never read as an hour-long stall.
enum MachClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func now() -> TimeInterval {
        Double(mach_absolute_time()) * secondsPerTick
    }
}

/// How busy the main run loop is, measured where the loop itself says it stops and starts.
///
/// Two observers on the main run loop: one runs first when the loop wakes (`afterWaiting`) and one
/// runs last before it sleeps (`beforeWaiting`), so the span between them is everything the loop did
/// for that wake — events, timers, main-queue blocks, layout and the Core Animation commit — and the
/// span from sleeping to waking is idle. Both go into Core's `LoopLoad`, which keeps the one- and
/// two-second windows the governor reads. Observing in the common modes keeps a live resize, a menu
/// being tracked or a modal sheet counted rather than invisible.
final class LoopMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private var load = LoopLoad()
    private var awakeSince: TimeInterval?
    private var asleepSince: TimeInterval?
    private var observers: [CFRunLoopObserver] = []
    private var runLoop: CFRunLoop?

    init(clock: @escaping @Sendable () -> TimeInterval = MachClock.now) {
        self.clock = clock
    }

    deinit {
        uninstall()
    }

    /// Starts measuring `runLoop`. Called from the thread that runs it, which is mid-wake, so the
    /// slice in progress counts from now.
    func install(on runLoop: CFRunLoop = CFRunLoopGetMain()) {
        lock.lock()
        defer { lock.unlock() }
        guard observers.isEmpty else { return }
        awakeSince = clock()
        asleepSince = nil
        let woke = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { [weak self] _, _ in self?.woke() }
        let sleeping = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, _ in self?.sleeping() }
        for observer in [woke, sleeping].compactMap({ $0 }) {
            CFRunLoopAddObserver(runLoop, observer, .commonModes)
            observers.append(observer)
        }
        self.runLoop = runLoop
    }

    func uninstall() {
        lock.lock()
        let held = observers
        observers = []
        let loop = runLoop
        runLoop = nil
        lock.unlock()
        for observer in held {
            if let loop { CFRunLoopRemoveObserver(loop, observer, .commonModes) }
            CFRunLoopObserverInvalidate(observer)
        }
    }

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !observers.isEmpty
    }

    /// Busy share and worst slice over the last one and two seconds.
    func reading() -> LoopReading {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        return load.reading(now: now)
    }

    private func woke() {
        let now = clock()
        lock.lock()
        if let start = asleepSince { load.record(.idle, from: start, to: now) }
        asleepSince = nil
        awakeSince = now
        lock.unlock()
    }

    private func sleeping() {
        let now = clock()
        lock.lock()
        if let start = awakeSince { load.record(.busy, from: start, to: now) }
        awakeSince = nil
        asleepSince = now
        lock.unlock()
    }
}
