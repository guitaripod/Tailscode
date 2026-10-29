import Foundation
import QuartzCore
import TailscodeCore

/// What the Mac does with Core's events: every read of the wall is compared with the one before, each
/// change becomes the gestures Core's queue plans for it under the person's style, and a tile that
/// has left the wall is remembered for a moment so its leaving still has a place to play. The queue is
/// Core's and the shapes are Core's; this holds them for the length of the window and nothing more.
@MainActor
final class WatchEffectsDriver {
    static let departedFor: TimeInterval = 1.5

    private(set) var queue = WallEffectQueue()
    private var gone: [String: (rect: WallRect, until: TimeInterval)] = [:]

    var live: [WallEffect] { queue.live }

    func isActive(at t: TimeInterval) -> Bool { queue.isActive(at: t) }

    /// Starts a gesture for each thing that changed from `previous` to `next`, and returns what changed.
    @discardableResult
    func observe(
        from previous: AgentWall?, to next: AgentWall, previousLayout: WallLayout?, style: WallStyle,
        at t: TimeInterval
    ) -> [WallEvent] {
        let events = WallEvents.between(previous, next)
        guard !events.isEmpty, let previous else { return events }
        for event in events where event.kind == .left {
            guard let index = previous.tiles.firstIndex(where: { $0.id == event.tile }),
                let layout = previousLayout, layout.tiles.indices.contains(index)
            else { continue }
            let squad = layout.squads.indices.contains(index) ? layout.squads[index] : nil
            gone[event.tile] = ((squad?.parent ?? layout.tiles[index]), t + Self.departedFor)
        }
        queue.add(events, at: t, style: style, contexts: Self.contexts(from: previous, to: next))
        return events
    }

    /// The context share each tile fell from and to, for the drain a compaction plays.
    static func contexts(from previous: AgentWall, to next: AgentWall) -> [String: (from: Double, to: Double)] {
        var shares: [String: Double] = [:]
        for tile in previous.tiles { if let share = tile.contextShare { shares[tile.id] = share } }
        var out: [String: (from: Double, to: Double)] = [:]
        for tile in next.tiles {
            if let was = shares[tile.id], let now = tile.contextShare { out[tile.id] = (was, now) }
        }
        return out
    }

    func prune(at t: TimeInterval) {
        queue.prune(at: t)
        gone = gone.filter { $0.value.until > t }
    }

    func departed(at t: TimeInterval) -> [String: WallRect] {
        gone.filter { $0.value.until > t }.mapValues(\.rect)
    }

    func reset() {
        queue = WallEffectQueue()
        gone = [:]
    }
}
