import MidgarCore
import QuartzCore
import TailscodeCore
import UIKit

/// The shape the wall is read for: what the screen's layout asks of the grid.
struct WatchShape: Equatable {
    var aspect: Double
    var gridAspect: Double
    var pages: Bool
}

/// One reading of the wall and what changed since the one before.
struct WatchRead {
    let wall: AgentWall
    let previous: AgentWall?
    let events: [WallEvent]
}

extension AgentWall {
    /// Whether the two walls show the same thing: everything but when they were read.
    func sameShown(as other: AgentWall) -> Bool {
        mood == other.mood && headline == other.headline && watchLine == other.watchLine
            && tiles == other.tiles && columns == other.columns && rows == other.rows
            && listed == other.listed && listedOverflow == other.listedOverflow
            && recent == other.recent && calm == other.calm && watched == other.watched
            && running == other.running && subagents == other.subagents
    }
}

/// Where the wall gets its reading while it is on screen: the tower, held open exactly as long as a
/// wall is shown in a foreground scene, a board whenever one arrives, the hour every half minute and
/// one read a second so the clocks and the cooling of what ended keep moving. It reads the wall,
/// turns what changed into effects, and hands both to whoever draws; nothing here runs per frame.
@MainActor
final class WatchFeed {
    enum Origin {
        case live
        case demo(AgentWall, AgentHour?)
    }

    static let hourEvery: TimeInterval = 30

    var onBoard: (() -> Void)?
    var onTick: (() -> Void)?
    var onHour: (() -> Void)?

    private(set) var board = AgentBoard.empty
    private(set) var hour: AgentHour?
    private(set) var wall = AgentWall.empty
    private(set) var effects = WallEffectQueue()
    private(set) var beatShiftedAt: TimeInterval = -10
    private(set) var isRunning = false

    private let origin: Origin
    private var previous: AgentWall?
    private var consumer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var hourTask: Task<Void, Never>?
    private var hourAt = Date.distantPast
    private var isAcquired = false

    init(origin: Origin) {
        self.origin = origin
        if case .demo(_, let hour) = origin { self.hour = hour }
    }

    deinit {
        consumer?.cancel()
        ticker?.cancel()
        hourTask?.cancel()
        if isAcquired { Task { @MainActor in AgentsHub.shared.release() } }
    }

    private var isLive: Bool {
        if case .live = origin { return true }
        return false
    }

    func resume() {
        guard !isRunning else { return }
        isRunning = true
        if isLive {
            isAcquired = true
            let hub = AgentsHub.shared
            hub.acquire()
            MidgarLog.info("agents wall shown", category: .ui)
            consumer = Task { [weak self] in
                let stream = await hub.boards()
                for await board in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.board = board
                    self.onBoard?()
                }
            }
            refreshHour(now: Date())
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    func suspend() {
        consumer?.cancel()
        consumer = nil
        ticker?.cancel()
        ticker = nil
        hourTask?.cancel()
        hourTask = nil
        guard isRunning else { return }
        isRunning = false
        guard isAcquired else { return }
        isAcquired = false
        AgentsHub.shared.release()
        MidgarLog.info("agents wall hidden", category: .ui)
    }

    private func tick() {
        let now = Date()
        if isLive, now.timeIntervalSince(hourAt) >= Self.hourEvery { refreshHour(now: now) }
        onTick?()
    }

    private func refreshHour(now: Date) {
        guard hourTask == nil else { return }
        hourAt = now
        hourTask = Task { [weak self] in
            let next = await AgentsHub.shared.hour()
            guard let self else { return }
            self.hourTask = nil
            guard !Task.isCancelled else { return }
            self.hour = next
            self.onHour?()
        }
    }

    /// Reads the wall for `shape` from what the tower last said, finds what changed, and queues the
    /// gestures those changes play. The wall it keeps is the one the next read is compared with.
    func read(shape: WatchShape, style: WallStyle, now: Date) -> WatchRead {
        let next: AgentWall
        switch origin {
        case .live:
            next = AgentWall.read(
                board: board, hour: hour, now: now, aspect: shape.aspect, gridAspect: shape.gridAspect,
                pages: shape.pages, previous: previous)
        case .demo(let source, _):
            next = source.reflowed(aspect: shape.aspect, gridAspect: shape.gridAspect, pages: shape.pages)
        }
        let events = WallEvents.between(previous, next)
        let t = CACurrentMediaTime()
        queue(events, previous: previous, next: next, style: style, at: t)
        noteBeats(previous: previous, next: next, at: t)
        let done = WatchRead(wall: next, previous: previous, events: events)
        previous = next
        wall = next
        return done
    }

    /// A gesture that no reading asked for: the demo's script plays its effects through here.
    func inject(_ events: [WallEvent], style: WallStyle) {
        queue(events, previous: wall, next: wall, style: style, at: CACurrentMediaTime())
    }

    func prune() {
        effects.prune(at: CACurrentMediaTime())
    }

    private func queue(
        _ events: [WallEvent], previous: AgentWall?, next: AgentWall, style: WallStyle, at t: TimeInterval
    ) {
        guard !events.isEmpty else { return }
        effects.add(events, at: t, style: style, contexts: contexts(events, previous: previous, next: next))
    }

    private func contexts(
        _ events: [WallEvent], previous: AgentWall?, next: AgentWall
    ) -> [String: (from: Double, to: Double)] {
        var shares: [String: (from: Double, to: Double)] = [:]
        for event in events where event.kind == .compacted {
            let was = previous?.tiles.first { $0.id == event.tile }?.contextShare
            let now = next.tiles.first { $0.id == event.tile }?.contextShare
            if let was, let now { shares[event.tile] = (was, now) }
        }
        return shares
    }

    private func noteBeats(previous: AgentWall?, next: AgentWall, at t: TimeInterval) {
        guard let previous else { return }
        let before = Dictionary(
            previous.tiles.compactMap { tile in tile.beat.map { (tile.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        for tile in next.tiles {
            guard let old = before[tile.id], let now = tile.beat, old.count == now.count, old.count > 1,
                old != now, Array(old.dropFirst()) == Array(now.dropLast())
            else { continue }
            beatShiftedAt = t
            return
        }
    }
}
