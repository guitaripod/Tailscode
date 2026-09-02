import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A reader picks how much time they are looking at; the grain follows from the span rather than
/// being a second question. Three hundred and sixty-five columns is not a chart, and seven columns
/// of one week each is not a week.
@Suite("Usage windows")
struct UsageWindowTests {
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

    private func analytics(_ window: UsageWindow, spend: [Int: Double] = [1: 40, 40: 25, 200: 10])
        -> UsageAnalytics?
    {
        let daily = spend.keys.sorted().map { daysAgo in
            UsageAnalyticsReport.Day(
                day: key(daysAgo: daysAgo), costUSD: spend[daysAgo] ?? 0,
                tokens: SessionSpendReport.Tokens(output: 10000), turns: 6, toolCalls: 20,
                sessions: 2)
        }
        let report = UsageAnalyticsReport(
            since: now.addingTimeInterval(-Double(window.days) * 86400), generatedAt: now,
            days: window.days,
            totals: UsageAnalyticsReport.Totals(
                costUSD: daily.reduce(0) { $0 + $1.costUSD },
                tokens: SessionSpendReport.Tokens(output: 10000 * daily.count),
                turns: 6 * daily.count, toolCalls: 20 * daily.count, sessions: 2 * daily.count,
                activeDays: daily.count),
            daily: daily,
            models: [
                SessionSpendReport.ModelShare(
                    model: "claude-opus-5", turns: 18,
                    tokens: SessionSpendReport.Tokens(output: 30000), costUSD: 75)
            ])
        return UsageAnalytics(
            servers: [("studio", report)], window: window, now: now, calendar: calendar)
    }

    @Test("Each window asks for its own span and says which it is showing")
    func spansAndLabels() throws {
        #expect(UsageWindow.week.days == 7)
        #expect(UsageWindow.month.days == 30)
        #expect(UsageWindow.quarter.days == 90)
        #expect(UsageWindow.year.days == 365)
        #expect(UsageWindow.allCases.count == 4)
        let quarter = try #require(analytics(.quarter))
        #expect(quarter.windowLabel == Localized.text("Last 90 days"))
        #expect(quarter.window == .quarter)
        let year = try #require(analytics(.year))
        #expect(year.windowLabel == Localized.text("Last 12 months"))
    }

    @Test("A short window is drawn a day at a time, a long one is not")
    func grainFollowsTheSpan() throws {
        #expect(try #require(analytics(.week)).days.count == 7)
        #expect(try #require(analytics(.month)).days.count == 30)
        let quarter = try #require(analytics(.quarter))
        #expect(quarter.days.count >= 13 && quarter.days.count <= 14)
        let year = try #require(analytics(.year))
        #expect(year.days.count >= 12 && year.days.count <= 13)
    }

    /// A column has to say what it is. Working that out from how many of them there are is not
    /// something a reader should have to do.
    @Test("A bar names itself as a day, a week or a month")
    func barsNameThemselves() throws {
        let month = try #require(analytics(.month))
        #expect(month.days.last?.title.contains(",") == false)
        #expect(month.days.last?.title.split(separator: " ").count == 3)
        let quarter = try #require(analytics(.quarter))
        #expect(quarter.days.contains { $0.title.contains("–") })
        let year = try #require(analytics(.year))
        #expect(year.days.contains { $0.title == "August" })
        #expect(year.days.last?.isToday == true)
    }

    /// The money is the same month however finely it is drawn — a grain that quietly dropped or
    /// double-counted a day would be a chart that disagrees with its own total.
    @Test("Regrouping the same ledger keeps every penny")
    func grainKeepsTheTotal() throws {
        let spend = [1: 40.0, 8: 25.0, 20: 10.0, 44: 5.0, 200: 7.0]
        for window in UsageWindow.allCases {
            let reading = try #require(analytics(window, spend: spend))
            let charted = reading.days.reduce(0) { $0 + $1.costUSD }
            let inWindow = spend.filter { $0.key < window.days }.values.reduce(0, +)
            #expect(abs(charted - inWindow) < 0.0001, "\(window) charted \(charted)")
        }
    }

    /// A quarter drawn as weekly columns still has a Tuesday in it: the week's rhythm is read off
    /// the days themselves, never off whichever weekday each bar happens to begin on.
    @Test("The week's rhythm survives a coarser chart")
    func weekdaysComeFromDaysNotBars() throws {
        let quarter = try #require(
            analytics(.quarter, spend: [1: 10, 2: 10, 3: 10, 30: 10, 31: 10, 60: 10]))
        #expect(quarter.weekdays.filter { $0.share > 0 }.count >= 3)
    }

    @Test("A trend is named in the days it actually compared")
    func trendNamesItsSpan() throws {
        let month = try #require(analytics(.month, spend: [1: 40, 20: 40]))
        #expect(month.deltaLine?.contains("7 days") == true)
        let year = try #require(analytics(.year, spend: [1: 40, 200: 40]))
        #expect(year.deltaLine?.contains("91 days") == true)
    }

    @Test("The chosen window is remembered, and nonsense falls back")
    func theChoiceIsRemembered() {
        let before = UserDefaults.standard.string(forKey: UsageWindow.storageKey)
        defer { UserDefaults.standard.set(before, forKey: UsageWindow.storageKey) }
        UsageWindow.current = .quarter
        #expect(UsageWindow.current == .quarter)
        UserDefaults.standard.set("fortnight", forKey: UsageWindow.storageKey)
        #expect(UsageWindow.current == .fallback)
        UserDefaults.standard.removeObject(forKey: UsageWindow.storageKey)
        #expect(UsageWindow.current == .month)
    }
}
