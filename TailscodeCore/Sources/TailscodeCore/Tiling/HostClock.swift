import Foundation

/// The one seam between Core's tiling runtime and a toolkit. Core never touches a main queue: on
/// Linux `g_application_run` never drains libdispatch's, so awaiting a main-actor type there hangs
/// with no log. The host supplies a monotonic clock and a way to ask for exactly one drain.
public protocol HostClock: Sendable {
    /// Monotonic seconds. Only differences are meaningful.
    func now() -> TimeInterval

    /// Schedules one drain of the frame's work. Idempotent while a drain is already pending, and
    /// callable from any thread.
    func requestDrain()
}
