import Foundation

/// One thing that happened on the wall between two reads.
public struct WallEvent: Sendable, Equatable {
    public enum Kind: Sendable, Hashable, CaseIterable {
        case step, joined, left, asked, answered, finished, failed, stopped, retried, quiet, resumed
        case compacted, away, back, workerStarted, workerEnded, workerQuiet, workerStuck
    }

    public let kind: Kind
    public let tile: String
    public let worker: String?

    public init(kind: Kind, tile: String, worker: String? = nil) {
        self.kind = kind
        self.tile = tile
        self.worker = worker
    }
}

/// What changed from one read of the wall to the next, said as events a client can draw. States are
/// compared by case and never by what they carry: a wait that deepens or a quiet counter that ticks
/// is not an event.
public enum WallEvents {
    static let compactionDrop = 0.2

    public static func between(_ previous: AgentWall?, _ next: AgentWall) -> [WallEvent] {
        guard let previous else { return [] }
        let before = Dictionary(previous.tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let nowIDs = Set(next.tiles.map(\.id))
        var events: [WallEvent] = []
        for tile in next.tiles {
            guard let old = before[tile.id] else {
                events.append(WallEvent(kind: .joined, tile: tile.id))
                continue
            }
            events += tileEvents(from: old, to: tile)
            events += workerEvents(from: old, to: tile)
        }
        for tile in previous.tiles where !nowIDs.contains(tile.id) {
            events.append(WallEvent(kind: .left, tile: tile.id))
        }
        return events
    }

    private static func tileEvents(from old: WallTile, to tile: WallTile) -> [WallEvent] {
        var kinds: [WallEvent.Kind] = []
        if tile.state.isNeedsYou, !old.state.isNeedsYou { kinds.append(.asked) }
        if old.state.isNeedsYou, tile.state.isActiveWork { kinds.append(.answered) }
        if let ending = ending(from: old.state, to: tile.state) { kinds.append(ending) }
        if case .retrying(let attempt) = tile.state {
            if case .retrying(let was) = old.state {
                if attempt > was { kinds.append(.retried) }
            } else {
                kinds.append(.retried)
            }
        }
        if tile.state.isQuiet, !old.state.isQuiet { kinds.append(.quiet) }
        if old.state.waitsOnProvider, tile.state.isWorkingOrThinking { kinds.append(.resumed) }
        if let was = old.contextShare, let now = tile.contextShare, was - now >= compactionDrop {
            kinds.append(.compacted)
        }
        if tile.state.isAway, !old.state.isAway { kinds.append(.away) }
        if old.state.isAway, !tile.state.isAway { kinds.append(.back) }
        if stepped(from: old, to: tile) { kinds.append(.step) }
        return kinds.map { WallEvent(kind: $0, tile: tile.id) }
    }

    private static func ending(from old: WallState, to state: WallState) -> WallEvent.Kind? {
        guard case .finished(let outcome) = state else { return nil }
        if case .finished(let was) = old, was.group == outcome.group { return nil }
        switch outcome {
        case .done, .unknown: return .finished
        case .failed: return .failed
        case .stopped: return .stopped
        }
    }

    private static func stepped(from old: WallTile, to tile: WallTile) -> Bool {
        guard case .working = old.state, case .working = tile.state else { return false }
        if old.steps.first?.id != tile.steps.first?.id { return true }
        if old.words != tile.words { return true }
        if let was = old.beat?.last, let now = tile.beat?.last { return now > was }
        return false
    }

    private static func workerEvents(from old: WallTile, to tile: WallTile) -> [WallEvent] {
        let before = Dictionary(old.workers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [WallEvent] = []
        for worker in tile.workers {
            guard let was = before[worker.id] else {
                events.append(WallEvent(kind: .workerStarted, tile: tile.id, worker: worker.id))
                continue
            }
            if let kind = change(from: was.state, to: worker.state) {
                events.append(WallEvent(kind: kind, tile: tile.id, worker: worker.id))
            }
        }
        return events
    }

    private static func change(from old: WorkerState, to state: WorkerState) -> WallEvent.Kind? {
        switch state {
        case .finished: return old.isFinished ? nil : .workerEnded
        case .quiet:
            if case .quiet = old { return nil }
            return .workerQuiet
        case .background(stuck: true):
            return old == .background(stuck: true) ? nil : .workerStuck
        case .working, .background(stuck: false): return nil
        }
    }
}

extension WallOutcome {
    fileprivate var group: Int {
        switch self {
        case .done, .unknown: return 0
        case .failed: return 1
        case .stopped: return 2
        }
    }
}

extension WallState {
    fileprivate var isActiveWork: Bool {
        switch self {
        case .working, .thinking, .retrying, .background: return true
        case .needsYou, .quiet, .finished, .away: return false
        }
    }

    fileprivate var isWorkingOrThinking: Bool {
        switch self {
        case .working, .thinking: return true
        case .needsYou, .retrying, .quiet, .background, .finished, .away: return false
        }
    }

    fileprivate var waitsOnProvider: Bool {
        switch self {
        case .quiet, .retrying: return true
        case .working, .thinking, .needsYou, .background, .finished, .away: return false
        }
    }

    fileprivate var isQuiet: Bool {
        if case .quiet = self { return true }
        return false
    }

    fileprivate var isAway: Bool {
        if case .away = self { return true }
        return false
    }
}
