import QuartzCore

/// A short stretch in which the window is in the middle of a motion the reader is watching, and
/// anything that can wait does.
///
/// A sent prompt rises for a little over half a second, and the server answering it — the turn
/// starting, the chat going live in the list beside it — lands in that half second. On an iPad the
/// chat list in the column next to the conversation redrew itself for the turn starting, eighty
/// milliseconds of one frame in the middle of the rise. What can be drawn a moment later is: a
/// screen beside the one in motion asks `remaining` before drawing and comes back when it is over.
@MainActor
final class MotionQuiet {
    static let shared = MotionQuiet()

    private var until: CFTimeInterval = 0

    /// Asks for quiet for `seconds` from now, never shortening quiet already asked for.
    func hold(for seconds: CFTimeInterval) {
        until = max(until, CACurrentMediaTime() + seconds)
    }

    /// The motion ended early, landed or was caught by a finger.
    func release() {
        until = 0
    }

    /// How long until the quiet is over, or nil when there is none.
    func remaining() -> CFTimeInterval? {
        let left = until - CACurrentMediaTime()
        return left > 0 ? left : nil
    }
}
