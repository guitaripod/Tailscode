import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Analytics share")
struct AnalyticsShareTests {
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

    private func day(_ daysAgo: Int, cost: Double, turns: Int = 10) -> UsageAnalyticsReport.Day {
        UsageAnalyticsReport.Day(
            day: key(daysAgo: daysAgo), costUSD: cost,
            tokens: UsageAnalyticsReport.Tokens(output: 1000), turns: turns, toolCalls: turns * 8,
            sessions: 2)
    }

    private func report(
        daily: [UsageAnalyticsReport.Day],
        models: [SessionSpendReport.ModelShare] = [],
        tools: [UsageAnalyticsReport.Tool] = [],
        records: UsageAnalyticsReport.Records = UsageAnalyticsReport.Records()
    ) -> UsageAnalyticsReport {
        let cost = daily.reduce(0) { $0 + $1.costUSD }
        let turns = daily.reduce(0) { $0 + $1.turns }
        return UsageAnalyticsReport(
            since: now.addingTimeInterval(-30 * 86_400), generatedAt: now, days: 30,
            totals: UsageAnalyticsReport.Totals(
                costUSD: cost, tokens: UsageAnalyticsReport.Tokens(output: 50_000),
                turns: turns, toolCalls: tools.reduce(0) { $0 + $1.calls },
                sessions: max(1, daily.count), activeDays: daily.count),
            daily: daily, models: models, tools: tools,
            hourTurns: [Int](repeating: 0, count: 24), hourCostUSD: [],
            cacheSavedUSD: 12, subagents: .init(), records: records)
    }

    private func analytics() throws -> UsageAnalytics {
        try #require(
            UsageAnalytics(
                servers: [
                    (
                        "studio",
                        report(
                            daily: [
                                day(0, cost: 12), day(1, cost: 40), day(2, cost: 18),
                                day(3, cost: 9), day(8, cost: 22),
                            ],
                            models: [
                                SessionSpendReport.ModelShare(
                                    model: "claude-opus-4", turns: 40,
                                    tokens: .init(output: 20_000), costUSD: 60),
                                SessionSpendReport.ModelShare(
                                    model: "claude-sonnet-4", turns: 80,
                                    tokens: .init(output: 30_000), costUSD: 41),
                            ],
                            tools: [
                                UsageAnalyticsReport.Tool(name: "Bash", calls: 120),
                                UsageAnalyticsReport.Tool(name: "Edit", calls: 40),
                            ],
                            records: UsageAnalyticsReport.Records(
                                priciestSession: UsageAnalyticsReport.Records.Session(
                                    id: "s1", title: "Rewrite the feed", costUSD: 18, turns: 12))
                        )
                    )
                ],
                now: now, calendar: calendar))
    }

    @Test("The package carries words, a filename and a card of fixed width")
    func packageShape() throws {
        let analytics = try analytics()
        let share = AnalyticsShare(analytics, now: now, calendar: calendar)
        #expect(share.subject.contains(analytics.totalMoney))
        #expect(share.filename.hasPrefix("tailscode-month-2026-08-07-"))
        #expect(share.filename.hasSuffix(".png"))
        #expect(!share.filename.contains(" "))
        #expect(!share.plainText.isEmpty)
        #expect(share.markdown.contains("# "))
        #expect(share.card.blocks.contains { if case .hero = $0 { return true }; return false })
        #expect(share.card.blocks.contains { if case .daily = $0 { return true }; return false })
        #expect(abs(share.card.height - AnalyticsShare.Card.measure(share.card.blocks)) < 0.5)
        #expect(share.card.height > 600)
        #expect(AnalyticsShare.Card.width == 1080)
    }

    @Test("Plain text and markdown carry the same facts and the estimate foot")
    func wordsCarryTheFacts() throws {
        let analytics = try analytics()
        let share = AnalyticsShare(analytics, now: now, calendar: calendar)
        for sample in [share.plainText, share.markdown] {
            #expect(sample.contains(analytics.totalMoney))
            #expect(sample.contains(analytics.windowLabel))
            #expect(sample.contains(analytics.activityLine))
            #expect(sample.contains("Models") || sample.contains(analytics.models[0].label))
            #expect(sample.contains("API-equivalent estimate"))
            #expect(sample.contains("Tailscode") || sample.contains("tailscode") || sample.contains("*Tailscode*"))
        }
        #expect(share.markdown.contains("**\(analytics.totalMoney)**"))
        #expect(share.plainText.contains("— Tailscode"))
    }

    @Test("The card is a brag poster, not the whole screen")
    func cardIsAPoster() throws {
        let analytics = try analytics()
        let share = AnalyticsShare(analytics, now: now, calendar: calendar)
        let kinds = share.card.blocks.map { block -> String in
            switch block {
            case .brand: return "brand"
            case .kicker: return "kicker"
            case .hero: return "hero"
            case .body: return "body"
            case .dim: return "dim"
            case .trend: return "trend"
            case .daily: return "daily"
            case .weekday: return "weekday"
            case .section: return "section"
            case .meter: return "meter"
            case .record: return "record"
            case .insight: return "insight"
            case .rule: return "rule"
            case .foot: return "foot"
            case .spacer: return "spacer"
            }
        }
        #expect(kinds.contains("brand"))
        #expect(kinds.contains("hero"))
        #expect(kinds.contains("daily"))
        #expect(kinds.contains("meter"))
        #expect(kinds.contains("record"))
        #expect(kinds.contains("foot"))
        #expect(!kinds.contains("where the money went"))
        let meters = share.card.blocks.compactMap { block -> AnalyticsShare.MeterBar? in
            if case .meter(let meter) = block { return meter }
            return nil
        }
        #expect(meters.count <= 12)
        #expect(meters.first?.hot == true)
    }

    @Test("A quiet ledger still shares, without empty charts")
    func quietLedger() throws {
        let analytics = try #require(
            UsageAnalytics(
                servers: [
                    (
                        "studio",
                        report(daily: [day(1, cost: 3, turns: 2)])
                    )
                ],
                now: now, calendar: calendar))
        let share = AnalyticsShare(analytics, now: now, calendar: calendar)
        #expect(share.card.blocks.contains { if case .hero = $0 { return true }; return false })
        #expect(share.plainText.contains(analytics.totalMoney))
        #expect(!share.filename.isEmpty)
    }

    @Test("The share palette never rides System's invisible colours")
    func paletteHasRealInk() {
        let palette = AnalyticsShare.Palette.shareDefault
        #expect(palette.canvas.hasPrefix("#"))
        #expect(palette.text != palette.canvas)
        #expect(Contrast.ratio(palette.text, on: palette.canvas) ?? 0 >= 4.5)
        #expect(Contrast.ratio(palette.accent, on: palette.canvas) ?? 0 >= 3.0)
    }
}
