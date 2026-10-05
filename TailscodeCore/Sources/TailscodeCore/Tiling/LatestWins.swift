import Foundation

/// A one-value mailbox between a producer on any thread and a consumer that drains once a frame.
///
/// A stream that posts every state to the UI thread is an unbounded queue: when the UI falls
/// behind, the backlog grows with the stream's rate and every queued state is built in turn even
/// though only the newest is ever shown. Here the producer overwrites and the consumer takes
/// whatever is newest, so the depth is at most one and skipped states are simply never built.
public final class LatestWins<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    public init() {}

    /// Overwrites the slot. True only on the clean-to-dirty transition, so the caller schedules
    /// exactly one wake however many values arrive before the consumer runs.
    @discardableResult
    public func post(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = self.value == nil
        self.value = value
        return wasEmpty
    }

    /// The newest value, leaving the slot clean.
    public func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let taken = value
        value = nil
        return taken
    }

    /// The newest value without taking it.
    public func peek() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public var isDirty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != nil
    }
}
