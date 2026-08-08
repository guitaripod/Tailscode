import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Trophies")
struct TrophyTests {
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
        daily: [UsageAnalyticsReport.Day] = [], hourTurns: [Int] = [Int](repeating: 0, count: 24),
        totals: UsageAnalyticsReport.Totals? = nil,
        records: UsageAnalyticsReport.Records = UsageAnalyticsReport.Records(),
        subagents: UsageAnalyticsReport.Subagents = UsageAnalyticsReport.Subagents(),
        compactions: UsageAnalyticsReport.Compactions = UsageAnalyticsReport.Compactions(),
        cacheSavedUSD: Double = 0
    ) -> UsageAnalyticsReport {
        let cost = daily.reduce(0) { $0 + $1.costUSD }
        let turns = daily.reduce(0) { $0 + $1.turns }
        return UsageAnalyticsReport(
            since: now.addingTimeInterval(-30 * 86_400), generatedAt: now, days: 30,
            totals: totals
                ?? UsageAnalyticsReport.Totals(
                    costUSD: cost, tokens: UsageAnalyticsReport.Tokens(output: 1000),
                    turns: turns, toolCalls: turns * 8, sessions: max(1, daily.count),
                    activeDays: daily.count),
            daily: daily, hourTurns: hourTurns, hourCostUSD: [],
            cacheSavedUSD: cacheSavedUSD, compactions: compactions, subagents: subagents,
            records: records)
    }

    private func day(_ daysAgo: Int, cost: Double, turns: Int = 10) -> UsageAnalyticsReport.Day {
        UsageAnalyticsReport.Day(
            day: key(daysAgo: daysAgo), costUSD: cost,
            tokens: UsageAnalyticsReport.Tokens(output: 1000), turns: turns, toolCalls: turns * 8,
            sessions: 2)
    }

    private func merge(_ reports: [(String, UsageAnalyticsReport)]) -> UsageAnalytics? {
        UsageAnalytics(servers: reports, now: now, calendar: calendar)
    }

    @Test("The catalog is well-formed: unique ids, points within Game Center's budget")
    func catalogShape() {
        let specs = TrophyRoom.specs()
        #expect(Set(specs.map(\.slug)).count == specs.count)
        #expect(specs.reduce(0) { $0 + $1.points } <= 1_000)
        #expect(specs.allSatisfy { $0.target > 0 })
        #expect(Set(TrophyRoom.Board.all).count == TrophyRoom.Board.all.count)
    }

    @Test("Every merge carries the whole catalog, earned or not")
    func wholeCatalogAlways() throws {
        let analytics = try #require(merge([("studio", report(daily: [day(1, cost: 5)]))]))
        #expect(analytics.trophies.count == TrophyRoom.specs().count)
        let first = try #require(
            analytics.trophies.first { $0.id == "com.guitaripod.tailscode.turns1" })
        #expect(first.earned)
        let billion = try #require(
            analytics.trophies.first { $0.id == "com.guitaripod.tailscode.tokens1b" })
        #expect(!billion.earned)
        #expect(billion.percent < 1)
    }

    @Test("Progress short of the target never reads as earned")
    func nearMissStaysUnearned() throws {
        let daily = (1...6).map { day($0, cost: 10, turns: 16) }
        let analytics = try #require(merge([("studio", report(daily: daily))]))
        let streak7 = try #require(
            analytics.trophies.first { $0.id == "com.guitaripod.tailscode.streak7" })
        #expect(!streak7.earned)
        #expect(streak7.percent > 80)
        let turns100 = try #require(
            analytics.trophies.first { $0.id == "com.guitaripod.tailscode.turns100" })
        #expect(!turns100.earned)
    }

    @Test("A second machine is counted across the merge, not per report")
    func machinesMerge() throws {
        let one = try #require(merge([("studio", report(daily: [day(1, cost: 5)]))]))
        let second = try #require(
            one.trophies.first { $0.id == "com.guitaripod.tailscode.machines2" })
        #expect(!second.earned)
        let two = try #require(
            merge([
                ("studio", report(daily: [day(1, cost: 5)])),
                ("laptop", report(daily: [day(2, cost: 5)])),
            ]))
        let earned = try #require(
            two.trophies.first { $0.id == "com.guitaripod.tailscode.machines2" })
        #expect(earned.earned)
    }

    @Test("The clock trophies read the merged hours")
    func hourTrophies() throws {
        var hours = [Int](repeating: 1, count: 24)
        hours[2] = 60
        let analytics = try #require(
            merge([("studio", report(daily: [day(1, cost: 5)], hourTurns: hours))]))
        let night = try #require(
            analytics.trophies.first { $0.id == "com.guitaripod.tailscode.night50" })
        #expect(night.earned)
        let clock = try #require(
            analytics.trophies.first { $0.id == "com.guitaripod.tailscode.clock24" })
        #expect(clock.earned)
    }

    @Test("Scores carry only what happened, in the boards' own units")
    func scores() throws {
        let daily = [day(0, cost: 10, turns: 40), day(1, cost: 10, turns: 60)]
        let analytics = try #require(merge([("studio", report(daily: daily))]))
        let streak = try #require(
            analytics.scores.first { $0.leaderboardID == TrophyRoom.Board.streak })
        #expect(streak.value == 2)
        let turns = try #require(
            analytics.scores.first { $0.leaderboardID == TrophyRoom.Board.turns })
        #expect(turns.value == 100)
        let tools = try #require(
            analytics.scores.first { $0.leaderboardID == TrophyRoom.Board.tools })
        #expect(tools.value == 800)
    }

    @Test("The chase leads the card: nextUp is unearned, nearest first")
    func nextUp() throws {
        let daily = (1...6).map { day($0, cost: 10, turns: 16) }
        let analytics = try #require(merge([("studio", report(daily: daily))]))
        let next = TrophyRoom.nextUp(analytics.trophies)
        #expect(next.count == 3)
        #expect(next.allSatisfy { !$0.earned })
        #expect(next[0].percent >= next[1].percent)
        #expect(next[1].percent >= next[2].percent)
        #expect(TrophyRoom.headline(analytics.trophies).contains("of"))
    }
}
