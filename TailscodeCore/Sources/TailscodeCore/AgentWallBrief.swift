import CodingAgentKit
import Foundation

/// What a wall tile can say beyond its line, for a tile that has the room: the counts of the work,
/// the agent's own plan, what it last said, its earlier steps and the files it changed. A tile shows
/// its line, its command and its latest steps first, whatever its size; the brief is what fills the
/// rest of a large tile instead of glass, chosen by `WallBriefFill` so every client fills a tile of
/// the same size with the same things.
public struct WallBrief: Sendable, Equatable {
    /// One dim line of counts: "38 tools · 4 files +120 −35".
    public var facts: String?
    public var plan: WallPlan?
    /// What the agent last said, in plain words, a few lines at most.
    public var said: String?
    /// The files the work changed, with the lines each gained and lost, newest last.
    public var files: [WallFile]

    public init(facts: String? = nil, plan: WallPlan? = nil, said: String? = nil, files: [WallFile] = []) {
        self.facts = facts
        self.plan = plan
        self.said = said
        self.files = files
    }

    public static let empty = WallBrief()

    public var isEmpty: Bool { facts == nil && plan == nil && said == nil && files.isEmpty }

    /// The files as one run of words a label can wrap: "Backoff.swift +12 −3 · Tests.swift +40".
    public var filesLine: String? {
        files.isEmpty ? nil : files.map(\.words).joined(separator: "  ·  ")
    }

    /// The brief of a watched session, from what its conversation says.
    public static func read(_ facts: AgentFacts) -> WallBrief {
        WallBrief(
            facts: line(tools: facts.toolCount, files: facts.edits),
            plan: facts.plan.flatMap(WallPlan.init(board:)), said: facts.said,
            files: facts.edits)
    }

    /// "38 tools · 4 files +120 −35", or nil when the work has nothing to count yet.
    static func line(tools: Int, files: [WallFile]) -> String? {
        var parts: [String] = []
        if tools > 0 { parts.append(Localized.text("%lld tools", tools)) }
        if !files.isEmpty {
            let added = files.reduce(0) { $0 + $1.added }
            let removed = files.reduce(0) { $0 + $1.removed }
            var changed =
                files.count == 1
                ? Localized.text("edited 1 file") : Localized.text("edited %lld files", files.count)
            if added + removed > 0 { changed += " " + WallFile.counts(added: added, removed: removed) }
            parts.append(changed)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The agent's own to-do list as a tile says it: how far through, the item it is on, and what is next.
public struct WallPlan: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let current: String?
    public let next: [String]

    public init(done: Int, total: Int, current: String?, next: [String]) {
        self.done = done
        self.total = total
        self.current = current
        self.next = next
    }

    /// Nil for a board with nothing on it, or one that is finished: a plan worth showing is one
    /// still being worked through.
    public init?(board: TaskBoard) {
        guard !board.isEmpty, board.doneCount < board.items.count else { return nil }
        done = board.doneCount
        total = board.items.count
        let current = board.current
        self.current = current.map { $0.activeForm ?? $0.subject }
        next = board.items.filter { $0.status == .pending && $0.id != current?.id }.map(\.subject)
    }

    /// "Plan · 4 of 7".
    public var headline: String {
        Localized.text("Plan") + " · " + Localized.text("%d of %d", done, total)
    }

    /// The lines under the headline, the one in hand first: "▸ Fixing the retry timer", "○ Run the suite".
    public var lines: [String] {
        (current.map { ["▸ " + $0] } ?? []) + next.map { "○ " + $0 }
    }

    /// How full the plan is, `0...1`, for a client that draws it as a bar.
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// One file the work changed.
public struct WallFile: Sendable, Equatable {
    public let name: String
    public let added: Int
    public let removed: Int

    public init(name: String, added: Int, removed: Int) {
        self.name = name
        self.added = added
        self.removed = removed
    }

    public var words: String {
        added + removed > 0 ? name + " " + Self.counts(added: added, removed: removed) : name
    }

    /// "+12 −3", with a real minus sign, and only the side that moved.
    static func counts(added: Int, removed: Int) -> String {
        [added > 0 ? "+\(added)" : nil, removed > 0 ? "\u{2212}\(removed)" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}

/// Which parts of a brief a tile has room for, the same on every client: each client measures what
/// a part would take at the type it chose for the tile, and this decides what goes in.
///
/// A tile first fits its line and its command and picks the largest type at which they fit. What
/// is left goes first to its latest step, which says what just happened, then in order of use to
/// the agent's plan, what it last said, the counts of the work, its earlier steps and the files —
/// each part taking as many whole lines as fit and none when not even its first does — and the
/// parts are laid out in reading order: counts, plan, words, steps, files. Nothing is ever cut
/// mid-line to make room.
public enum WallBriefFill {
    public enum Part: Int, Sendable, CaseIterable, Comparable {
        case facts
        case plan
        case said
        case steps
        case files

        public static func < (lhs: Part, rhs: Part) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The fewest lines a part is worth showing at all.
        public var floor: Int {
            switch self {
            case .said, .plan: return 2
            case .facts, .steps, .files: return 1
            }
        }
    }

    /// A part a client could show: what one of its lines takes and how many it has.
    public struct Offer: Sendable, Equatable {
        public let part: Part
        public let lineHeight: Double
        public let lines: Int

        public init(part: Part, lineHeight: Double, lines: Int) {
            self.part = part
            self.lineHeight = lineHeight
            self.lines = lines
        }
    }

    /// The steps a tile keeps ahead of everything else in its brief.
    public static let latestSteps = 1

    static let order: [Part] = [.plan, .said, .facts]

    /// How many lines each part gets in `room`, with `gap` between parts. Parts with nothing to
    /// show or no room are left out.
    public static func choose(_ offers: [Offer], room: Double, gap: Double) -> [Part: Int] {
        var left = room
        var granted: [Part: Int] = [:]
        func offer(_ part: Part) -> Offer? {
            offers.first { $0.part == part && $0.lines > 0 && $0.lineHeight > 0 }
        }
        func take(_ part: Part, cap: Int) {
            guard let offer = offer(part) else { return }
            let fits = Int(((left - gap) / offer.lineHeight).rounded(.down))
            let lines = min(fits, cap, offer.lines)
            guard lines >= min(part.floor, offer.lines), lines > 0 else { return }
            granted[part] = lines
            left -= gap + Double(lines) * offer.lineHeight
        }
        take(.steps, cap: latestSteps)
        for part in order { take(part, cap: .max) }
        if let steps = offer(.steps) {
            if let have = granted[.steps] {
                let more = min(Int((left / steps.lineHeight).rounded(.down)), steps.lines - have)
                if more > 0 {
                    granted[.steps] = have + more
                    left -= Double(more) * steps.lineHeight
                }
            } else {
                take(.steps, cap: .max)
            }
        }
        take(.files, cap: .max)
        return granted
    }
}
