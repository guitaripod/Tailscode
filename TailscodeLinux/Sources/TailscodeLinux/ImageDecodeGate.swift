import Foundation
import TailscodeCore

/// The one door every picture read and decode goes through. Decoding is CPU and disk work that
/// does not touch the toolkit, so it runs on threads of its own rather than on the cooperative
/// pool — a Swift task that blocks on a decode holds a pool thread for its whole length, and a
/// chat opened on a hundred screenshots used to grow libdispatch to dozens of them. The gate is
/// two wide while the window is calm or busy, one wide from the loaded level on, and from the
/// strained level it also rests between decodes, so a window that is already struggling is not
/// asked to decode a backlog as fast as a disk can supply it.
///
/// What waits is served by who is asked for most urgently, not in arrival order: a picture
/// somebody opened comes first, then the one in the newest row — which is what is on screen when
/// a chat opens at its end — and between equals the earlier request.
final class ImageDecodeGate: @unchecked Sendable {
    static let shared = ImageDecodeGate()

    private static let calmWidth = 2
    private static let strainedRest: TimeInterval = 0.05

    private let lock = NSLock()
    private var waiting: [Job] = []
    private var running = 0
    private var width = ImageDecodeGate.calmWidth
    private var rest: TimeInterval = 0
    private var sequence = 0
    private let workers = DispatchQueue(
        label: "tailscode.image-decode", qos: .utility, attributes: .concurrent)

    /// Sets the width and the rest between decodes from the window's shed level. Main loop only,
    /// where `CascadeBudget` lives; called whenever work is queued and whenever a batch lands, so
    /// a level that changes under a backlog is felt by the backlog.
    func adapt(to level: ShedLevel) {
        lock.lock()
        width = level >= .loaded ? 1 : Self.calmWidth
        rest = level >= .strained ? Self.strainedRest : 0
        lock.unlock()
        pump()
    }

    /// Runs `work` on a gate thread and returns what it made, or nil when the task was cancelled
    /// before the work started. A higher `rank` is served sooner; urgent work goes ahead of all
    /// of it.
    func run<Result: Sendable>(
        urgent: Bool = false, rank: Int = .max, _ work: @escaping @Sendable () -> Result
    ) async -> Result? {
        let slot = CancelSlot()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
                let job = Job(
                    urgent: urgent, rank: rank,
                    run: {
                        continuation.resume(returning: work())
                    },
                    abandon: {
                        continuation.resume(returning: nil)
                    })
                if slot.set(job, in: self) {
                    job.abandon()
                    return
                }
                lock.lock()
                sequence += 1
                job.sequence = sequence
                waiting.append(job)
                lock.unlock()
                pump()
            }
        } onCancel: {
            slot.cancel()
        }
    }

    fileprivate func withdraw(_ job: Job) {
        lock.lock()
        let index = waiting.firstIndex { $0 === job }
        if let index { waiting.remove(at: index) }
        lock.unlock()
        if index != nil { job.abandon() }
    }

    private func pump() {
        while let next = take() {
            workers.async { [self] in
                next.run()
                lock.lock()
                let pause = rest
                lock.unlock()
                if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                lock.lock()
                running -= 1
                lock.unlock()
                pump()
            }
        }
    }

    private func take() -> Job? {
        lock.lock()
        defer { lock.unlock() }
        guard running < width, !waiting.isEmpty else { return nil }
        var best = 0
        for index in waiting.indices.dropFirst() where waiting[index].precedes(waiting[best]) {
            best = index
        }
        running += 1
        return waiting.remove(at: best)
    }
}

private final class Job: @unchecked Sendable {
    let urgent: Bool
    let rank: Int
    var sequence = 0
    let run: @Sendable () -> Void
    let abandon: @Sendable () -> Void

    init(
        urgent: Bool, rank: Int, run: @escaping @Sendable () -> Void,
        abandon: @escaping @Sendable () -> Void
    ) {
        self.urgent = urgent
        self.rank = rank
        self.run = run
        self.abandon = abandon
    }

    func precedes(_ other: Job) -> Bool {
        if urgent != other.urgent { return urgent }
        if rank != other.rank { return rank > other.rank }
        return sequence < other.sequence
    }
}

/// A cancel that may arrive before the job is queued: remembered, and applied the moment it is.
private final class CancelSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var job: Job?
    private var gate: ImageDecodeGate?
    private var cancelled = false

    /// Whether the cancel had already come, in which case the job must not be queued.
    func set(_ next: Job, in owner: ImageDecodeGate) -> Bool {
        lock.lock()
        job = next
        gate = owner
        let already = cancelled
        lock.unlock()
        return already
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let held = job
        let owner = gate
        lock.unlock()
        if let held, let owner { owner.withdraw(held) }
    }
}
