import Foundation

/// One earned or earnable mark against the account's own ledger. The catalog is fixed and the
/// words are generated here once: a client decides only how tall a progress bar is, and Game
/// Center is handed the same identifiers and percentages this struct already carries — the
/// dashboard and the in-app card can never disagree about what has been earned.
public struct Trophy: Sendable, Equatable {
    public let id: String
    public let symbolName: String
    public let glyph: String
    public let title: String
    public let goal: String
    public let progressLine: String
    /// `0...100`, Game Center's own unit, so the number reported is the number drawn.
    public let percent: Double
    public let points: Int

    public var earned: Bool { percent >= 100 }
}

/// One score for one leaderboard, in the leaderboard's own integer unit.
public struct TrophyScore: Sendable, Equatable {
    public let leaderboardID: String
    public let value: Int
}

/// What the window's merged reports say about the account, reduced to the few numbers the
/// catalog judges. Assembled inside ``UsageAnalytics``'s merge — the trophies are read from
/// the same fold as every chart, never from a second accounting that could drift.
struct TrophyFacts {
    var turns = 0
    var tokens = 0
    var toolCalls = 0
    var sessions = 0
    var streakDays = 0
    var subagentRuns = 0
    var compactions = 0
    var cacheSavedUSD = 0.0
    var machines = 0
    var projects = 0
    var models = 0
    var nightTurns = 0
    var hoursCovered = 0
    var longestTurnSeconds = 0.0
    var peakDayCostUSD = 0.0
    var weekendTurns = 0
}

/// The trophy catalog and the arithmetic that scores it. Every identifier here is also a Game
/// Center vendor identifier configured in App Store Connect — the catalog is the contract
/// between the app and the store, so an entry added here is added there in the same change.
public enum TrophyRoom {
    public enum Board {
        public static let streak = "com.guitaripod.tailscode.board.streak"
        public static let turns = "com.guitaripod.tailscode.board.turns30"
        public static let tokens = "com.guitaripod.tailscode.board.tokens30"
        public static let tools = "com.guitaripod.tailscode.board.tools30"

        public static let all = [streak, turns, tokens, tools]
    }

    struct Spec {
        let slug: String
        let symbolName: String
        let glyph: String
        let title: String
        let goal: String
        let points: Int
        let target: Double
        let unit: Unit
        let value: (TrophyFacts) -> Double

        enum Unit {
            case count(String)
            case days
            case money
            case hours
            case minutes
        }
    }

    static func specs() -> [Spec] {
        [
            Spec(
                slug: "turns1", symbolName: "bubble.left.fill", glyph: "❞",
                title: Localized.text("First words"),
                goal: Localized.text("Send a first turn"),
                points: 5, target: 1, unit: .count(Localized.text("turns")),
                value: { Double($0.turns) }),
            Spec(
                slug: "turns100", symbolName: "bubble.left.and.bubble.right.fill", glyph: "❝",
                title: Localized.text("A hundred turns"),
                goal: Localized.text("Send 100 turns inside one month"),
                points: 10, target: 100, unit: .count(Localized.text("turns")),
                value: { Double($0.turns) }),
            Spec(
                slug: "turns1000", symbolName: "text.bubble.fill", glyph: "✉",
                title: Localized.text("A thousand turns"),
                goal: Localized.text("Send 1,000 turns inside one month"),
                points: 25, target: 1_000, unit: .count(Localized.text("turns")),
                value: { Double($0.turns) }),
            Spec(
                slug: "turns10000", symbolName: "envelope.open.fill", glyph: "✍",
                title: Localized.text("Ten thousand turns"),
                goal: Localized.text("Send 10,000 turns inside one month"),
                points: 50, target: 10_000, unit: .count(Localized.text("turns")),
                value: { Double($0.turns) }),
            Spec(
                slug: "streak3", symbolName: "calendar", glyph: "≡",
                title: Localized.text("Three days running"),
                goal: Localized.text("Work three days in a row"),
                points: 10, target: 3, unit: .days,
                value: { Double($0.streakDays) }),
            Spec(
                slug: "streak7", symbolName: "calendar.badge.checkmark", glyph: "✓",
                title: Localized.text("A full week"),
                goal: Localized.text("Work seven days in a row"),
                points: 25, target: 7, unit: .days,
                value: { Double($0.streakDays) }),
            Spec(
                slug: "streak14", symbolName: "calendar.circle.fill", glyph: "◎",
                title: Localized.text("A fortnight"),
                goal: Localized.text("Work fourteen days in a row"),
                points: 50, target: 14, unit: .days,
                value: { Double($0.streakDays) }),
            Spec(
                slug: "streak30", symbolName: "flame.fill", glyph: "▲",
                title: Localized.text("A month unbroken"),
                goal: Localized.text("Work thirty days in a row"),
                points: 100, target: 30, unit: .days,
                value: { Double($0.streakDays) }),
            Spec(
                slug: "tokens10m", symbolName: "textformat.abc", glyph: "τ",
                title: Localized.text("Ten million tokens"),
                goal: Localized.text("Move 10M tokens inside one month"),
                points: 10, target: 10_000_000, unit: .count(Localized.text("tokens")),
                value: { Double($0.tokens) }),
            Spec(
                slug: "tokens100m", symbolName: "doc.text.fill", glyph: "Τ",
                title: Localized.text("A hundred million tokens"),
                goal: Localized.text("Move 100M tokens inside one month"),
                points: 25, target: 100_000_000, unit: .count(Localized.text("tokens")),
                value: { Double($0.tokens) }),
            Spec(
                slug: "tokens1b", symbolName: "crown.fill", glyph: "♛",
                title: Localized.text("The billion club"),
                goal: Localized.text("Move 1B tokens inside one month"),
                points: 100, target: 1_000_000_000, unit: .count(Localized.text("tokens")),
                value: { Double($0.tokens) }),
            Spec(
                slug: "tools1000", symbolName: "wrench.and.screwdriver.fill", glyph: "⚒",
                title: Localized.text("A thousand tool calls"),
                goal: Localized.text("Let the agent run 1,000 tools inside one month"),
                points: 10, target: 1_000, unit: .count(Localized.text("calls")),
                value: { Double($0.toolCalls) }),
            Spec(
                slug: "tools10000", symbolName: "hammer.fill", glyph: "⚙",
                title: Localized.text("Ten thousand tool calls"),
                goal: Localized.text("Let the agent run 10,000 tools inside one month"),
                points: 25, target: 10_000, unit: .count(Localized.text("calls")),
                value: { Double($0.toolCalls) }),
            Spec(
                slug: "sessions50", symbolName: "square.stack.3d.up.fill", glyph: "▤",
                title: Localized.text("Fifty conversations"),
                goal: Localized.text("Hold 50 conversations inside one month"),
                points: 10, target: 50, unit: .count(Localized.text("chats")),
                value: { Double($0.sessions) }),
            Spec(
                slug: "subagent1", symbolName: "person.2.fill", glyph: "⑂",
                title: Localized.text("Delegator"),
                goal: Localized.text("Send a subagent out to work"),
                points: 10, target: 1, unit: .count(Localized.text("runs")),
                value: { Double($0.subagentRuns) }),
            Spec(
                slug: "subagent250", symbolName: "person.3.sequence.fill", glyph: "⑃",
                title: Localized.text("Fleet commander"),
                goal: Localized.text("Send 250 subagents out inside one month"),
                points: 50, target: 250, unit: .count(Localized.text("runs")),
                value: { Double($0.subagentRuns) }),
            Spec(
                slug: "compaction1", symbolName: "arrow.down.right.and.arrow.up.left", glyph: "⇲",
                title: Localized.text("The long haul"),
                goal: Localized.text("Work a conversation long enough to compact it"),
                points: 10, target: 1, unit: .count(Localized.text("compactions")),
                value: { Double($0.compactions) }),
            Spec(
                slug: "cache100", symbolName: "banknote.fill", glyph: "$",
                title: Localized.text("Cache money"),
                goal: Localized.text("Let caching save $100 inside one month"),
                points: 25, target: 100, unit: .money,
                value: { $0.cacheSavedUSD }),
            Spec(
                slug: "cache1000", symbolName: "building.columns.fill", glyph: "𝔹",
                title: Localized.text("A thousand saved"),
                goal: Localized.text("Let caching save $1,000 inside one month"),
                points: 50, target: 1_000, unit: .money,
                value: { $0.cacheSavedUSD }),
            Spec(
                slug: "machines2", symbolName: "server.rack", glyph: "▣",
                title: Localized.text("A second machine"),
                goal: Localized.text("Put two machines to work in the same month"),
                points: 25, target: 2, unit: .count(Localized.text("machines")),
                value: { Double($0.machines) }),
            Spec(
                slug: "projects5", symbolName: "folder.fill", glyph: "▸",
                title: Localized.text("Five projects"),
                goal: Localized.text("Work five projects inside one month"),
                points: 10, target: 5, unit: .count(Localized.text("projects")),
                value: { Double($0.projects) }),
            Spec(
                slug: "models3", symbolName: "cpu.fill", glyph: "◆",
                title: Localized.text("Three models"),
                goal: Localized.text("Put three models to work inside one month"),
                points: 10, target: 3, unit: .count(Localized.text("models")),
                value: { Double($0.models) }),
            Spec(
                slug: "night50", symbolName: "moon.stars.fill", glyph: "☾",
                title: Localized.text("Night shift"),
                goal: Localized.text("Start 50 turns between midnight and five"),
                points: 25, target: 50, unit: .count(Localized.text("turns")),
                value: { Double($0.nightTurns) }),
            Spec(
                slug: "clock24", symbolName: "clock.fill", glyph: "◷",
                title: Localized.text("Round the clock"),
                goal: Localized.text("Start a turn in every hour of the day"),
                points: 50, target: 24, unit: .hours,
                value: { Double($0.hoursCovered) }),
            Spec(
                slug: "longturn10", symbolName: "hourglass", glyph: "◔",
                title: Localized.text("The ten-minute turn"),
                goal: Localized.text("Keep the agent out on one turn for ten minutes"),
                points: 25, target: 600, unit: .minutes,
                value: { $0.longestTurnSeconds }),
            Spec(
                slug: "day100", symbolName: "sun.max.fill", glyph: "☀",
                title: Localized.text("The hundred-dollar day"),
                goal: Localized.text("Put $100 of work through one day"),
                points: 50, target: 100, unit: .money,
                value: { $0.peakDayCostUSD }),
            Spec(
                slug: "weekend100", symbolName: "sofa.fill", glyph: "♨",
                title: Localized.text("Weekender"),
                goal: Localized.text("Send 100 turns on Saturdays and Sundays"),
                points: 25, target: 100, unit: .count(Localized.text("turns")),
                value: { Double($0.weekendTurns) }),
        ]
    }

    static func trophies(facts: TrophyFacts) -> [Trophy] {
        specs().map { spec in
            let value = max(0, spec.value(facts))
            let percent = value >= spec.target ? 100.0 : min(99.9, value / spec.target * 100)
            return Trophy(
                id: "com.guitaripod.tailscode." + spec.slug,
                symbolName: spec.symbolName, glyph: spec.glyph, title: spec.title,
                goal: spec.goal,
                progressLine: progressLine(value: value, target: spec.target, unit: spec.unit),
                percent: percent, points: spec.points)
        }
    }

    static func scores(facts: TrophyFacts) -> [TrophyScore] {
        var scores: [TrophyScore] = []
        if facts.streakDays > 0 {
            scores.append(TrophyScore(leaderboardID: Board.streak, value: facts.streakDays))
        }
        if facts.turns > 0 {
            scores.append(TrophyScore(leaderboardID: Board.turns, value: facts.turns))
        }
        if facts.tokens > 0 {
            scores.append(TrophyScore(leaderboardID: Board.tokens, value: facts.tokens))
        }
        if facts.toolCalls > 0 {
            scores.append(TrophyScore(leaderboardID: Board.tools, value: facts.toolCalls))
        }
        return scores
    }

    /// The card's one-line account of the case: how much is earned, and what is closest.
    public static func headline(_ trophies: [Trophy]) -> String {
        let earned = trophies.filter(\.earned).count
        return Localized.text("%d of %d earned", earned, trophies.count)
    }

    /// The unearned marks nearest their targets — the card shows the chase, not the shelf.
    public static func nextUp(_ trophies: [Trophy], limit: Int = 3) -> [Trophy] {
        Array(
            trophies.filter { !$0.earned }
                .sorted {
                    $0.percent != $1.percent ? $0.percent > $1.percent : $0.points < $1.points
                }
                .prefix(limit))
    }

    private static func progressLine(value: Double, target: Double, unit: Spec.Unit) -> String {
        switch unit {
        case .count(let word):
            return Localized.text(
                "%@ of %@ %@", UsageAnalytics.count(Int(value)),
                UsageAnalytics.count(Int(target)), word)
        case .days:
            return Localized.text("day %d of %d", Int(value), Int(target))
        case .money:
            return Localized.text(
                "%@ of %@", "~" + SessionSpend.money(value), SessionSpend.money(target))
        case .hours:
            return Localized.text("%d of %d hours", Int(value), Int(target))
        case .minutes:
            return Localized.text(
                "%@ of %@", SessionSpend.duration(value), SessionSpend.duration(target))
        }
    }
}
