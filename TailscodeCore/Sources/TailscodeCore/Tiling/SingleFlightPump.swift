import Foundation

/// The process-wide ceiling on transcript builds running at once.
///
/// Every full pane builds its rows off the UI thread, and five streaming panes each holding a
/// thread through a rebuild would take the whole machine's cores at the moment it is busiest. The
/// gate hands out `max(1, cores / 4)` permits and queues the rest without blocking a thread: a
/// waiting build is a closure in a list, not a thread asleep on a semaphore.
public final class BuildGate: @unchecked Sendable {
    public static let shared = BuildGate(
        limit: max(1, ProcessInfo.processInfo.activeProcessorCount / 4))

    public let limit: Int
    private let lock = NSLock()
    private var running = 0
    private var waiting: [@Sendable () -> Void] = []
    private let queue: DispatchQueue

    public init(limit: Int, queue: DispatchQueue = .global(qos: .userInitiated)) {
        self.limit = max(1, limit)
        self.queue = queue
    }

    /// Runs `job` on a background queue once a permit is free, releasing the permit when it returns.
    public func run(_ job: @escaping @Sendable () -> Void) {
        lock.lock()
        guard running < limit else {
            waiting.append(job)
            lock.unlock()
            return
        }
        running += 1
        lock.unlock()
        dispatch(job)
    }

    public var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func dispatch(_ job: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            job()
            finish()
        }
    }

    private func finish() {
        lock.lock()
        guard !waiting.isEmpty else {
            running -= 1
            lock.unlock()
            return
        }
        let next = waiting.removeFirst()
        lock.unlock()
        dispatch(next)
    }
}

/// At most one build in flight per consumer, always ending on the newest input.
///
/// A pane offered a state while it is still building the last one does not start a second build
/// and does not queue the state: it replaces whatever was waiting. When the build finishes it
/// delivers, then builds again from the newest input if one arrived. CPU is bounded by one build
/// per pane, an intermediate state that was overtaken is never built, and the last state offered
/// is always the last one delivered.
public final class SingleFlightPump<Input: Sendable, Output: Sendable>: @unchecked Sendable {
    private let work: @Sendable (Input) -> Output
    private let deliver: @Sendable (Output) -> Void
    private let gate: BuildGate
    private let lock = NSLock()
    private var pending: Input?
    private var running = false
    private var cancelled = false

    public init(
        gate: BuildGate = .shared,
        work: @escaping @Sendable (Input) -> Output,
        deliver: @escaping @Sendable (Output) -> Void
    ) {
        self.gate = gate
        self.work = work
        self.deliver = deliver
    }

    public func offer(_ input: Input) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        pending = input
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        gate.run { [self] in cycle() }
    }

    /// Drops the waiting input and withholds the delivery of a build already running. A cancelled
    /// pump ignores every later offer, so a pane that shut down cannot be woken by a late state.
    public func cancel() {
        lock.lock()
        cancelled = true
        pending = nil
        lock.unlock()
    }

    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !running && pending == nil
    }

    /// One build, then a hand back to the gate when a newer input is waiting, so a pump that is
    /// offered faster than it builds takes turns with the other panes instead of holding a permit.
    private func cycle() {
        lock.lock()
        guard !cancelled, let input = pending else {
            running = false
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        let output = work(input)
        lock.lock()
        let deliverable = !cancelled
        lock.unlock()
        if deliverable { deliver(output) }
        lock.lock()
        let more = !cancelled && pending != nil
        if !more { running = false }
        lock.unlock()
        if more { gate.run { [self] in cycle() } }
    }
}
