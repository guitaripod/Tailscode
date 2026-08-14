import Foundation
import Testing

@testable import TailscodeCore

@Suite("Widget glance")
struct WidgetGlanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func quota(
        _ provider: String, _ windows: [(String, Double)], live: Bool = true,
        resetsIn: TimeInterval? = 7_200
    ) -> WidgetQuota {
        WidgetQuota(
            providerName: provider, subtitle: "", isLive: live,
            gauges: windows.map {
                WidgetQuota.Gauge(
                    label: $0.0, fraction: $0.1,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) }, trustedReset: true)
            })
    }

    private func balance(_ total: Double, note: String = "Topped up $100.00") -> WidgetQuota {
        WidgetQuota(
            providerName: "DeepSeek", subtitle: "Prepaid balance", isLive: true,
            gauges: [
                WidgetQuota.Gauge(
                    label: "Balance", fraction: total > 0 ? 0 : 1, resetsAt: nil,
                    trustedReset: false, usedUSD: total, limitUSD: nil, currency: "USD",
                    note: note)
            ])
    }

    private func glance(
        _ quotas: [WidgetQuota], grouping: WidgetGrouping = .automatic,
        detail: WidgetDetail = .automatic, filter: Set<String>? = nil, age: TimeInterval = 0
    ) -> WidgetGlance {
        WidgetGlance.make(
            quotas: quotas, updatedAt: now.addingTimeInterval(-age), now: now,
            grouping: grouping, detail: detail, providerFilter: filter)
    }

    @Test("Money with no ceiling is a balance, not a bar at zero")
    func balanceIsNotAWindow() {
        let row = try! #require(glance([balance(104.32)]).rows.first)
        #expect(row.kind == .balance)
        #expect(row.fraction == nil)
        #expect(row.value == "$104.32")
        #expect(row.tone == .balance)
        #expect(row.caption == "Topped up $100.00")
    }

    @Test("An empty balance is a wall, and leads the reading")
    func emptyBalanceIsAWall() {
        let reading = glance([quota("Claude", [("5-hour", 0.2)]), balance(0)])
        let row = try! #require(reading.rows.first)
        #expect(row.kind == .balance)
        #expect(row.tone == .danger)
        #expect(row.value == "Empty")
        #expect(reading.verdict.contains("empty"))
    }

    @Test("A healthy balance sits under the windows rather than over them")
    func healthyBalanceRanksLast() {
        let reading = glance([balance(50), quota("Claude", [("5-hour", 0.1)])])
        #expect(reading.rows.last?.kind == .balance)
    }

    @Test("A full window reads as a state, and carries its own clock")
    func wallReadsAsAState() {
        let reading = glance([quota("Claude", [("Weekly", 1.0), ("5-hour", 0.4)])])
        let row = try! #require(reading.rows.first)
        #expect(row.value == "Used up")
        #expect(row.tone == .danger)
        #expect(reading.verdict.contains("used up"))
        #expect(reading.verdict.contains("2h 0m"))
    }

    @Test("A window whose stated reset has passed is not a wall")
    func spentWindowIsNotAWall() {
        let stale = WidgetQuota(
            providerName: "Claude", subtitle: "", isLive: true,
            gauges: [
                WidgetQuota.Gauge(
                    label: "Weekly", fraction: 1.0, resetsAt: now.addingTimeInterval(-60),
                    trustedReset: true)
            ])
        let row = try! #require(glance([stale]).rows.first)
        #expect(row.tone != .danger)
        #expect(row.resetsAt == nil)
    }

    @Test("Warm is attention, and only a wall spends the failure colour")
    func tonesFollowMeaning() {
        let rows = glance([quota("Claude", [("A", 0.2), ("B", 0.7), ("C", 0.9)])]).rows
        #expect(rows.first(where: { $0.label == "A" })?.tone == .ok)
        #expect(rows.first(where: { $0.label == "B" })?.tone == .warn)
        #expect(rows.first(where: { $0.label == "C" })?.tone == .warn)
        #expect(rows.first(where: { $0.label == "C" })?.isCritical == true)
        #expect(rows.first(where: { $0.label == "B" })?.isCritical == false)
    }

    @Test("One provider fills the widget with its windows; several share it a row each")
    func automaticGroupingFollowsTheAccount() {
        let single = glance([quota("Claude", [("5-hour", 0.5), ("Weekly", 0.3)])])
        #expect(single.rows.count == 2)
        #expect(single.title == "Claude")

        let several = glance([
            quota("Claude", [("5-hour", 0.5), ("Weekly", 0.3)]),
            quota("Grok", [("Chat", 0.8), ("Reasoning", 0.1)]),
        ])
        #expect(Array(several.rows.prefix(2)).map(\.providerShort) == ["Grok", "Claude"])
        #expect(several.title == "Usage")
    }

    @Test("Tightest-first ranks every window in the account, whoever meters it")
    func hottestGroupingIgnoresProviders() {
        let reading = glance(
            [
                quota("Claude", [("5-hour", 0.5), ("Weekly", 0.95)]),
                quota("Grok", [("Chat", 0.8)]),
            ], grouping: .hottest)
        #expect(reading.rows.map(\.label) == ["Weekly", "Chat", "5-hour"])
    }

    @Test("One-per-provider leads with a row each and keeps the rest behind them")
    func byProviderLeadsWithOneEach() {
        let reading = glance(
            [
                quota("Claude", [("5-hour", 0.5), ("Weekly", 0.95)]),
                quota("Grok", [("Chat", 0.8)]),
            ], grouping: .byProvider)
        #expect(Array(reading.rows.prefix(2)).map(\.providerShort) == ["Claude", "Grok"])
        #expect(reading.rows.count == 3)
    }

    @Test("A picked provider is the only one the widget shows")
    func filterKeepsOnlyWhatWasPicked() {
        let reading = glance(
            [quota("Claude Code", [("5-hour", 0.5)]), quota("Grok", [("Chat", 0.8)])],
            filter: ["claude"])
        #expect(reading.providers.map(\.short) == ["Claude"])
    }

    @Test("A server's own wording for a house we know still reads as that house")
    func brandSurvivesAServersWording() {
        #expect(WidgetGlance.key(for: "Claude Code") == "claude")
        #expect(WidgetGlance.key(for: "opencode go") == "opencode")
        #expect(ProviderBrand.short("Claude Code") == "Claude")
        #expect(ProviderBrand.short("Kimi") == "Kimi")
    }

    @Test("Compact spends no room on captions; detailed states money and reset")
    func detailDecidesTheSecondLine() {
        let spend = WidgetQuota(
            providerName: "opencode go", subtitle: "", isLive: true,
            gauges: [
                WidgetQuota.Gauge(
                    label: "5-hour", fraction: 0.28, resetsAt: now.addingTimeInterval(5_400),
                    trustedReset: true, usedUSD: 3.42, limitUSD: 12, currency: "USD")
            ])
        #expect(glance([spend], detail: .compact).rows[0].caption.isEmpty)
        let detailed = glance([spend], detail: .detailed).rows[0].caption
        #expect(detailed.contains("$3.42 / $12.00"))
        #expect(detailed.contains("resets 1h 30m"))
        /// The money on its own, for a surface that draws the clock itself and would otherwise
        /// state the reset twice.
        #expect(glance([spend], detail: .compact).rows[0].money == "$3.42 / $12.00")
        #expect(glance([balance(104.32)]).rows[0].money == "$104.32")
        #expect(glance([quota("Claude", [("Weekly", 0.3)])]).rows[0].money.isEmpty)
    }

    @Test("Every size gets rows it can hold, and says what it left out")
    func sizesTruncateOutLoud() {
        let reading = glance([quota("Claude", (1...6).map { ("W\($0)", Double($0) / 10) })])
        #expect(reading.rows(for: .small).count == 3)
        #expect(reading.rows(for: .circular).count == 1)
        #expect(reading.rows(for: .large).count == 6)
        #expect(reading.overflow(for: .small) == 3)
        #expect(reading.overflowLine(for: .small) == "+3 more")
        #expect(reading.overflowLine(for: .large) == nil)
    }

    @Test("A snapshot nobody could refresh says so before it says anything else")
    func stalenessLeads() {
        let fresh = glance([quota("Claude", [("5-hour", 0.4)])])
        #expect(fresh.freshness.isStale == false)
        #expect(fresh.freshness.badge == "LIVE")

        let old = glance([quota("Claude", [("5-hour", 0.4)])], age: 3_600)
        #expect(old.freshness.isStale)
        #expect(old.freshness.badge == "CACHED")
        #expect(old.freshness.note.contains("1h 0m"))
    }

    @Test("An estimate names itself rather than borrowing a live badge")
    func estimateNamesItself() {
        #expect(glance([quota("opencode go", [("Monthly", 0.2)], live: false)]).freshness.badge == "EST")
    }

    @Test("Nothing stored is a state with words, not an empty box")
    func emptyHasWords() {
        let reading = glance([])
        #expect(reading.isEmpty)
        #expect(reading.hero == nil)
        #expect(reading.verdict == WidgetGlance.emptyTitle)
        #expect(reading.spoken.contains(WidgetGlance.emptyDetail))
    }

    @Test("The inline accessory carries who, how full, and how long")
    func inlineSaysTheWholeThing() {
        let reading = glance([quota("Claude", [("5-hour", 0.47)])])
        #expect(reading.inlineText == "Claude 47% · 2h 0m")
    }

    @Test("A narrow column keeps a window's identity rather than cutting it in half")
    func shortLabelsKeepMeaning() {
        #expect(WidgetGlance.shortLabel("5-hour session") == "5-hour")
        #expect(WidgetGlance.shortLabel("Weekly") == "Weekly")
        #expect(WidgetGlance.shortLabel("Weekly · Opus") == "Weekly · Opus")
        #expect(WidgetGlance.shortLabel("Token input") == "Input")
        #expect(WidgetGlance.shortLabel("Wildcard window") == "Wildcard window")
    }

    @Test("A screen reader gets the row as a sentence")
    func rowsSpeak() {
        let reading = glance([quota("Claude", [("Weekly", 0.62)])])
        #expect(reading.rows[0].spoken == "Claude Weekly 62%, resets in 2h 0m")
        #expect(glance([balance(0)]).rows[0].spoken.contains("balance is empty"))
    }
}
