import AgentTestSupport
import CodingAgentKit
import CodingAgentKitApple
import Foundation

extension DemoWorld {
    /// Thirty plausible days for the demo screenshots: a working rhythm with quiet weekends, a
    /// three-model split, evenings that run hot, and records worth showing. Deterministic — the
    /// same screenshot twice — via a tiny seeded generator rather than anything random.
    public static func demoAnalytics(now: Date = Date()) -> UsageAnalyticsReport {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let window = 30
        var seed: UInt64 = 0x5EED
        func noise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) & 0xFFFF) / 65_535
        }

        var daily: [UsageAnalyticsReport.Day] = []
        var totalCost = 0.0
        var totalTurns = 0
        var totalTools = 0
        var totalSessions = 0
        var tokens = UsageAnalyticsReport.Tokens()
        var busiest: UsageAnalyticsReport.Day?
        for offset in (0..<window).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            let skip = noise() < (weekend ? 0.45 : 0.06)
            if skip { continue }
            let heat = (weekend ? 0.35 : 1.0) * (0.4 + noise())
            let cost = (18 + 74 * heat).rounded()
            let turns = Int(9 + 38 * heat)
            let dayTokens = UsageAnalyticsReport.Tokens(
                input: Int(41_000 * heat), output: Int(210_000 * heat),
                cacheRead: Int(9_800_000 * heat), cacheWrite5m: Int(610_000 * heat),
                cacheWrite1h: Int(120_000 * heat))
            let day = UsageAnalyticsReport.Day(
                day: formatter.string(from: date), costUSD: cost, tokens: dayTokens,
                turns: turns, toolCalls: turns * 11, sessions: 1 + Int(3.2 * heat))
            daily.append(day)
            totalCost += cost
            totalTurns += turns
            totalTools += day.toolCalls
            totalSessions += day.sessions
            tokens = UsageAnalyticsReport.Tokens(
                input: tokens.input + dayTokens.input, output: tokens.output + dayTokens.output,
                cacheRead: tokens.cacheRead + dayTokens.cacheRead,
                cacheWrite5m: tokens.cacheWrite5m + dayTokens.cacheWrite5m,
                cacheWrite1h: tokens.cacheWrite1h + dayTokens.cacheWrite1h)
            if day.costUSD > (busiest?.costUSD ?? 0) { busiest = day }
        }
        let activeDays = daily.filter { $0.turns > 0 }.count

        let hourTurns = [
            2, 1, 0, 0, 0, 0, 1, 4, 14, 32, 41, 38, 22, 19, 26, 44, 39, 31, 24, 28, 46, 51, 37,
            12,
        ]
        let hourCost = hourTurns.map { Double($0) * 1.7 }

        return UsageAnalyticsReport(
            since: calendar.date(byAdding: .day, value: -(window - 1), to: today) ?? today,
            generatedAt: now, days: window,
            totals: UsageAnalyticsReport.Totals(
                costUSD: totalCost, tokens: tokens, turns: totalTurns, toolCalls: totalTools,
                sessions: totalSessions, activeDays: activeDays),
            daily: daily,
            models: [
                SessionSpendReport.ModelShare(
                    model: "claude-fable-5", turns: totalTurns * 6 / 10,
                    tokens: UsageAnalyticsReport.Tokens(output: tokens.output * 6 / 10),
                    costUSD: totalCost * 0.62),
                SessionSpendReport.ModelShare(
                    model: "claude-opus-4-8", turns: totalTurns * 3 / 10,
                    tokens: UsageAnalyticsReport.Tokens(output: tokens.output * 3 / 10),
                    costUSD: totalCost * 0.31),
                SessionSpendReport.ModelShare(
                    model: "claude-haiku-4-5", turns: totalTurns / 10,
                    tokens: UsageAnalyticsReport.Tokens(output: tokens.output / 10),
                    costUSD: totalCost * 0.07),
            ],
            projects: [
                UsageAnalyticsReport.Project(
                    directory: "/Users/demo/dev/pulse-server", name: "pulse-server",
                    sessions: totalSessions * 4 / 10, turns: totalTurns * 5 / 10,
                    costUSD: totalCost * 0.47),
                UsageAnalyticsReport.Project(
                    directory: "/Users/demo/dev/pulse-ios", name: "pulse-ios",
                    sessions: totalSessions * 3 / 10, turns: totalTurns * 3 / 10,
                    costUSD: totalCost * 0.33),
                UsageAnalyticsReport.Project(
                    directory: "/Users/demo/dev/pulse-infra", name: "pulse-infra",
                    sessions: totalSessions * 2 / 10, turns: totalTurns / 10,
                    costUSD: totalCost * 0.14),
                UsageAnalyticsReport.Project(
                    directory: "/Users/demo/dev/blog", name: "blog",
                    sessions: totalSessions / 10, turns: totalTurns / 10,
                    costUSD: totalCost * 0.06),
            ],
            tools: [
                UsageAnalyticsReport.Tool(name: "Bash", calls: totalTools * 52 / 100),
                UsageAnalyticsReport.Tool(name: "Edit", calls: totalTools * 18 / 100),
                UsageAnalyticsReport.Tool(name: "Read", calls: totalTools * 14 / 100),
                UsageAnalyticsReport.Tool(name: "Write", calls: totalTools * 7 / 100),
                UsageAnalyticsReport.Tool(name: "Grep", calls: totalTools * 5 / 100),
                UsageAnalyticsReport.Tool(name: "WebSearch", calls: totalTools * 3 / 100),
                UsageAnalyticsReport.Tool(name: "WebFetch", calls: totalTools / 100),
            ],
            hourTurns: hourTurns, hourCostUSD: hourCost,
            cacheSavedUSD: totalCost * 4.6,
            compactions: UsageAnalyticsReport.Compactions(
                count: 14, reclaimedTokens: 4_812_000),
            subagents: UsageAnalyticsReport.Subagents(
                runs: 311, tokens: UsageAnalyticsReport.Tokens(output: 96_000_000),
                costUSD: totalCost * 0.19),
            records: UsageAnalyticsReport.Records(
                busiestDay: busiest.map {
                    UsageAnalyticsReport.Records.BusiestDay(
                        day: $0.day, costUSD: $0.costUSD, turns: $0.turns)
                },
                priciestSession: UsageAnalyticsReport.Records.Session(
                    id: "demo-c2", title: "Migrate the tile cache to content-addressed storage",
                    costUSD: totalCost * 0.11, turns: 63),
                priciestTurn: UsageAnalyticsReport.Records.Turn(
                    at: ago(9_000), costUSD: 38.40, seconds: 2_150, model: "claude-fable-5",
                    prompt: "Refactor the sync engine so every writer goes through the journal",
                    sessionTitle: "Migrate the tile cache to content-addressed storage"),
                longestTurn: UsageAnalyticsReport.Records.Turn(
                    at: ago(160_000), costUSD: 21.05, seconds: 4_890, model: "claude-opus-4-8",
                    prompt: "Run the whole soak suite and fix whatever falls out",
                    sessionTitle: "Hunt the flaky WebSocket test"),
                streakDays: 9))
    }

    /// What a homelab's llama.cpp server did over thirty days, in the shape an opencode server can
    /// afford to report: the money, the tokens by tier, the model and the project of each session
    /// record and nothing about the turns inside. Two codenamed models on the owner's own GPU, so
    /// the demo shows the section that exists for them. Deterministic, like the hosted ledger.
    public static func demoLocalAnalytics(now: Date = Date()) -> UsageAnalyticsReport {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let window = 30
        var seed: UInt64 = 0xB017
        func noise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) & 0xFFFF) / 65_535
        }

        var daily: [UsageAnalyticsReport.Day] = []
        var tokens = UsageAnalyticsReport.Tokens()
        var sessions = 0
        for offset in (0..<window).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7
            if noise() < (weekend ? 0.3 : 0.08) { continue }
            let heat = (weekend ? 0.6 : 1.0) * (0.3 + noise())
            let day = UsageAnalyticsReport.Day(
                day: formatter.string(from: date), costUSD: 0,
                tokens: UsageAnalyticsReport.Tokens(
                    input: Int(96_000 * heat), output: Int(19_000 * heat)),
                sessions: 1 + Int(2.4 * heat))
            daily.append(day)
            sessions += day.sessions
            tokens = UsageAnalyticsReport.Tokens(
                input: tokens.input + day.tokens.input, output: tokens.output + day.tokens.output)
        }
        func share(_ part: Double) -> UsageAnalyticsReport.Tokens {
            UsageAnalyticsReport.Tokens(
                input: Int(Double(tokens.input) * part), output: Int(Double(tokens.output) * part))
        }
        return UsageAnalyticsReport(
            since: calendar.date(byAdding: .day, value: -(window - 1), to: today) ?? today,
            generatedAt: now, days: window,
            totals: UsageAnalyticsReport.Totals(
                costUSD: 0, tokens: tokens, sessions: sessions, activeDays: daily.count),
            daily: daily,
            models: [
                SessionSpendReport.ModelShare(
                    model: "llama-server/qwen3-coder-30b-a3b", turns: 0, tokens: share(0.64),
                    costUSD: 0),
                SessionSpendReport.ModelShare(
                    model: "llama-server/qwen3.6-27b", turns: 0, tokens: share(0.36), costUSD: 0),
            ],
            projects: [
                UsageAnalyticsReport.Project(
                    directory: "/home/demo/dev/acme-api", name: "acme-api",
                    sessions: sessions * 6 / 10, tokens: share(0.6)),
                UsageAnalyticsReport.Project(
                    directory: "/home/demo/dev/acme-web", name: "acme-web",
                    sessions: sessions * 4 / 10, tokens: share(0.4)),
            ],
            coverage: .sessionTotals)
    }
}
