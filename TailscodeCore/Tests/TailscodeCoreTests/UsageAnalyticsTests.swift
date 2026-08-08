import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Usage analytics")
struct UsageAnalyticsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki") ?? .current
        return calendar
    }

    private var now: Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-08-07T15:00:00+03:00") ?? Date()
    }

    private func key(daysAgo: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = calendar.date(
            byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
        return formatter.string(from: day)
    }

    private func report(
        days: Int = 30, daily: [UsageAnalyticsReport.Day] = [],
        models: [SessionSpendReport.ModelShare] = [],
        tools: [UsageAnalyticsReport.Tool] = [],
        totals: UsageAnalyticsReport.Totals? = nil,
        records: UsageAnalyticsReport.Records = UsageAnalyticsReport.Records(),
        subagents: UsageAnalyticsReport.Subagents = UsageAnalyticsReport.Subagents(),
        cacheSavedUSD: Double = 0
    ) -> UsageAnalyticsReport {
        let cost = daily.reduce(0) { $0 + $1.costUSD }
        let turns = daily.reduce(0) { $0 + $1.turns }
        return UsageAnalyticsReport(
            since: now.addingTimeInterval(-Double(days) * 86_400), generatedAt: now, days: days,
            totals: totals
                ?? UsageAnalyticsReport.Totals(
                    costUSD: cost, tokens: UsageAnalyticsReport.Tokens(output: 1000),
                    turns: turns, toolCalls: tools.reduce(0) { $0 + $1.calls },
                    sessions: max(1, daily.count), activeDays: daily.count),
            daily: daily, models: models, tools: tools,
            hourTurns: [Int](repeating: 0, count: 24), hourCostUSD: [],
            cacheSavedUSD: cacheSavedUSD, subagents: subagents, records: records)
    }

    private func day(_ daysAgo: Int, cost: Double, turns: Int = 10) -> UsageAnalyticsReport.Day {
        UsageAnalyticsReport.Day(
            day: key(daysAgo: daysAgo), costUSD: cost,
            tokens: UsageAnalyticsReport.Tokens(output: 1000), turns: turns, toolCalls: turns * 8,
            sessions: 2)
    }

    @Test("An empty haul has nothing to show")
    func emptyHaul() {
        #expect(
            UsageAnalytics(
                servers: [("studio", report())], now: now, calendar: calendar) == nil)
        #expect(UsageAnalytics(servers: [], now: now, calendar: calendar) == nil)
    }

    @Test("The daily chart holds the whole window, empty days present and zero")
    func windowIsZeroFilled() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", report(daily: [day(1, cost: 40), day(3, cost: 10)]))],
                now: now, calendar: calendar))
        #expect(analytics.days.count == 30)
        #expect(analytics.days.last?.isToday == true)
        #expect(analytics.days.filter { $0.costUSD > 0 }.count == 2)
        let peak = try #require(analytics.peakDay)
        #expect(peak.key == key(daysAgo: 1))
        #expect(peak.share == 1)
    }

    @Test("Two servers merge into one account: days add, models add, records take the max")
    func mergesServers() throws {
        let a = report(
            daily: [day(1, cost: 30)],
            models: [
                SessionSpendReport.ModelShare(
                    model: "claude-fable-5", turns: 5,
                    tokens: UsageAnalyticsReport.Tokens(output: 100), costUSD: 30)
            ],
            records: UsageAnalyticsReport.Records(
                priciestSession: UsageAnalyticsReport.Records.Session(
                    id: "a", title: "small", costUSD: 12, turns: 4),
                streakDays: 2))
        let b = report(
            daily: [day(1, cost: 10), day(2, cost: 5)],
            models: [
                SessionSpendReport.ModelShare(
                    model: "claude-fable-5", turns: 2,
                    tokens: UsageAnalyticsReport.Tokens(output: 50), costUSD: 10)
            ],
            records: UsageAnalyticsReport.Records(
                priciestSession: UsageAnalyticsReport.Records.Session(
                    id: "b", title: "big", costUSD: 25, turns: 9),
                streakDays: 1))
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", a), ("laptop", b)], now: now, calendar: calendar))
        let yesterday = try #require(analytics.days.first { $0.key == key(daysAgo: 1) })
        #expect(yesterday.costUSD == 40)
        #expect(analytics.models.count == 1)
        #expect(analytics.models.first?.money == "~$40.00")
        #expect(analytics.machines.count == 2)
        #expect(analytics.machines.first?.label == "studio")
        #expect(analytics.records.contains { $0.id == "priciestSession" && $0.detail == "big" })
    }

    @Test("One machine needs no machine split")
    func singleServerHasNoMachines() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", report(daily: [day(1, cost: 10)]))],
                now: now, calendar: calendar))
        #expect(analytics.machines.isEmpty)
    }

    @Test("A quiet recent week reads as down, a loud one as up, noise as steady")
    func trend() throws {
        var loud: [UsageAnalyticsReport.Day] = []
        for offset in 0..<7 { loud.append(day(offset, cost: 100)) }
        for offset in 7..<14 { loud.append(day(offset, cost: 10)) }
        let up = try #require(
            UsageAnalytics(
                servers: [("studio", report(daily: loud))], now: now, calendar: calendar))
        #expect(up.trend == .up)

        var quiet: [UsageAnalyticsReport.Day] = []
        for offset in 0..<7 { quiet.append(day(offset, cost: 10)) }
        for offset in 7..<14 { quiet.append(day(offset, cost: 100)) }
        let down = try #require(
            UsageAnalytics(
                servers: [("studio", report(daily: quiet))], now: now, calendar: calendar))
        #expect(down.trend == .down)

        var even: [UsageAnalyticsReport.Day] = []
        for offset in 0..<14 { even.append(day(offset, cost: 50)) }
        let flat = try #require(
            UsageAnalytics(
                servers: [("studio", report(daily: even))], now: now, calendar: calendar))
        #expect(flat.trend == .flat)
        #expect(flat.deltaLine == Localized.text("Steady week over week"))
    }

    @Test("The streak is counted over the merged account, not either server's word for it")
    func streakIsRecomputed() throws {
        let a = report(daily: [day(0, cost: 5), day(2, cost: 5)])
        let b = report(daily: [day(1, cost: 5)])
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", a), ("laptop", b)], now: now, calendar: calendar))
        #expect(analytics.records.contains { $0.id == "streak" && $0.value.contains("3") })
    }

    @Test("Tools carry their own percent and the headline names the workhorse")
    func tools() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [
                    (
                        "studio",
                        report(
                            daily: [day(1, cost: 10)],
                            tools: [
                                UsageAnalyticsReport.Tool(name: "Bash", calls: 75),
                                UsageAnalyticsReport.Tool(name: "Edit", calls: 25),
                            ])
                    )
                ], now: now, calendar: calendar))
        #expect(analytics.tools.first?.label == "Bash")
        #expect(analytics.tools.first?.share == 1)
        #expect(analytics.tools.first?.money == "75%")
        #expect(analytics.toolsLine?.contains("Bash") == true)
        #expect(analytics.toolsLine?.contains("75%") == true)
    }

    @Test("Weekdays read Monday first")
    func weekdaysMondayFirst() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", report(daily: [day(1, cost: 10)]))],
                now: now, calendar: calendar))
        #expect(analytics.weekdays.count == 7)
        #expect(analytics.weekdays.first?.label == calendar.shortWeekdaySymbols[1])
    }

    @Test("The busiest day is the account's peak, not either machine's own")
    func busiestDayIsMerged() throws {
        let a = report(
            daily: [day(1, cost: 30), day(2, cost: 25)],
            records: UsageAnalyticsReport.Records(
                busiestDay: UsageAnalyticsReport.Records.BusiestDay(
                    day: key(daysAgo: 1), costUSD: 30, turns: 10)))
        let b = report(
            daily: [day(2, cost: 20)],
            records: UsageAnalyticsReport.Records(
                busiestDay: UsageAnalyticsReport.Records.BusiestDay(
                    day: key(daysAgo: 2), costUSD: 20, turns: 10)))
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", a), ("laptop", b)], now: now, calendar: calendar))
        let busiest = try #require(analytics.records.first { $0.id == "busiestDay" })
        #expect(busiest.value.contains("$45"))
    }

    @Test("Days a server reports as empty count as neither active nor streak")
    func inertDaysDoNotCount() throws {
        var daily = [day(0, cost: 10), day(1, cost: 10)]
        daily.append(UsageAnalyticsReport.Day(day: key(daysAgo: 2)))
        daily.append(day(3, cost: 10))
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", report(daily: daily))], now: now, calendar: calendar))
        #expect(analytics.records.contains { $0.id == "streak" && $0.value.contains("2") })
        #expect(analytics.perDayLine.contains("3 active days"))
    }

    @Test("Every server too old is still a surface, not a vanished account")
    func onlyMissingServers() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [], missingServers: ["attic"], now: now, calendar: calendar))
        #expect(analytics.missingServers == ["attic"])
        #expect(analytics.days.count == 30)
        #expect(analytics.records.isEmpty)
    }

    @Test("Money marks itself an estimate, and the servers too old to answer are named")
    func provenance() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", report(daily: [day(1, cost: 10)]))],
                missingServers: ["attic"], now: now, calendar: calendar))
        #expect(analytics.totalMoney.hasPrefix("~"))
        #expect(analytics.source.contains("Estimated"))
        #expect(analytics.missingServers == ["attic"])
    }

    @Test("The demo world fills every section, so a screenshot never shows a hole")
    func demoWorldIsFull() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [("studio", DemoWorld.demoAnalytics(now: now))],
                now: now, calendar: calendar))
        #expect(analytics.days.count == 30)
        #expect(!analytics.models.isEmpty)
        #expect(!analytics.projects.isEmpty)
        #expect(!analytics.tools.isEmpty)
        #expect(!analytics.tiers.isEmpty)
        #expect(analytics.cacheLine != nil)
        #expect(analytics.records.count >= 5)
        #expect(!analytics.insights.isEmpty)
        #expect(analytics.clockLine != nil)
    }
}
