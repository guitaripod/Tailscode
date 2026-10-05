import Foundation
@testable import TailscodeCore

/// A clock a test moves by hand, counting the drains it was asked for.
final class ManualClock: HostClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    private var drains = 0

    init(_ start: TimeInterval = 1000) {
        time = start
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func requestDrain() {
        lock.lock()
        drains += 1
        lock.unlock()
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        time += seconds
        lock.unlock()
    }

    var drainRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return drains
    }

    func resetDrains() {
        lock.lock()
        drains = 0
        lock.unlock()
    }
}

/// A thread-safe counter and log for closures a test hands to the runtime.
final class Tally<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func add(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var count: Int { all.count }
}

/// Polls `condition` until it holds or `timeout` passes, for work that lands on another thread.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}
