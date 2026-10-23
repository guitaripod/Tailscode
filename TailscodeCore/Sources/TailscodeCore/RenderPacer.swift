import CodingAgentKit
import Foundation

/// How often a transcript may be drawn again while it only grows.
///
/// A conversation is drawn again from all its messages for every state its stream emits, and while
/// an answer is being written that is every few milliseconds. What one draw costs grows with the
/// conversation, so a long one drawn at the rate the words arrive spends the whole main thread on
/// drawing and leaves none for a finger. The pacer gives drawing a share of the thread instead:
/// after a draw that took `c` seconds the next growth waits until drawing would be no more than
/// `share` of the time, and what is drawn when the wait is over is the newest state, not the one
/// that asked. The wait is capped at `longestWait`, so the words never trail what arrived by more
/// than that, and a small conversation, whose draw is cheap, is never made to wait at all.
///
/// Only growth waits. A message arriving, the turn ending, a question, a phase change: anything
/// that is not the same words getting longer is drawn the moment it arrives.
public struct RenderPacer: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case now
        case after(Double)
    }

    public static let share = 0.25
    public static let longestWait = 0.15

    public private(set) var cost: Double = 0
    public private(set) var earliest: Double = 0

    public init() {}

    public mutating func offer(at now: Double, isGrowth: Bool) -> Verdict {
        guard isGrowth, now < earliest else { return .now }
        return .after(earliest - now)
    }

    /// A draw took from `start` to `end`. The cost it is paced by rises at once and falls slowly,
    /// so one cheap draw between expensive ones does not open the throttle.
    public mutating func drew(from start: Double, to end: Double) {
        let took = max(0, end - start)
        cost = max(took, cost * 0.8 + took * 0.2)
        earliest = end + min(Self.longestWait, cost * (1 / Self.share - 1))
    }

    /// Whether `new` is the transcript `old` was with only the newest words added: the same
    /// messages, the same last message with the same parts, and nothing else about the
    /// conversation different. Anything this misses is merely drawn a little late.
    public static func isGrowth(from old: ConversationState, to new: ConversationState) -> Bool {
        guard old.messages.count == new.messages.count, let was = old.messages.last,
            let now = new.messages.last, was.id == now.id, was.role == now.role,
            was.isStreaming == now.isStreaming, was.parts.count == now.parts.count
        else { return false }
        var before = old
        var after = new
        before.messages = []
        after.messages = []
        return before == after
    }
}
