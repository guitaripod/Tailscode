import Foundation

/// The rows a phone's compact step list shows when the list is longer than its slots: which steps
/// stand, what the first and last slots say about the ones that do not, and a step waiting on the
/// person ahead of all of them. The list holds still (nothing in it scrolls), so this is the whole
/// of "which rows are the first N": the head of the list, the tail while a running turn is
/// followed, and the window around the cursor otherwise, so the step being read is always on the
/// stage.
public struct NeuralCompactWindow: Sendable, Equatable {
    public enum Slot: Sendable, Equatable {
        /// The step the turn is stopped on, with the person's answer awaited.
        case ask(stepID: String)
        /// "N earlier steps": what lies before the first step shown.
        case earlier(count: Int)
        case step(stepID: String)
        /// "N more steps": what lies after the last step shown.
        case more(count: Int)
    }

    public let slots: [Slot]
    /// The visible positions the window shows: `shown.lowerBound` steps come before it and
    /// `total - shown.upperBound` after.
    public let shown: Range<Int>
    public let total: Int

    public var hiddenBefore: Int { shown.lowerBound }
    public var hiddenAfter: Int { total - shown.upperBound }
    public var hidesSteps: Bool { hiddenBefore > 0 || hiddenAfter > 0 }

    public var stepIDs: [String] {
        slots.compactMap { if case .step(let id) = $0 { return id } else { return nil } }
    }
}

extension NeuralStepList {
    /// The window of a list into `slots` rows. A list that fits is shown whole; one that does
    /// not gives up its first and last slot to "earlier" and "more" where steps lie beyond them.
    /// A step waiting on the person takes the first slot of any list.
    public func compactWindow(slots limit: Int) -> NeuralCompactWindow {
        var out: [NeuralCompactWindow.Slot] = []
        var room = max(limit, 3)
        if let ask = pendingAskID {
            out.append(.ask(stepID: ask))
            room -= 1
        }
        let count = visibleCount
        let range = Self.compactRange(
            count: count, room: room, cursor: cursor.flatMap(visibleIndex(of:)),
            following: isFollowing)
        if range.lowerBound > 0 { out.append(.earlier(count: range.lowerBound)) }
        for position in range {
            if let row = row(atVisible: position) { out.append(.step(stepID: row.id)) }
        }
        if range.upperBound < count { out.append(.more(count: count - range.upperBound)) }
        return NeuralCompactWindow(slots: out, shown: range, total: count)
    }

    /// The positions shown of `count` steps in `room` slots, the end slots counted when they say
    /// something.
    static func compactRange(count: Int, room: Int, cursor: Int?, following: Bool) -> Range<Int> {
        guard count > room else { return 0..<count }
        let tail = room - 1
        if following { return (count - tail)..<count }
        guard let cursor else { return 0..<tail }
        if cursor < tail { return 0..<tail }
        if cursor >= count - tail { return (count - tail)..<count }
        let middle = room - 2
        let start = min(max(cursor - middle / 2, 1), count - middle - 1)
        return start..<(start + middle)
    }
}
