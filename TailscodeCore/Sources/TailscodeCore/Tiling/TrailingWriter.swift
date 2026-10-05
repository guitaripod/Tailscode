import Foundation

/// One write, a moment after the last change. A divider drag or a burst of focus changes would
/// otherwise encode and store the whole layout on every step; this keeps only the newest value
/// and hands it to `write` once nothing has changed for `delay`, on a utility queue of its own —
/// never the main queue, which libdispatch never drains under GTK on Linux.
///
/// `flush` writes whatever is pending at once and returns after it is written, so every exit path
/// can call it and lose nothing. Writes never overlap and never go out of order. `write` must not
/// call back into the same writer.
public final class TrailingWriter<Value: Sendable>: @unchecked Sendable {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let write: @Sendable (Value) -> Void
    private let lock = NSLock()
    private var pending: Value?
    private var scheduled: DispatchWorkItem?

    public init(
        delay: TimeInterval = 0.25, label: String = "tailscode.trailing-writer",
        write: @escaping @Sendable (Value) -> Void
    ) {
        self.delay = max(0, delay)
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.write = write
    }

    /// Whether a value is waiting to be written.
    public var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    /// Replaces whatever is waiting with `value` and restarts the delay.
    public func schedule(_ value: Value) {
        let item = DispatchWorkItem { [weak self] in self?.writePending() }
        lock.lock()
        pending = value
        scheduled?.cancel()
        scheduled = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Writes the waiting value now, if there is one, and returns once it is written.
    public func flush() {
        lock.lock()
        scheduled?.cancel()
        scheduled = nil
        lock.unlock()
        queue.sync { writePending() }
    }

    private func writePending() {
        lock.lock()
        let value = pending
        pending = nil
        lock.unlock()
        if let value { write(value) }
    }
}
