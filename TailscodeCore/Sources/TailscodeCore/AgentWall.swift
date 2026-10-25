import CodingAgentKit
import Foundation

/// How the whole wall feels, which drives the ambience and never anything that flashes.
public enum WallMood: Sendable, Equatable {
    /// Nothing is running.
    case calm
    /// Something is working, thinking, retrying, quiet or in the background.
    case busy
    /// Something needs a person.
    case attention
    /// Something has needed a person for more than five minutes, or a turn failed not long ago.
    case alarm
}

/// How long an ask has waited, measured from when this device first saw it.
public enum WallUrgency: Sendable, Equatable {
    case fresh
    case waiting
    case overdue

    public static let waitingAfter: TimeInterval = 60
    public static let overdueAfter: TimeInterval = 300

    public static func level(waited: TimeInterval) -> WallUrgency {
        if waited >= overdueAfter { return .overdue }
        if waited >= waitingAfter { return .waiting }
        return .fresh
    }
}

public enum WallOutcome: Sendable, Hashable {
    case done
    case failed
    case stopped
    /// Ended while nobody here was watching, so how is not known.
    case unknown

    init(_ outcome: AgentFinish.Outcome) {
        switch outcome {
        case .done: self = .done
        case .failed: self = .failed
        case .stopped: self = .stopped
        case .unknown: self = .unknown
        }
    }
}

/// The one state a tile wears. The associated values are facts about that state, never part of
/// its identity: `rank` ignores them, so a tile whose wait deepens does not move.
public enum WallState: Sendable, Equatable {
    case working
    case thinking
    case needsYou(WallUrgency)
    case retrying(attempt: Int)
    /// Running, and nothing has arrived for 45 s; `since` is when that was first seen.
    case quiet(since: Date)
    case background(stuck: Bool)
    case finished(WallOutcome)
    case away(lastSeen: Date)

    /// Where the state sits in the wall's order: needs-you, failed, retrying, quiet, away,
    /// working, thinking, background, finished.
    public var rank: Int {
        switch self {
        case .needsYou: return 0
        case .finished(.failed): return 1
        case .retrying: return 2
        case .quiet: return 3
        case .away: return 4
        case .working: return 5
        case .thinking: return 6
        case .background: return 7
        case .finished: return 8
        }
    }

    public var isNeedsYou: Bool {
        if case .needsYou = self { return true }
        return false
    }

    var isRunning: Bool {
        switch self {
        case .working, .thinking, .retrying, .quiet, .background: return true
        case .needsYou, .finished, .away: return false
        }
    }
}

/// One agent on the wall, with everything its tile draws.
public struct WallTile: Sendable, Equatable, Identifiable {
    /// The session's key: the profile and the session id.
    public let id: String
    public let profileID: String
    public let sessionID: String
    public let title: String
    public let machine: String
    public let chip: ModelChip?
    public let state: WallState
    /// The primary line: what it is doing, what it waits to do, or why it failed.
    public let words: String
    /// The whole command, the file's path, the question or the failure reason; nil otherwise.
    public let detail: String?
    public let startedAt: Date?
    /// When the tile entered its state, for the counter that ticks beside the word.
    public let stateSince: Date?
    public let ask: AgentAsk?
    public let beat: [Int]?
    /// How full the model's window is, `0...1`; nil when it is not known.
    public let contextShare: Double?
    public let children: [AgentChild]
    /// The last three steps, newest first.
    public let steps: [AgentStep]
    /// Columns the tile covers, 1 or 2.
    public internal(set) var span = 1
    public internal(set) var column = 0
    public internal(set) var row = 0
    /// How far a finished tile has cooled, `0` lit to `1` gone; always 0 for anything else.
    public let fade: Double
    public let unread: Bool

    /// The one plain word that says the state beside its glyph, counting from `now`.
    public func statusWord(at now: Date) -> String {
        switch state {
        case .working:
            return Localized.text("Working")
        case .thinking:
            return Localized.text("Thinking")
        case .needsYou:
            return Localized.text("waiting %@", AgentFinish.clock(max(0, now.timeIntervalSince(stateSince ?? now))))
        case .retrying(let attempt):
            return Localized.text("Waiting on the provider · try %d", attempt)
        case .quiet(let since):
            return Localized.text("quiet for %@", AgentFinish.clock(max(0, now.timeIntervalSince(since))))
        case .background(let stuck):
            if stuck { return Localized.text("stuck") }
            guard let startedAt else { return Localized.text("in the background") }
            return Localized.text(
                "in the background · %@", AgentFinish.clock(max(0, now.timeIntervalSince(startedAt))))
        case .finished(let outcome):
            switch outcome {
            case .done: return Localized.text("Done")
            case .failed: return Localized.text("Failed")
            case .stopped: return Localized.text("Stopped")
            case .unknown: return Localized.text("Finished")
            }
        case .away(let lastSeen):
            return Localized.text(
                "last seen %@ ago", AgentFinish.clock(max(0, now.timeIntervalSince(lastSeen))))
        }
    }
}

/// A session or an ending too small for a tile: running past the cap, or one of the last endings.
public struct WallChip: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let machine: String
    /// How it ended; nil for a session that is still running.
    public let outcome: WallOutcome?
    /// When it ended, or when it started if that is known.
    public let at: Date?
    public let words: String
    public let unread: Bool
}

/// What the last hour held, for the screen where nothing runs.
public struct WallCalm: Sendable, Equatable {
    public let done: Int
    public let failed: Int
    public let stopped: Int
    /// "6 done · 1 failed · 2 stopped in the last hour"; the client adds who saw it.
    public let line: String
}

/// The board read for a monitor that is left on: a handful of tiles that never scroll, a grid
/// chosen from the count and the screen's shape, the rails, and the mood. A pure reading of what
/// the tower saw, from `now` alone, so the same input gives the same wall.
public struct AgentWall: Sendable, Equatable {
    public let mood: WallMood
    public let headline: String
    public let watchLine: String
    public let tiles: [WallTile]
    public let columns: Int
    public let rows: Int
    /// Running sessions without a tile, at most six.
    public let listed: [WallChip]
    /// How many listed sessions did not fit in `listed`.
    public let listedOverflow: Int
    /// The last five endings that no tile is showing.
    public let recent: [WallChip]
    /// The last hour's summary, only while nothing runs.
    public let calm: WallCalm?
    public let watched: Int
    public let running: Int
    /// When this wall was read; the next read measures what it kept from here.
    public let at: Date

    public static let maxTiles = AgentWatch.cap
    public static let maxListed = 6
    public static let maxRecent = 5

    public static let empty = AgentWall.read(
        board: .empty, hour: nil, now: Date(timeIntervalSince1970: 0), aspect: 1.6, previous: nil)

    public var isCalm: Bool { mood == .calm }

    public static func read(
        board: AgentBoard, hour: AgentHour?, now: Date, aspect: Double, previous: AgentWall?
    ) -> AgentWall {
        let drafts = WallReading.drafts(board: board, now: now, previous: previous)
        let ordered = WallReading.order(drafts, previous: previous)
        let shown = Array(ordered.prefix(maxTiles))
        let overflow = ordered.dropFirst(maxTiles).filter { $0.state.isRunning }
        let chips = WallReading.listed(board: board, overflow: Array(overflow))
        let placed = WallGrid.place(shown, aspect: aspect)
        let mood = WallReading.mood(drafts: drafts, listed: chips)
        return AgentWall(
            mood: mood,
            headline: WallReading.headline(board: board, drafts: drafts, mood: mood),
            watchLine: board.watchLine, tiles: placed.tiles, columns: placed.columns,
            rows: placed.rows, listed: Array(chips.prefix(maxListed)),
            listedOverflow: max(0, chips.count - maxListed),
            recent: WallReading.recent(board: board, shown: placed.tiles),
            calm: board.isEmpty ? WallReading.calm(board: board, hour: hour, now: now) : nil,
            watched: board.watched, running: board.running, at: now)
    }
}
