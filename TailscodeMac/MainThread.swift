import Darwin
import Foundation

/// AppKit and CoreFoundation call back on the main thread from outside a Swift job.
///
/// Asking the runtime whether this thread is the main executor segfaults on macOS 27 during
/// event delivery and run-loop observation (`swift_task_isMainExecutorImpl`, a fault at `0x30`
/// or `0x800`), which is what killed a click on a capability row and the frame observer beside
/// it. The Mac targets compile with `-disable-dynamic-actor-isolation`, and this helper's cast
/// keeps the closure's own prologue from asking again: the callback is already on the main
/// thread, and the work runs there.
/// A reference a C callback may carry: a run-loop observer outlives the view it measures unless
/// the closure holds that view weakly, and a `@Sendable` closure cannot capture the view itself.
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

enum MainThread {
    static func call<T>(_ body: @MainActor () -> T) -> T {
        precondition(pthread_main_np() != 0, "MainThread.call off the main thread")
        return withoutActuallyEscaping(body) { escaped in
            unsafeBitCast(escaped, to: (() -> T).self)()
        }
    }
}
