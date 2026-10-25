import CodingAgentKit
import Foundation

/// The readings behind `AgentWall`: which tile each agent becomes, in what order, and what the
/// rails say.
enum WallReading {
    static let quietAfter: TimeInterval = 45
    static let doneLasts: TimeInterval = 60
    static let failedLasts: TimeInterval = 900

    static func drafts(board: AgentBoard, now: Date, previous: AgentWall?) -> [WallTile] {
        var drafts: [WallTile] = []
        for card in board.needsYou { drafts.append(tile(card, now: now, previous: previous)) }
        for row in board.working where row.isWatched || row.isAway {
            drafts.append(tile(row, background: false, now: now, previous: previous))
        }
        for row in board.background where row.isWatched || row.isAway {
            drafts.append(tile(row, background: true, now: now, previous: previous))
        }
        let live = Set(drafts.map(\.id))
        for finish in board.finished where !live.contains(finish.id) {
            if let made = tile(finish, now: now) { drafts.append(made) }
        }
        return drafts
    }

    private static func tile(_ card: AgentAskCard, now: Date, previous: AgentWall?) -> WallTile {
        let since = card.ask.since ?? now
        let state: WallState =
            card.isAway
            ? .away(lastSeen: lastSeen(card.id, fallback: card.lastActivity ?? now, previous: previous))
            : .needsYou(.level(waited: now.timeIntervalSince(since)))
        let words: String
        let detail: String?
        switch card.ask.kind {
        case .approval:
            words = card.ask.lead
            detail = card.ask.object
        case .question:
            words = Localized.text("Has a question")
            detail = card.ask.lead
        }
        return WallTile(
            id: card.id, profileID: card.profileID, sessionID: card.sessionID, title: card.title,
            machine: card.machine, chip: card.chip, state: state,
            words: card.isAway ? notAnswering(card.machine) : words,
            detail: card.isAway ? nil : detail, startedAt: card.startedAt,
            stateSince: card.isAway ? state.awaySince : since, ask: card.ask, beat: card.beat,
            contextShare: card.contextShare, children: card.children, steps: card.steps, fade: 0,
            unread: card.unread)
    }

    private static func tile(
        _ row: AgentRow, background: Bool, now: Date, previous: AgentWall?
    ) -> WallTile {
        let state = state(of: row, background: background, now: now, previous: previous)
        let words: String
        switch state {
        case .away: words = notAnswering(row.machine)
        case .thinking: words = Localized.text("Thinking")
        case .retrying: words = Localized.text("Waiting on the provider")
        default: words = row.line ?? Localized.text("Working")
        }
        let since: Date?
        switch state {
        case .quiet(let when): since = when
        case .away(let seen): since = seen
        default: since = row.startedAt
        }
        let showsObject: Bool
        switch state {
        case .working, .thinking, .quiet: showsObject = true
        default: showsObject = false
        }
        return WallTile(
            id: row.id, profileID: row.profileID, sessionID: row.sessionID, title: row.title,
            machine: row.machine, chip: row.chip, state: state, words: words,
            detail: showsObject ? row.object?.text : nil, startedAt: row.startedAt,
            stateSince: since, ask: nil, beat: row.beat, contextShare: row.contextShare,
            children: row.children, steps: row.steps, fade: 0, unread: row.unread)
    }

    private static func state(
        of row: AgentRow, background: Bool, now: Date, previous: AgentWall?
    ) -> WallState {
        if row.isAway {
            return .away(lastSeen: lastSeen(row.id, fallback: row.lastActivity ?? now, previous: previous))
        }
        if background { return .background(stuck: row.isStuck) }
        if let attempt = row.retryAttempt { return .retrying(attempt: attempt) }
        if isFlat(row.beat) {
            if case .quiet(let since)? = previous?.tiles.first(where: { $0.id == row.id })?.state {
                return .quiet(since: since)
            }
            return .quiet(since: now.addingTimeInterval(-quietAfter))
        }
        return row.activity == .thinking ? .thinking : .working
    }

    static func isFlat(_ beat: [Int]?) -> Bool {
        guard let beat else { return false }
        let width = AgentBeat.span / Double(AgentBeat.buckets)
        return beat.suffix(Int((quietAfter / width).rounded())).allSatisfy { $0 == 0 }
    }

    private static func lastSeen(_ id: String, fallback: Date, previous: AgentWall?) -> Date {
        guard let was = previous?.tiles.first(where: { $0.id == id }) else { return fallback }
        if case .away(let seen) = was.state { return seen }
        return previous?.at ?? fallback
    }

    private static func notAnswering(_ machine: String) -> String {
        Localized.text("%@ not answering", machine)
    }

    private static func tile(_ finish: AgentFinish, now: Date) -> WallTile? {
        let age = now.timeIntervalSince(finish.endedAt)
        let outcome = WallOutcome(finish.outcome)
        let lasts: TimeInterval
        switch outcome {
        case .done, .stopped: lasts = doneLasts
        case .failed: lasts = failedLasts
        case .unknown: return nil
        }
        guard age < lasts else { return nil }
        let reason = outcome == .failed ? (finish.reason ?? finish.line) : nil
        return WallTile(
            id: finish.id, profileID: finish.profileID, sessionID: finish.sessionID,
            title: finish.title, machine: finish.machine, chip: nil, state: .finished(outcome),
            words: reason ?? finish.line, detail: reason, startedAt: nil, stateSince: finish.endedAt,
            ask: nil, beat: nil, contextShare: nil, children: [], steps: [],
            fade: outcome == .failed ? 0 : min(1, max(0, age / doneLasts)), unread: finish.unread)
    }

    /// Needs-you tiles first, each rank after, but a tile that has not changed rank keeps the slot
    /// it had: a newcomer joins the end of its rank, so the wall does not reshuffle on an event.
    static func order(_ drafts: [WallTile], previous: AgentWall?) -> [WallTile] {
        var slot: [String: Int] = [:]
        var rank: [String: Int] = [:]
        for (index, tile) in (previous?.tiles ?? []).enumerated() {
            slot[tile.id] = index
            rank[tile.id] = tile.state.rank
        }
        let isKept = { (tile: WallTile) in slot[tile.id] != nil && rank[tile.id] == tile.state.rank }
        var ordered = drafts.filter(isKept).sorted { (slot[$0.id] ?? 0) < (slot[$1.id] ?? 0) }
        for tile in drafts.filter({ !isKept($0) }).sorted(by: leads) {
            let at = ordered.lastIndex { $0.state.rank <= tile.state.rank }.map { $0 + 1 } ?? 0
            ordered.insert(tile, at: at)
        }
        return ordered
    }

    private static func leads(_ lhs: WallTile, _ rhs: WallTile) -> Bool {
        if lhs.state.rank != rhs.state.rank { return lhs.state.rank < rhs.state.rank }
        switch (lhs.state, rhs.state) {
        case (.needsYou, .needsYou):
            let (left, right) = (lhs.stateSince ?? .distantFuture, rhs.stateSince ?? .distantFuture)
            if left != right { return left < right }
        case (.finished, .finished):
            let (left, right) = (lhs.stateSince ?? .distantPast, rhs.stateSince ?? .distantPast)
            if left != right { return left > right }
        default:
            let (left, right) = (lhs.startedAt ?? .distantPast, rhs.startedAt ?? .distantPast)
            if left != right { return left > right }
        }
        return lhs.id < rhs.id
    }

    static func listed(board: AgentBoard, overflow: [WallTile]) -> [WallChip] {
        var chips = overflow.map {
            WallChip(
                id: $0.id, title: $0.title, machine: $0.machine, outcome: nil, at: $0.startedAt,
                words: $0.words, unread: $0.unread)
        }
        for row in board.working + board.background where !row.isWatched && !row.isAway {
            chips.append(
                WallChip(
                    id: row.id, title: row.title, machine: row.machine, outcome: nil,
                    at: row.startedAt, words: row.line ?? Localized.text("Working"),
                    unread: row.unread))
        }
        return chips
    }

    static func recent(board: AgentBoard, shown: [WallTile]) -> [WallChip] {
        let showing = Set(shown.filter { if case .finished = $0.state { return true } else { return false } }.map(\.id))
        return board.finished.filter { !showing.contains($0.id) }
            .sorted { $0.endedAt > $1.endedAt }.prefix(AgentWall.maxRecent).map {
                WallChip(
                    id: $0.id, title: $0.title, machine: $0.machine, outcome: WallOutcome($0.outcome),
                    at: $0.endedAt, words: $0.line, unread: $0.unread)
            }
    }

    static func mood(drafts: [WallTile], listed: [WallChip]) -> WallMood {
        var attention = false
        var busy = !listed.isEmpty
        for tile in drafts {
            switch tile.state {
            case .needsYou(.overdue): return .alarm
            case .finished(.failed): return .alarm
            case .needsYou: attention = true
            case .working, .thinking, .retrying, .quiet, .background: busy = true
            case .finished, .away: break
            }
        }
        return attention ? .attention : (busy ? .busy : .calm)
    }

    static func headline(board: AgentBoard, drafts: [WallTile], mood: WallMood) -> String {
        guard board.isEmpty else { return board.sentence }
        let failed = drafts.filter { $0.state == .finished(.failed) }.count
        return failed > 0 ? Localized.text("%d failed", failed) : Localized.text("All quiet")
    }

    static func calm(board: AgentBoard, hour: AgentHour?, now: Date) -> WallCalm {
        var counts: [WallOutcome: Int] = [:]
        var marked: [(id: String, at: Date)] = []
        for lane in hour?.lanes ?? [] where lane.parentID == nil {
            for mark in lane.marks where now.timeIntervalSince(mark.at) < AgentHour.span {
                counts[WallOutcome(mark.outcome), default: 0] += 1
                marked.append((lane.id, mark.at))
            }
        }
        for finish in board.finished where now.timeIntervalSince(finish.endedAt) < AgentHour.span {
            let seen = marked.contains { $0.id == finish.id && abs($0.at.timeIntervalSince(finish.endedAt)) < 2 }
            if !seen { counts[WallOutcome(finish.outcome), default: 0] += 1 }
        }
        let done = counts[.done] ?? 0
        let failed = counts[.failed] ?? 0
        let stopped = counts[.stopped] ?? 0
        var parts: [String] = []
        if done > 0 { parts.append(Localized.text("%d done", done)) }
        if failed > 0 { parts.append(Localized.text("%d failed", failed)) }
        if stopped > 0 { parts.append(Localized.text("%d stopped", stopped)) }
        let line =
            parts.isEmpty
            ? Localized.text("Nothing ended in the last hour")
            : Localized.text("%@ in the last hour", parts.joined(separator: " · "))
        return WallCalm(done: done, failed: failed, stopped: stopped, line: line)
    }
}

extension WallState {
    fileprivate var awaySince: Date? {
        if case .away(let seen) = self { return seen }
        return nil
    }
}
