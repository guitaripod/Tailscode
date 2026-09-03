import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quota board")
struct QuotaBoardTests {
    private func holding(_ provider: String, _ fraction: Double, balance: Bool = false)
        -> QuotaHolding
    {
        let gauge = UsageQuota.Gauge(
            key: "w", label: balance ? "Balance" : "Weekly", fraction: fraction, resetsAt: nil,
            trustedReset: false, usedUSD: balance ? 3 : nil, limitUSD: nil)
        return QuotaHolding(
            quota: UsageQuota(
                providerName: provider, subtitle: "", source: "test", live: true,
                gauges: [gauge], details: []),
            machines: ["arch"])
    }

    @Test("The default order is the catalog's, whatever the pressure")
    func catalogOrderHoldsStill() {
        let holdings = [holding("Grok", 0.9), holding("Claude", 0.1), holding("opencode", 0.5)]
        let arranged = QuotaBoard.arrange(holdings, preferences: .default)
        #expect(arranged.map(\.providerName) == ["Claude", "opencode", "Grok"])
        let hotter = [holding("Grok", 0.2), holding("Claude", 0.95), holding("opencode", 0.5)]
        #expect(
            QuotaBoard.arrange(hotter, preferences: .default).map(\.providerName)
                == ["Claude", "opencode", "Grok"], "a poll moved the cards")
    }

    @Test("Tightest first is a choice, and it does sort by pressure")
    func tightestFirst() {
        let holdings = [holding("Grok", 0.9), holding("Claude", 0.1), holding("opencode", 0.5)]
        let prefs = QuotaBoardPreferences(arrangement: .tightestFirst)
        #expect(
            QuotaBoard.arrange(holdings, preferences: prefs).map(\.providerName)
                == ["Grok", "opencode", "Claude"])
        #expect(
            QuotaBoard.arrange(holdings, preferences: QuotaBoardPreferences(arrangement: .byName))
                .map(\.providerName) == ["Claude", "Grok", "opencode"])
    }

    @Test("A hidden provider leaves the board and the glance, and keeps its switch")
    func hiding() {
        let holdings = [holding("Grok", 0.9), holding("Claude", 0.1)]
        var prefs = QuotaBoardPreferences()
        prefs.setHidden("grok", true)
        #expect(QuotaBoard.arrange(holdings, preferences: prefs).map(\.providerName) == ["Claude"])
        let choices = QuotaBoard.choices(holdings: holdings, preferences: prefs)
        #expect(choices.map(\.key) == ["claude", "grok"])
        #expect(choices[1].isHidden)
        let glance = QuotaGlance.make(
            from: [("arch", holdings[0].quota), ("arch", holdings[1].quota)], answeredAt: Date(),
            board: prefs)
        #expect(!glance.lines.contains { $0.slug == "grok" })
        #expect(glance.lines.contains { $0.slug == "claude" })
    }

    @Test("Moving a card makes the order the person's")
    func moving() {
        let holdings = [holding("Claude", 0.1), holding("opencode", 0.5), holding("Grok", 0.9)]
        var prefs = QuotaBoardPreferences(arrangement: .tightestFirst)
        prefs.move("grok", by: -2, among: holdings.map(QuotaBoard.key))
        #expect(prefs.arrangement == .custom)
        #expect(
            QuotaBoard.arrange(holdings, preferences: prefs).map(\.providerName)
                == ["Grok", "Claude", "opencode"])
        prefs.move("grok", by: -1, among: holdings.map(QuotaBoard.key))
        #expect(prefs.order.first == "grok", "moving past the front is a no-op")
        prefs.move("claude", by: 5, among: holdings.map(QuotaBoard.key))
        #expect(
            QuotaBoard.arrange(holdings, preferences: prefs).map(\.providerName)
                == ["Grok", "opencode", "Claude"])
    }

    @Test("An offer without a reading is a switch too, placed by the catalog")
    func offers() {
        let holdings = [holding("Claude", 0.1)]
        let choices = QuotaBoard.choices(
            holdings: holdings, offers: [QuotaBoard.Offer(key: "deepseek", name: "DeepSeek")],
            preferences: .default)
        #expect(choices.map(\.key) == ["claude", "deepseek"])
        #expect(!choices[1].isReported)
        var prefs = QuotaBoardPreferences()
        prefs.setHidden("deepseek", true)
        #expect(!QuotaBoard.shows(QuotaBoard.Offer(key: "deepseek", name: "DeepSeek"), preferences: prefs))
    }

    @Test("The lead is the tightest visible window, never a balance with money in it")
    func lead() {
        let holdings = [
            holding("Claude", 0.4), holding("Grok", 0.9), holding("DeepSeek", 0.0, balance: true),
        ]
        var prefs = QuotaBoardPreferences()
        #expect(QuotaBoard.lead(holdings, preferences: prefs)?.holding.providerName == "Grok")
        prefs.setHidden("grok", true)
        let visible = QuotaBoard.arrange(holdings, preferences: prefs)
        #expect(QuotaBoard.lead(visible, preferences: prefs)?.holding.providerName == "Claude")
        let empty = [holding("Claude", 0.4), holding("DeepSeek", 1.0, balance: true)]
        #expect(QuotaBoard.lead(empty, preferences: prefs)?.holding.providerName == "DeepSeek")
        prefs.leadsWithTightest = false
        #expect(QuotaBoard.lead(holdings, preferences: prefs) == nil)
    }

    @Test("Preferences round-trip through the store and the default clears it")
    func store() {
        let key = QuotaBoardStore.defaultsKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        QuotaBoardStore.update { $0.setHidden("grok", true); $0.arrangement = .byName }
        #expect(QuotaBoardStore.current.isHidden("grok"))
        #expect(QuotaBoardStore.current.arrangement == .byName)
        QuotaBoardStore.save(.default)
        #expect(UserDefaults.standard.data(forKey: key) == nil)
    }
}
