import CGtkShim
import Foundation
import Synchronization

/// Gives memory the app has just let go of back to the system.
///
/// glibc keeps what is freed inside its arenas for the next allocation, so a conversation that was
/// closed, a clip that was put away and a poster that was read leave the resident size where it
/// peaked until something asks for the pages back. Whoever lets go of something large says so
/// here; nothing runs while nothing is let go.
enum HeapReturn {
    private static let pending = Atomic<Bool>(false)
    private static let queue = DispatchQueue(label: "tailscode.heap-return", qos: .utility)

    /// Long enough for what was let go to have been freed by whoever still held it.
    static let settle: TimeInterval = 2

    /// How many passes have run and how long the last one took, for the harness.
    static let passes = Atomic<Int>(0)
    static let lastMicroseconds = Atomic<Int>(0)

    /// One pass a moment from now, off the main thread. Every call made before it runs is that
    /// same pass, so a burst of closes costs one walk of the arenas. O(1), any thread.
    static func soon() {
        guard pending.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
        else { return }
        queue.asyncAfter(deadline: .now() + settle) {
            pending.store(false, ordering: .relaxed)
            let began = ContinuousClock.now
            _ = tailscode_heap_trim()
            let spent = ContinuousClock.now - began
            lastMicroseconds.store(
                Int(spent.components.seconds) * 1_000_000
                    + Int(spent.components.attoseconds / 1_000_000_000_000),
                ordering: .relaxed)
            passes.add(1, ordering: .relaxed)
        }
    }
}
