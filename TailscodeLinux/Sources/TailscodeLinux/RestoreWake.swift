import Foundation
import TailscodeCore

/// The staggered wake of a restored window: panes open one at a time, the focused pane first and
/// the rest most recently focused first, `spacing` apart, so a relaunch never opens every stream in
/// one frame. A pane is woken only once its chat is ready — the listing carries it — and a ready
/// pane never waits on an earlier one that is not, because a server that does not answer this
/// minute must not hold the other chats closed.
struct RestoreWake: Sendable, Equatable {
    enum Step: Sendable, Equatable {
        /// Open this pane now.
        case wake(PaneID)
        /// Something is ready but the spacing has not elapsed; ask again after this long.
        case wait(TimeInterval)
        /// Nothing is ready.
        case idle
    }

    let spacing: TimeInterval
    private var rank: [PaneID: Int]
    private var ready: Set<PaneID> = []
    private var lastWake: TimeInterval?

    /// - Parameter order: the wake order, as `RestorePlan.wakeSchedule` gives it.
    init(order: [PaneID], spacing: TimeInterval = RestorePlan.wakeSpacing) {
        self.spacing = spacing
        var rank: [PaneID: Int] = [:]
        for (index, pane) in order.enumerated() where rank[pane] == nil { rank[pane] = index }
        self.rank = rank
    }

    /// The order for a layout: focused first, then most recently focused.
    init(layout: SplitLayout, spacing: TimeInterval = RestorePlan.wakeSpacing) {
        self.init(
            order: RestorePlan.wakeSchedule(
                focused: layout.focusedPane, recent: layout.recentlyFocused, spacing: spacing
            ).map(\.pane),
            spacing: spacing)
    }

    var isWaiting: Bool { !ready.isEmpty }

    mutating func markReady(_ pane: PaneID) {
        ready.insert(pane)
    }

    mutating func forget(_ pane: PaneID) {
        ready.remove(pane)
    }

    mutating func take(now: TimeInterval) -> Step {
        guard !ready.isEmpty else { return .idle }
        if let lastWake, now - lastWake < spacing {
            return .wait(spacing - (now - lastWake))
        }
        let next = ready.min { lhs, rhs in
            let left = rank[lhs] ?? Int.max
            let right = rank[rhs] ?? Int.max
            return left != right ? left < right : lhs.raw < rhs.raw
        }
        guard let next else { return .idle }
        ready.remove(next)
        lastWake = now
        return .wake(next)
    }
}
