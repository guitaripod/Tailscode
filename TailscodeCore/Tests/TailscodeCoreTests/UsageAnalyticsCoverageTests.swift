import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// Every model the person actually runs belongs in these numbers, whatever it cost and whatever
/// its server could measure. A local model bills nothing and still does the work; a server whose
/// ledger is one running total per conversation knows the money and not the turns. Neither may
/// read as an account that went unused.
@Suite("Usage analytics across providers")
struct UsageAnalyticsCoverageTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki") ?? .current
        return calendar
    }

    private var now: Date {
        ISO8601DateFormatter().date(from: "2026-08-07T15:00:00+03:00") ?? Date()
    }

    private func key(daysAgo: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(
            from: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))
                ?? now)
    }

    private func tokens(
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0
    ) -> SessionSpendReport.Tokens {
        SessionSpendReport.Tokens(
            input: input, output: output, cacheRead: cacheRead, cacheWrite5m: cacheWrite)
    }

    private func report(
        models: [SessionSpendReport.ModelShare],
        daily: [UsageAnalyticsReport.Day],
        turns: Int = 0, toolCalls: Int = 0, sessions: Int = 1,
        hourTurns: [Int] = [], cacheSavedUSD: Double = 0,
        coverage: UsageAnalyticsReport.Coverage? = nil
    ) -> UsageAnalyticsReport {
        var total = SessionSpendReport.Tokens()
        for model in models {
            total = SessionSpendReport.Tokens(
                input: total.input + model.tokens.input,
                output: total.output + model.tokens.output,
                cacheRead: total.cacheRead + model.tokens.cacheRead,
                cacheWrite5m: total.cacheWrite5m + model.tokens.cacheWrite5m)
        }
        return UsageAnalyticsReport(
            since: now.addingTimeInterval(-30 * 86_400), generatedAt: now, days: 30,
            totals: UsageAnalyticsReport.Totals(
                costUSD: models.reduce(0) { $0 + $1.costUSD }, tokens: total, turns: turns,
                toolCalls: toolCalls, sessions: sessions, activeDays: daily.count),
            daily: daily, models: models, hourTurns: hourTurns, cacheSavedUSD: cacheSavedUSD,
            coverage: coverage)
    }

    private func day(_ daysAgo: Int, cost: Double, tokens count: Int, sessions: Int = 1)
        -> UsageAnalyticsReport.Day
    {
        UsageAnalyticsReport.Day(
            day: key(daysAgo: daysAgo), costUSD: cost, tokens: tokens(output: count),
            sessions: sessions)
    }

    private var localOnly: UsageAnalyticsReport {
        report(
            models: [
                SessionSpendReport.ModelShare(
                    model: "ollama/qwen3-coder:30b", turns: 0,
                    tokens: tokens(input: 400_000, output: 60000), costUSD: 0)
            ],
            daily: [day(1, cost: 0, tokens: 300_000), day(3, cost: 0, tokens: 160_000)],
            sessions: 12, coverage: .sessionTotals)
    }

    @Test("An account whose models all run for free still has a month")
    func freeAccountLeadsWithTheWork() throws {
        let analytics = try #require(
            UsageAnalytics(servers: [("desktop", localOnly)], now: now, calendar: calendar))
        #expect(analytics.headline.contains("$") == false)
        #expect(analytics.totalMoney == "~$0")
        #expect(analytics.days.contains { $0.share > 0 })
        #expect(analytics.peakDay?.value.contains("$") == false)
        #expect(analytics.models.count == 1)
        #expect(analytics.models.first?.isFree == true)
        #expect(analytics.models.first?.money == "Free")
        #expect(analytics.models.first?.share == 1)
        #expect(analytics.modelsLine?.isEmpty == false)
        #expect(analytics.weekdays.contains { $0.share > 0 })
    }

    /// The failure this whole surface exists to avoid: a local model showing a zero bar and a
    /// "$0" beside half a million tokens, which reads as a model nobody used.
    @Test("A free model outranks a hosted one that spent a cent on nothing")
    func freeWorkOutranksTinyPaidWork() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [
                    (
                        "desktop",
                        report(
                            models: [
                                SessionSpendReport.ModelShare(
                                    model: "ollama/qwen3-coder:30b", turns: 0,
                                    tokens: tokens(input: 400_000, output: 60000), costUSD: 0),
                                SessionSpendReport.ModelShare(
                                    model: "xai/grok-4.6", turns: 0,
                                    tokens: tokens(input: 200, output: 90), costUSD: 0.02),
                            ],
                            daily: [day(1, cost: 0.02, tokens: 460_290)], sessions: 4,
                            coverage: .sessionTotals))
                ], now: now, calendar: calendar))
        #expect(analytics.models.map(\.label) == ["qwen3-coder-30b", "grok-4.6"])
        #expect(analytics.models.first?.isFree == true)
        #expect(analytics.models.last?.isFree == false)
        #expect(analytics.models.last?.money == "~$0.02")
        #expect(analytics.modelsLine?.contains("99%") == true)
    }

    @Test("Providers are split when there is more than one door")
    func providersSplitWhenThereIsAChoice() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [
                    (
                        "desktop",
                        report(
                            models: [
                                SessionSpendReport.ModelShare(
                                    model: "ollama/gpt-oss:120b", turns: 0,
                                    tokens: tokens(output: 500_000), costUSD: 0),
                                SessionSpendReport.ModelShare(
                                    model: "claude-opus-5", turns: 40,
                                    tokens: tokens(output: 100_000), costUSD: 12),
                            ],
                            daily: [day(1, cost: 12, tokens: 600_000)], turns: 40, sessions: 6))
                ], now: now, calendar: calendar))
        #expect(analytics.providers.map(\.label) == ["Ollama", "Anthropic"])
        #expect(analytics.providers.first?.detail.contains("on your own machine") == true)
        #expect(analytics.providers.first?.isFree == true)
        #expect(analytics.providers.last?.money == "~$12.00")
    }

    @Test("One provider is not a split worth drawing")
    func oneProviderHasNoSection() throws {
        let analytics = try #require(
            UsageAnalytics(servers: [("desktop", localOnly)], now: now, calendar: calendar))
        #expect(analytics.providers.isEmpty)
    }

    @Test("A server that counts conversations rather than turns says so")
    func coarseServerDeclaresItself() throws {
        let analytics = try #require(
            UsageAnalytics(servers: [("desktop", localOnly)], now: now, calendar: calendar))
        #expect(analytics.coverage.contains(.turns) == false)
        #expect(analytics.coverageNote?.contains("desktop") == true)
        #expect(analytics.activityLine.contains("turns") == false)
        #expect(analytics.activityLine.contains("tool calls") == false)
        #expect(analytics.activityLine.contains("conversations"))
        #expect(analytics.hours.isEmpty)
        #expect(analytics.clockLine == nil)
        #expect(analytics.tools.isEmpty)
    }

    @Test("A mixed account names the machine whose counts are missing")
    func mixedCoverageNamesTheCoarseMachine() throws {
        let full = report(
            models: [
                SessionSpendReport.ModelShare(
                    model: "claude-opus-5", turns: 40, tokens: tokens(output: 90000), costUSD: 20)
            ],
            daily: [day(1, cost: 20, tokens: 90000)], turns: 40, toolCalls: 300, sessions: 5,
            hourTurns: [Int](repeating: 0, count: 13) + [40] + [Int](repeating: 0, count: 10))
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", full), ("desktop", localOnly)], now: now,
                calendar: calendar))
        #expect(analytics.coverageNote?.contains("desktop") == true)
        #expect(analytics.coverageNote?.contains("1 of 2") == true)
        #expect(analytics.activityLine.contains("40 turns"))
        #expect(analytics.hours.isEmpty == false)
        #expect(analytics.machines.map(\.label) == ["studio", "desktop"])
        #expect(analytics.machines.last?.isFree == true)
    }

    @Test("Every server reporting the full ledger says nothing about coverage")
    func fullCoverageIsSilent() throws {
        let full = report(
            models: [
                SessionSpendReport.ModelShare(
                    model: "claude-opus-5", turns: 40, tokens: tokens(output: 90000), costUSD: 20)
            ],
            daily: [day(1, cost: 20, tokens: 90000)], turns: 40, sessions: 5)
        let analytics = try #require(
            UsageAnalytics(servers: [("studio", full)], now: now, calendar: calendar))
        #expect(analytics.coverageNote == nil)
        #expect(analytics.coverage == .all)
        #expect(analytics.modelsLine == nil)
    }

    /// A server that reports the money and the tokens but prices nothing itself still has a cache
    /// story worth telling, and it is the same split the tier chart already draws.
    @Test("Cache saving is implied where a server reports none")
    func cacheSavingIsImpliedFromTheTierSplit() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [
                    (
                        "desktop",
                        report(
                            models: [
                                SessionSpendReport.ModelShare(
                                    model: "anthropic/claude-opus-5", turns: 0,
                                    tokens: tokens(
                                        input: 50000, output: 50000, cacheRead: 8_000_000),
                                    costUSD: 60)
                            ],
                            daily: [day(1, cost: 60, tokens: 8_100_000)], sessions: 9,
                            coverage: .sessionTotals))
                ], now: now, calendar: calendar))
        #expect(analytics.cacheLine?.isEmpty == false)
        #expect(analytics.cacheLine?.contains("%") == true)
    }

    @Test("A conversation that cost nothing is not the priciest one")
    func aFreeConversationIsNoRecord() throws {
        var coarse = localOnly
        coarse.records.priciestSession = UsageAnalyticsReport.Records.Session(
            id: "s", title: "Free chat", costUSD: 0, turns: 0)
        let analytics = try #require(
            UsageAnalytics(servers: [("desktop", coarse)], now: now, calendar: calendar))
        #expect(analytics.records.contains { $0.id == "priciestSession" } == false)
        #expect(analytics.records.contains { $0.id == "busiestDay" })
    }

    /// Ollama Cloud is a subscription and a gateway's free tier is somebody's money. A server
    /// that has no rate for a hosted door reports zero, and zero drawn as "Free" claims a bill
    /// that exists is nothing — only a model on a machine the person owns is free.
    @Test("A hosted model the server cannot price reads Unpriced, never Free")
    func hostedZeroIsUnpriced() throws {
        let cloud = SessionSpendReport.Tokens(input: 2_000_000, output: 40_000)
        let local = SessionSpendReport.Tokens(input: 1_000_000, output: 20_000)
        let paid = SessionSpendReport.Tokens(input: 100_000, output: 5_000)
        let report = UsageAnalyticsReport(
            since: Date(timeIntervalSinceNow: -30 * 86400), generatedAt: Date(), days: 30,
            totals: UsageAnalyticsReport.Totals(
                costUSD: 12, tokens: SessionSpendReport.Tokens(input: 3_100_000, output: 65_000),
                sessions: 3, activeDays: 1),
            daily: [
                UsageAnalyticsReport.Day(
                    day: "2026-08-07", costUSD: 12,
                    tokens: SessionSpendReport.Tokens(input: 3_100_000, output: 65_000),
                    sessions: 3)
            ],
            models: [
                SessionSpendReport.ModelShare(
                    model: "ollama-cloud/glm-5.3-flash", turns: 0, tokens: cloud, costUSD: 0),
                SessionSpendReport.ModelShare(
                    model: "ollama/qwen3-coder:30b", turns: 0, tokens: local, costUSD: 0),
                SessionSpendReport.ModelShare(
                    model: "anthropic/claude-opus-5", turns: 0, tokens: paid, costUSD: 12),
            ],
            coverage: .sessionTotals)
        let analytics = try #require(UsageAnalytics(servers: [("desk · opencode", report)]))
        let glm = try #require(analytics.models.first { $0.label.contains("glm") })
        #expect(glm.money == "Unpriced")
        let qwen = try #require(analytics.models.first { $0.label.contains("qwen") })
        #expect(qwen.money == "Free")
        let cloudRow = try #require(analytics.providers.first { $0.label == "Ollama Cloud" })
        #expect(cloudRow.money == "Unpriced")
        let line = try #require(analytics.modelsLine)
        #expect(line.contains("unpriced"))
        #expect(line.contains("Ollama Cloud"))
        #expect(line.contains("on a machine you already own"))
        #expect(!line.contains("2 models cost nothing"))
    }
}
