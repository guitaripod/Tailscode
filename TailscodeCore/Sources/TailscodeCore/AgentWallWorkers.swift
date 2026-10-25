import Foundation

/// What a sub-agent or a piece of background work under a watched session is doing, as far as the
/// listing can say. A worker has no heartbeat of its own: `quiet` is read from when the listing last
/// saw it move.
public enum WorkerState: Sendable, Equatable {
    case working
    /// Running, and the listing has seen no movement since `since`.
    case quiet(since: Date)
    case background(stuck: Bool)
    /// Left the roster while its session still runs; the tile cools and goes.
    case finished

    /// Which state this is and nothing about it: working, quiet, background, stuck, finished.
    public var ordinal: Int {
        switch self {
        case .working: return 0
        case .quiet: return 1
        case .background(false): return 2
        case .background(true): return 3
        case .finished: return 4
        }
    }

    public var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }

    /// A state that wants a look: stuck work or an agent that has stopped moving.
    public var needsEyes: Bool {
        switch self {
        case .quiet, .background(stuck: true): return true
        case .working, .background(stuck: false), .finished: return false
        }
    }
}

/// One worker with everything its small tile draws.
public struct WallWorker: Sendable, Equatable, Identifiable {
    /// The session's key and the worker's own id.
    public let id: String
    public let kind: AgentChild.Kind
    public let title: String
    /// What it is doing; empty when the state word says all there is, as for background work.
    public let words: String
    public let state: WorkerState
    public let startedAt: Date?
    /// When the worker entered its state, for the counter beside the word.
    public let stateSince: Date?
    public let todosDone: Int
    public let todosTotal: Int
    public let toolCount: Int?
    /// How far a finished worker has cooled, `0` lit to `1` gone; always 0 for anything else.
    public let fade: Double

    /// How far through its todo list, `0...1`; nil when it keeps none.
    public var progress: Double? {
        todosTotal > 0 ? min(1, Double(todosDone) / Double(todosTotal)) : nil
    }

    public func statusWord(at now: Date) -> String {
        switch state {
        case .working:
            return Localized.text("Working")
        case .quiet(let since):
            return Localized.text("quiet for %@", AgentFinish.clock(max(0, now.timeIntervalSince(since))))
        case .background(let stuck):
            return stuck ? Localized.text("stuck") : Localized.text("in the background")
        case .finished:
            return Localized.text("Finished")
        }
    }

    /// "one sub-agent" or "3 sub-agents"; nil for none.
    public static func count(_ agents: Int) -> String? {
        switch agents {
        case ...0: return nil
        case 1: return Localized.text("one sub-agent")
        default: return Localized.text("%d sub-agents", agents)
        }
    }

    func finished(since: Date, now: Date) -> WallWorker {
        WallWorker(
            id: id, kind: kind, title: title, words: words, state: .finished, startedAt: startedAt,
            stateSince: since, todosDone: todosDone, todosTotal: todosTotal, toolCount: toolCount,
            fade: min(1, max(0, now.timeIntervalSince(since) / WallReading.workerDoneLasts)))
    }
}

/// A rectangle in a cell's own units, `0...1` across and down, so a client scales it to pixels.
public struct WallFrame: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// How one session's cell is shared between the session and its workers: the session's own tile,
/// a small tile for each worker that fits, and one more for the count of those that do not.
public struct WallSquad: Sendable, Equatable {
    /// Where the session's own tile goes.
    public let parent: WallFrame
    /// The frame of each worker shown; `slots[i]` belongs to `workers[i]`.
    public let slots: [WallFrame]
    /// Workers past the slots.
    public let hidden: Int
    /// The "+N" tile, present exactly when `hidden > 0`.
    public let more: WallFrame?
    /// The first worker that did not fit is stuck or quiet, so the "+N" tile says so.
    public let moreNeedsEyes: Bool

    static let gap = 0.022
    static let wideFrom = 1.3
    static let slotAspect = 1.5

    /// How many small tiles a cell affords, counting the "+N" tile: the fewer sessions share the
    /// wall, the more room each cell has.
    static func capacity(sessions: Int) -> Int {
        switch sessions {
        case ...1: return 6
        case 2: return 5
        case 3: return 4
        default: return 3
        }
    }

    static func plan(workers: [WallWorker], sessions: Int, cellAspect: Double) -> WallSquad? {
        guard !workers.isEmpty, cellAspect > 0 else { return nil }
        let capacity = capacity(sessions: sessions)
        let spilled = workers.count > capacity
        let shown = spilled ? capacity - 1 : workers.count
        let cells = shown + (spilled ? 1 : 0)
        let wide = cellAspect >= wideFrom
        let share = cells <= 2 ? 0.58 : 0.5
        let width = cellAspect
        let parent: (x: Double, y: Double, w: Double, h: Double)
        let area: (x: Double, y: Double, w: Double, h: Double)
        if wide {
            parent = (0, 0, share * width - gap / 2, 1)
            area = (share * width + gap / 2, 0, width - share * width - gap / 2, 1)
        } else {
            parent = (0, 0, width, share - gap / 2)
            area = (0, share + gap / 2, width, 1 - share - gap / 2)
        }
        let frames = grid(cells: cells, in: area).map { frame($0, width: width) }
        let hidden = spilled ? workers.count - shown : 0
        return WallSquad(
            parent: frame(parent, width: width), slots: Array(frames.prefix(shown)), hidden: hidden,
            more: spilled ? frames.last : nil,
            moreNeedsEyes: spilled && workers.dropFirst(shown).contains { $0.state.needsEyes })
    }

    private static func frame(
        _ rect: (x: Double, y: Double, w: Double, h: Double), width: Double
    ) -> WallFrame {
        WallFrame(x: rect.x / width, y: rect.y, width: rect.w / width, height: rect.h)
    }

    /// Row-major cells whose columns make each one closest to `slotAspect`, all of one width: a
    /// short last row stays as wide as the rows above it, so no worker looks like the favourite.
    private static func grid(
        cells: Int, in area: (x: Double, y: Double, w: Double, h: Double)
    ) -> [(x: Double, y: Double, w: Double, h: Double)] {
        var best = (columns: 1, miss: Double.infinity)
        for columns in 1...cells {
            let rows = (cells + columns - 1) / columns
            let aspect = ((area.w - gap * Double(columns - 1)) / Double(columns))
                / ((area.h - gap * Double(rows - 1)) / Double(rows))
            let miss = abs(log(max(aspect, 0.01) / slotAspect))
            if miss < best.miss - 0.0001 { best = (columns, miss) }
        }
        let columns = best.columns
        let rows = (cells + columns - 1) / columns
        let height = (area.h - gap * Double(rows - 1)) / Double(rows)
        var out: [(x: Double, y: Double, w: Double, h: Double)] = []
        for row in 0..<rows {
            let inRow = min(columns, cells - row * columns)
            let wide = (area.w - gap * Double(columns - 1)) / Double(columns)
            for column in 0..<inRow {
                out.append(
                    (
                        area.x + Double(column) * (wide + gap), area.y + Double(row) * (height + gap),
                        wide, height
                    ))
            }
        }
        return out
    }
}

extension WallReading {
    static let workerQuietAfter: TimeInterval = 90
    static let workerDoneLasts: TimeInterval = 30

    /// The workers under one session: what the roster names now, then what left it since the last
    /// read, cooling for half a minute. A session that is only carrying background work has no worker
    /// for it, because that work is the tile itself. Quiet is only read while the session itself is running, for
    /// an agent behind an ask or on a machine that stopped answering is silent for a known reason.
    static func workers(
        under parent: String, children: [AgentChild], state: WallState, now: Date,
        previous: AgentWall?
    ) -> [WallWorker] {
        let readsQuiet: Bool
        switch state {
        case .working, .thinking, .quiet, .background: readsQuiet = true
        case .needsYou, .retrying, .finished, .away: readsQuiet = false
        }
        var own = false
        if case .background = state { own = true }
        let kids = own ? children.filter { $0.kind != .background } : children
        var made = kids.map { worker($0, under: parent, readsQuiet: readsQuiet, now: now) }
        let named = Set(made.map(\.id))
        let before = previous?.tiles.first { $0.id == parent }?.workers ?? []
        for gone in before where !named.contains(gone.id) {
            let since = gone.state.isFinished ? (gone.stateSince ?? now) : now
            if now.timeIntervalSince(since) < workerDoneLasts {
                made.append(gone.finished(since: since, now: now))
            }
        }
        return stable(made, before: before)
    }

    /// Workers stay where they first were, whatever they do: a newcomer joins the end, the
    /// longest-running first among several that arrive together.
    private static func stable(_ workers: [WallWorker], before: [WallWorker]) -> [WallWorker] {
        var slot: [String: Int] = [:]
        for (index, worker) in before.enumerated() { slot[worker.id] = index }
        let kept = workers.filter { slot[$0.id] != nil }.sorted { (slot[$0.id] ?? 0) < (slot[$1.id] ?? 0) }
        return kept + workers.filter { slot[$0.id] == nil }.sorted(by: arrives)
    }

    private static func worker(
        _ child: AgentChild, under parent: String, readsQuiet: Bool, now: Date
    ) -> WallWorker {
        let state: WorkerState
        let words: String
        switch child.kind {
        case .background:
            state = .background(stuck: !child.isActive)
            words = ""
        case .agent:
            if readsQuiet, let moved = child.updatedAt,
                now.timeIntervalSince(moved) >= workerQuietAfter
            {
                state = .quiet(since: moved)
            } else {
                state = .working
            }
            words = child.doing ?? Localized.text("Working")
        }
        let since: Date?
        if case .quiet(let moved) = state { since = moved } else { since = child.startedAt }
        return WallWorker(
            id: parent + "#" + child.id, kind: child.kind,
            title: child.kind == .background ? (child.doing ?? child.title) : child.title, words: words,
            state: state, startedAt: child.startedAt, stateSince: since,
            todosDone: child.todos?.done ?? 0, todosTotal: child.todos?.total ?? 0,
            toolCount: child.toolCount, fade: 0)
    }

    private static func arrives(_ lhs: WallWorker, _ rhs: WallWorker) -> Bool {
        let (left, right) = (lhs.startedAt ?? .distantFuture, rhs.startedAt ?? .distantFuture)
        if left != right { return left < right }
        return lhs.id < rhs.id
    }
}
