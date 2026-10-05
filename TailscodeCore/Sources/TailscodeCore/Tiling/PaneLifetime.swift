import Foundation

/// Everything a pane started that must stop when the pane stops being alive.
///
/// A tick, a timer, a task, an observer token and a lease each used to be a field some exit path
/// had to remember; the audit found tasks surviving `shutdown` because one path forgot. A pane
/// registers each one here and `cancelAll` ends them together, on shutdown, on demotion to parked
/// and on being hidden. The lifetime outlives one `cancelAll`, because a pane parked now may be
/// resumed later and register again.
public final class PaneLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancels: [@Sendable () -> Void] = []

    public init() {}

    public func add(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        cancels.append(cancel)
        lock.unlock()
    }

    /// Runs every registered cancel once, outside the lock so a cancel may register again or
    /// cancel another lifetime, and leaves the lifetime empty and reusable.
    public func cancelAll() {
        lock.lock()
        let running = cancels
        cancels = []
        lock.unlock()
        for cancel in running { cancel() }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels.count
    }
}
