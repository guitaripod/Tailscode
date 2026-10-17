import Foundation
import TailscodeCore

/// The one door every picture read and decode goes through. Decoding is CPU and disk work that
/// does not touch the toolkit, so it runs on a small operation queue of its own rather than on the
/// cooperative pool — a Swift task that blocks on a decode holds a pool thread for its whole
/// length, and a chat opened on a hundred screenshots used to grow libdispatch to dozens of them.
/// The queue is two wide while the window is calm or busy, one wide from the loaded level on, and
/// from the strained level it also rests between decodes, so a window that is already struggling
/// is not asked to decode a backlog as fast as a disk can supply it.
final class ImageDecodeGate: @unchecked Sendable {
    static let shared = ImageDecodeGate()

    private static let calmWidth = 2
    private static let strainedRest: TimeInterval = 0.05

    private let queue: OperationQueue
    private let lock = NSLock()
    private var rest: TimeInterval = 0

    init() {
        queue = OperationQueue()
        queue.name = "tailscode.image-decode"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = Self.calmWidth
    }

    /// Sets the width and the rest between decodes from the window's shed level. Main loop only,
    /// where `CascadeBudget` lives; called whenever work is queued and whenever a batch lands, so
    /// a level that changes under a backlog is felt by the backlog.
    func adapt(to level: ShedLevel) {
        let width = level >= .loaded ? 1 : Self.calmWidth
        if queue.maxConcurrentOperationCount != width { queue.maxConcurrentOperationCount = width }
        lock.lock()
        rest = level >= .strained ? Self.strainedRest : 0
        lock.unlock()
    }

    /// Runs `work` on the queue and returns what it made, or nil when the task was cancelled
    /// before the work started. Urgent work — a picture somebody asked to look at — goes ahead of
    /// the backlog; the rest runs in the order it was asked for, which on a first fill is the
    /// newest rows first because the tail of a transcript is built before the history above it.
    func run<Result: Sendable>(
        urgent: Bool = false, _ work: @escaping @Sendable () -> Result
    ) async -> Result? {
        let slot = CancelSlot()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
                let operation = GateOperation<Result>(work: work, rest: { [weak self] in self?.currentRest ?? 0 })
                operation.attach(continuation)
                operation.queuePriority = urgent ? .high : .normal
                operation.completionBlock = { [weak operation] in operation?.finish(nil) }
                slot.set(operation)
                queue.addOperation(operation)
            }
        } onCancel: {
            slot.cancel()
        }
    }

    private var currentRest: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return rest
    }
}

/// A cancel that may arrive before the operation exists: remembered, and applied the moment it
/// does.
private final class CancelSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Operation?
    private var cancelled = false

    func set(_ next: Operation) {
        lock.lock()
        operation = next
        let already = cancelled
        lock.unlock()
        if already { next.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let held = operation
        lock.unlock()
        held?.cancel()
    }
}

/// One unit of the gate's work. The continuation is resumed exactly once: with the work's result
/// when it ran, or with nil from the completion block when the operation was cancelled before it
/// started — a cancelled operation is never asked to run, so nothing else would answer it.
private final class GateOperation<Result: Sendable>: Operation, @unchecked Sendable {
    private let work: @Sendable () -> Result
    private let rest: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result?, Never>?

    init(work: @escaping @Sendable () -> Result, rest: @escaping @Sendable () -> TimeInterval) {
        self.work = work
        self.rest = rest
    }

    func attach(_ next: CheckedContinuation<Result?, Never>) {
        lock.lock()
        continuation = next
        lock.unlock()
    }

    override func main() {
        guard !isCancelled else { return }
        let made = work()
        finish(made)
        let pause = rest()
        if pause > 0 { Thread.sleep(forTimeInterval: pause) }
    }

    func finish(_ value: Result?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}
