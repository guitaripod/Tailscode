import CodingAgentKit
import Foundation

/// Accounts to lay the share card out against, one per way a ledger can be awkward: the rich
/// month it is designed for, a single model, twelve of them, names far longer than a tile,
/// no chart to draw, an account that spent nothing because every model ran on its own
/// machine, a window with one active day, a server that could only count conversations, and the
/// two long windows. Deterministic (a fixed clock, a UTC calendar, a seeded generator), so a
/// test, a dump of PNGs on any client and a screenshot all look at the same accounts.
public enum ShareFixtures {
    public static let names = [
        "rich", "oneModel", "twelveModels", "longNames", "noDaily", "localOnly", "tinyWindow",
        "partialCoverage", "quarter", "year", "localSessions",
    ]

    public static var now: Date {
        ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z") ?? Date(timeIntervalSince1970: 0)
    }

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    public struct Case: Sendable {
        public let name: String
        public let analytics: UsageAnalytics
    }

    public static func all() -> [Case] {
        names.compactMap { name in analytics(named: name).map { Case(name: name, analytics: $0) } }
    }

    public static func analytics(named name: String) -> UsageAnalytics? {
        switch name {
        case "rich": return build(servers: [("studio", report())])
        case "oneModel":
            return build(
                servers: [
                    (
                        "studio",
                        report(
                            models: [Model("claude-opus-4-8", 1, rate: 0.9)],
                            projects: [Project("pulse-server", 1)], toolCount: 3)
                    )
                ])
        case "twelveModels":
            return build(
                servers: [
                    (
                        "studio",
                        report(
                            models: (0..<12).map { index in
                                Model(
                                    "model-\(index + 1)-preview", 1 / Double(index + 1),
                                    rate: 0.8 / Double(index + 1))
                            }, projects: (0..<8).map { Project("repo-\($0 + 1)", 1 / Double($0 + 1)) },
                            toolCount: 10)
                    )
                ])
        case "longNames":
            return build(
                servers: [
                    (
                        "studio",
                        report(
                            models: [
                                Model("claude-opus-4-8-20260101-extended-thinking-preview", 0.6, rate: 0.7),
                                Model("anthropic/claude-sonnet-4-5-20250929-with-a-very-long-suffix", 0.3, rate: 0.2),
                                Model("ollama/qwen3-coder-30b-a3b-instruct-q8_0-262144-ctx", 0.1, rate: 0),
                            ],
                            projects: [
                                Project("the-monorepo-that-holds-every-service-and-every-app", 0.5),
                                Project("infrastructure-as-code-for-the-production-cluster", 0.3),
                                Project("a", 0.2),
                            ],
                            tools: ["mcp__plugin_revenuecat_RevenueCat__get-customer-center-config", "Bash", "Edit"],
                            sessionTitle:
                                "Migrate the entire tile cache to content-addressed storage and then rewrite every consumer of it")
                    )
                ])
        case "noDaily":
            return build(servers: [("studio", report(daily: false))])
        case "localOnly":
            return build(
                servers: [
                    (
                        "desk · opencode",
                        report(
                            models: [
                                Model("ollama/qwen3-coder:30b", 0.7, rate: 0),
                                Model("ollama/gpt-oss:120b", 0.3, rate: 0),
                            ], projects: [Project("pulse-server", 0.6), Project("blog", 0.4)],
                            priced: false)
                    )
                ])
        case "localSessions":
            return build(
                servers: [
                    (
                        "desk · opencode",
                        report(
                            models: [Model("ollama/qwen3-coder:30b", 1, rate: 0)],
                            projects: [Project("pulse-server", 1)], priced: false,
                            coverage: .sessionTotals)
                    )
                ])
        case "tinyWindow":
            return build(
                servers: [("studio", report(spanDays: 7, activeDays: 1, toolCount: 2))],
                window: .week)
        case "partialCoverage":
            return build(
                servers: [
                    ("studio", report()),
                    (
                        "laptop · opencode",
                        report(
                            models: [Model("claude-sonnet-4-5", 1, rate: 0.3)],
                            projects: [Project("pulse-ios", 1)], toolCount: 0,
                            coverage: .sessionTotals)
                    ),
                ], missing: ["old-mac"])
        case "quarter":
            return build(servers: [("studio", report(spanDays: 90))], window: .quarter)
        case "year":
            return build(servers: [("studio", report(spanDays: 365))], window: .year)
        default: return nil
        }
    }

    private struct Model {
        let id: String
        let weight: Double
        let rate: Double

        init(_ id: String, _ weight: Double, rate: Double) {
            self.id = id
            self.weight = weight
            self.rate = rate
        }
    }

    private struct Project {
        let name: String
        let weight: Double

        init(_ name: String, _ weight: Double) {
            self.name = name
            self.weight = weight
        }
    }

    private static func build(
        servers: [(String, UsageAnalyticsReport)], window: UsageWindow = .month,
        missing: [String] = []
    ) -> UsageAnalytics? {
        UsageAnalytics(
            servers: servers, missingServers: missing, window: window, now: now,
            calendar: calendar)
    }

    private static func key(daysAgo: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        return formatter.string(
            from: calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today)
    }

    private static func report(
        spanDays: Int = 30, activeDays: Int? = nil,
        models: [Model] = [
            Model("claude-fable-5", 0.55, rate: 0.62), Model("claude-opus-4-8", 0.3, rate: 0.3),
            Model("claude-haiku-4-5", 0.1, rate: 0.06),
            Model("ollama/qwen3-coder:30b", 0.05, rate: 0),
        ],
        projects: [Project] = [
            Project("pulse-server", 0.45), Project("pulse-ios", 0.3), Project("pulse-infra", 0.15),
            Project("blog", 0.1),
        ],
        tools: [String] = [],
        toolCount: Int = 7, daily: Bool = true, priced: Bool = true,
        coverage: UsageAnalyticsReport.Coverage? = nil, sessionTitle: String? = nil
    ) -> UsageAnalyticsReport {
        var seed: UInt64 = 0x5EED
        func noise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) & 0xFFFF) / 65_535
        }
        let measured = coverage == nil
        var days: [UsageAnalyticsReport.Day] = []
        var total = UsageAnalyticsReport.Tokens()
        var cost = 0.0
        var turns = 0
        var calls = 0
        var sessions = 0
        var busiest: UsageAnalyticsReport.Day?
        let kept = activeDays ?? Int(Double(spanDays) * 0.8)
        for offset in (0..<spanDays).reversed() {
            let recent = spanDays - offset
            if let activeDays {
                guard offset < activeDays else { continue }
            } else {
                guard recent > spanDays - kept - 1, noise() > 0.18 else { continue }
            }
            let heat = 0.35 + noise() * 0.9 + (offset == 0 ? 0.4 : 0)
            let dayCost = priced ? (20 + 70 * heat).rounded() : 0
            let dayTurns = measured ? Int(9 + 38 * heat) : 0
            let tokens = UsageAnalyticsReport.Tokens(
                input: Int(41_000 * heat), output: Int(210_000 * heat),
                cacheRead: Int(9_800_000 * heat), cacheWrite5m: Int(610_000 * heat),
                cacheWrite1h: Int(120_000 * heat))
            let day = UsageAnalyticsReport.Day(
                day: key(daysAgo: offset), costUSD: dayCost, tokens: tokens, turns: dayTurns,
                toolCalls: measured ? dayTurns * 11 : 0, sessions: 1 + Int(3.2 * heat))
            days.append(day)
            cost += dayCost
            turns += dayTurns
            calls += day.toolCalls
            sessions += day.sessions
            total = UsageAnalyticsReport.Tokens(
                input: total.input + tokens.input, output: total.output + tokens.output,
                cacheRead: total.cacheRead + tokens.cacheRead,
                cacheWrite5m: total.cacheWrite5m + tokens.cacheWrite5m,
                cacheWrite1h: total.cacheWrite1h + tokens.cacheWrite1h)
            if dayCost > (busiest?.costUSD ?? 0) || (!priced && busiest == nil) { busiest = day }
        }
        let weightSum = models.reduce(0) { $0 + $1.weight }
        let modelShares = models.map { model -> SessionSpendReport.ModelShare in
            let share = model.weight / weightSum
            return SessionSpendReport.ModelShare(
                model: model.id, turns: Int(Double(turns) * share),
                tokens: UsageAnalyticsReport.Tokens(
                    input: Int(Double(total.input) * share),
                    output: Int(Double(total.output) * share),
                    cacheRead: Int(Double(total.cacheRead) * share)),
                costUSD: priced ? cost * model.rate : 0)
        }
        let projectSum = projects.reduce(0) { $0 + $1.weight }
        let projectRows = projects.map { project -> UsageAnalyticsReport.Project in
            let share = project.weight / projectSum
            return UsageAnalyticsReport.Project(
                directory: "/home/demo/dev/\(project.name)", name: project.name,
                sessions: max(1, Int(Double(sessions) * share)), turns: Int(Double(turns) * share),
                costUSD: priced ? cost * share : 0,
                tokens: UsageAnalyticsReport.Tokens(
                    input: Int(Double(total.input) * share),
                    output: Int(Double(total.output) * share)))
        }
        let toolNames =
            tools.isEmpty
            ? Array(
                ["Bash", "Edit", "Read", "Write", "Grep", "WebSearch", "WebFetch", "Glob", "Task", "TodoWrite"]
                    .prefix(toolCount)) : tools
        let toolRows = toolNames.enumerated().map { index, name in
            UsageAnalyticsReport.Tool(name: name, calls: max(1, calls * (50 - index * 4) / 200))
        }
        let hourTurns = [
            2, 1, 0, 0, 0, 0, 1, 4, 14, 32, 41, 38, 22, 19, 26, 44, 39, 31, 24, 28, 46, 51, 37, 12,
        ]
        let records =
            daily
            ? UsageAnalyticsReport.Records(
                busiestDay: busiest.map {
                    .init(day: $0.day, costUSD: $0.costUSD, turns: $0.turns)
                },
                priciestSession: priced
                    ? .init(
                        id: "demo-c2",
                        title: sessionTitle ?? "Migrate the tile cache to content-addressed storage",
                        costUSD: cost * 0.11, turns: 63) : nil,
                priciestTurn: priced
                    ? .init(
                        at: now.addingTimeInterval(-9_000), costUSD: 38.4, seconds: 2_150,
                        model: "claude-fable-5",
                        prompt: "Refactor the sync engine so every writer goes through the journal",
                        sessionTitle: sessionTitle ?? "Migrate the tile cache") : nil,
                longestTurn: .init(
                    at: now.addingTimeInterval(-160_000), costUSD: 21.05, seconds: 4_890,
                    model: "claude-opus-4-8",
                    prompt: "Run the whole soak suite and fix whatever falls out",
                    sessionTitle: "Hunt the flaky WebSocket test"),
                streakDays: min(12, max(1, days.count)))
            : UsageAnalyticsReport.Records()
        return UsageAnalyticsReport(
            since: now.addingTimeInterval(-Double(spanDays) * 86_400), generatedAt: now,
            days: spanDays,
            totals: UsageAnalyticsReport.Totals(
                costUSD: cost, tokens: total, turns: turns, toolCalls: calls, sessions: sessions,
                activeDays: days.count),
            daily: daily ? days : [], models: modelShares, projects: projectRows,
            tools: measured ? toolRows : [], hourTurns: measured ? hourTurns : [],
            hourCostUSD: measured ? hourTurns.map { Double($0) * 1.7 } : [],
            cacheSavedUSD: priced ? cost * 4.6 : 0,
            compactions: .init(count: measured ? 14 : 0, reclaimedTokens: measured ? 4_812_000 : 0),
            subagents: .init(
                runs: measured ? 311 : 0,
                tokens: measured ? .init(output: 96_000_000) : .init(),
                costUSD: measured && priced ? cost * 0.19 : 0), records: records, coverage: coverage)
    }
}
