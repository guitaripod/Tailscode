import CoreFoundation
import Darwin
import Foundation

/// The length of every main run loop turn between `start` and `stop`, each in wall seconds and in
/// the main thread's own CPU seconds. A turn is what a person feels as one hitch: the loop wakes,
/// does everything it was handed (the press, a display link's tick, layout, the Core Animation
/// commit) and sleeps, and a turn longer than a frame is a dropped frame. CPU time is the figure
/// to trust on a shared Mac, where wall time includes waiting for a core.
@MainActor
final class BrainTurnMeter {
    struct Turn: Sendable {
        let wall: Double
        let cpu: Double
    }

    private(set) var turns: [Turn] = []
    private var observers: [CFRunLoopObserver] = []
    private var wallStart = 0.0
    private var cpuStart = 0.0
    private var awake = false

    nonisolated static func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }

    func start() {
        guard observers.isEmpty else { return }
        turns = []
        awake = true
        wallStart = MachClock.now()
        cpuStart = Self.threadCPU()
        let woke = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
        ) { [weak self] _, _ in
            MainThread.call { self?.begin() }
        }
        let slept = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, _ in
            MainThread.call { self?.end() }
        }
        for observer in [woke, slept].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    func stop() {
        for observer in observers {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observers = []
        awake = false
    }

    private func begin() {
        awake = true
        wallStart = MachClock.now()
        cpuStart = Self.threadCPU()
    }

    private func end() {
        guard awake else { return }
        awake = false
        turns.append(Turn(wall: MachClock.now() - wallStart, cpu: Self.threadCPU() - cpuStart))
    }

    var sequenceCPU: [Double] { turns.map { $0.cpu * 1000 } }

    var longestCPU: Double { (turns.map(\.cpu).max() ?? 0) * 1000 }
    var longestWall: Double { (turns.map(\.wall).max() ?? 0) * 1000 }
    var totalCPU: Double { turns.reduce(0) { $0 + $1.cpu } * 1000 }

    func turnsOver(cpuMilliseconds limit: Double) -> Int {
        turns.filter { $0.cpu * 1000 > limit }.count
    }
}
