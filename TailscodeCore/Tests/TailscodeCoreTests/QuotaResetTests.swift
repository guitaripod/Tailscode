import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quota reset and fold")
struct QuotaResetTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func weekly(
        _ fraction: Double, resetsIn: TimeInterval? = 4 * 86_400, trusted: Bool = true
    ) -> UsageQuota.Gauge {
        UsageQuota.Gauge(
            key: "weekly_all", label: "Weekly · all models", fraction: fraction,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, trustedReset: trusted)
    }

    private func claude(_ gauges: [UsageQuota.Gauge], live: Bool = true) -> UsageQuota {
        UsageQuota(
            providerName: "Claude", subtitle: "Max",
            source: live ? "api.anthropic.com · live" : "api.anthropic.com · cached", live: live,
            gauges: gauges, details: [])
    }

    private func folded(_ reports: [(String, UsageQuota)]) -> UsageQuota.Gauge? {
        QuotaRollup.account(from: reports, now: now).first?.quota.gauges.first
    }

    @Test("A window past its stated reset reads as reset, opened at that reset")
    func settlesAPassedReset() {
        let reset = now.addingTimeInterval(-30)
        let settled = QuotaReset.settled(weekly(1, resetsIn: -30), now: now)
        #expect(settled.fraction == 0)
        #expect(settled.resetsAt == nil)
        #expect(settled.startsAt == reset)
        #expect(QuotaReset.settled(weekly(0.4), now: now) == weekly(0.4))
    }

    @Test("A spend window resets its money; a balance has no window to reset")
    func settlesMoneyByKind() {
        let spend = UsageQuota.Gauge(
            key: "monthly", label: "Monthly", fraction: 1, resetsAt: now.addingTimeInterval(-1),
            trustedReset: true, usedUSD: 60, limitUSD: 60)
        let settled = QuotaReset.settled(spend, now: now)
        #expect(settled.usedUSD == 0)
        #expect(settled.fraction == 0)
        let balance = UsageQuota.Gauge(
            key: "balance", label: "Balance", fraction: 1, resetsAt: now.addingTimeInterval(-1),
            trustedReset: false, usedUSD: 0, limitUSD: nil)
        #expect(QuotaReset.settled(balance, now: now) == balance)
    }

    @Test("Every surface reads a reset week as open before any machine is asked again")
    func rollupSettlesBeforeFolding() {
        let gauge = folded([
            ("arch", claude([weekly(1, resetsIn: -60)])),
            ("macbook", claude([weekly(1, resetsIn: -60)])),
        ])
        #expect(gauge?.fraction == 0)
        #expect(QuotaSurface.windowAmount(gauge!) != Localized.text("Used up"))
    }

    @Test("A machine that has read the next window outranks one still holding the last")
    func laterWindowWins() {
        let gauge = folded([
            ("macbook", claude([weekly(1, resetsIn: -60)])),
            ("arch", claude([weekly(0.02, resetsIn: 7 * 86_400 - 60)])),
        ])
        #expect(gauge?.fraction == 0.02)
        #expect(gauge?.resetsAt == now.addingTimeInterval(7 * 86_400 - 60))

        let older = weekly(0.9, resetsIn: 2 * 3600)
        let newer = weekly(0.05, resetsIn: 7 * 86_400)
        #expect(QuotaRollup.fold(older, live: true, newer, live: true) == newer)
        #expect(QuotaRollup.fold(newer, live: true, older, live: true) == newer)
    }

    @Test("A live reading speaks over a machine's cached answer for the same window")
    func liveOutranksCached() {
        let gauge = folded([
            ("macbook", claude([weekly(1)], live: false)),
            ("arch", claude([weekly(0)])),
        ])
        #expect(gauge?.fraction == 0)
        let reversed = folded([
            ("arch", claude([weekly(0)])),
            ("macbook", claude([weekly(1)], live: false)),
        ])
        #expect(reversed?.fraction == 0)
    }

    @Test("A figure rounded up to the wall yields to the finer figure it rounds")
    func finerOutranksRounded() {
        let gauge = folded([
            ("macbook", claude([weekly(1)])),
            ("arch", claude([weekly(0.996)])),
        ])
        #expect(gauge?.fraction == 0.996)
        #expect(QuotaSurface.walls(in: [claude([gauge!])], now: now).isEmpty)
    }

    @Test("Two readings that are not one measurement still keep the larger")
    func strictestOtherwise() {
        #expect(
            folded([("arch", claude([weekly(0.99)])), ("macbook", claude([weekly(1)]))])?.fraction
                == 1)
        #expect(
            folded([("arch", claude([weekly(0.4)])), ("macbook", claude([weekly(0.45)]))])?.fraction
                == 0.45)
    }

    @Test("A refusal is not lifted by another machine's figure just short of the wall")
    func refusalOutranksFiner() {
        var refused = weekly(1)
        refused.refused = true
        var answering = weekly(0.999)
        answering.refused = false
        for reports in [
            [("arch", claude([refused])), ("macbook", claude([answering]))],
            [("macbook", claude([answering])), ("arch", claude([refused]))],
        ] {
            let gauge = folded(reports)
            #expect(gauge?.fraction == 1)
            #expect(gauge?.refused == true)
        }
        #expect(!QuotaSurface.walls(in: [claude([refused])], now: now).isEmpty)
    }

    @Test("Which window is live is decided by the reading that won it, in any order")
    func liveIsPerWindow() {
        let session = UsageQuota.Gauge(
            key: "session", label: "5-hour session", fraction: 0.2,
            resetsAt: now.addingTimeInterval(3600), trustedReset: true)
        let a = ("arch", claude([session]))
        let b = ("macbook", claude([weekly(0.9)], live: false))
        let c = ("mini", claude([weekly(1)], live: false))
        let orders = [[a, b, c], [a, c, b], [b, c, a], [c, a, b], [b, a, c], [c, b, a]]
        let weeks = orders.map { order in
            QuotaRollup.account(from: order, now: now).first?.quota.gauges
                .first { $0.key == "weekly_all" }?.fraction
        }
        #expect(weeks.allSatisfy { $0 == 1 })
    }

    @Test("A week read as reset yields to a measured reading of the week that opened")
    func placeholderYieldsToMeasurement() {
        let gauge = folded([
            ("arch", claude([weekly(1, resetsIn: -120)])),
            ("macbook", claude([weekly(0.04, resetsIn: 7 * 86_400 - 120)], live: false)),
        ])
        #expect(gauge?.fraction == 0.04)
        #expect(gauge?.resetsAt == now.addingTimeInterval(7 * 86_400 - 120))
        #expect(gauge.map(QuotaReset.isReopened) == false)
    }

    @Test("A failure's wall comes down once the week it named has reopened")
    func failureWallYieldsToReset() {
        let message = "You've hit your weekly limit · resets in 3 days"
        let reopened = QuotaReset.settled(claude([weekly(1, resetsIn: -60)], live: false), now: now)
        #expect(QuotaSurface.read(failure: message, quotas: [reopened], now: now) == .moved)
        let standing = claude([weekly(0.4)], live: false)
        if case .wall = QuotaSurface.read(failure: message, quotas: [standing], now: now) {
        } else {
            Issue.record("a cached reading that has not reset leaves the failure's wall standing")
        }
        let session = UsageQuota.Gauge(
            key: "session", label: "5-hour session", fraction: 1,
            resetsAt: now.addingTimeInterval(-60), trustedReset: true)
        let otherWindow = QuotaReset.settled(claude([session, weekly(0.4)], live: false), now: now)
        if case .wall = QuotaSurface.read(failure: message, quotas: [otherWindow], now: now) {
        } else {
            Issue.record("a session reopening says nothing about a week's refusal")
        }
    }

    @Test("A week read as reset carries no verdict from before it")
    func settleDropsTheVerdict() {
        var refused = weekly(1, resetsIn: -10)
        refused.refused = true
        #expect(QuotaReset.settled(refused, now: now).refused == nil)
    }

    @Test("The widget's stored week at its wall reads clear once its reset passes")
    func widgetSettles() {
        let stored = WidgetQuota(
            providerName: "Claude", subtitle: "Max", isLive: true,
            gauges: [
                WidgetQuota.Gauge(
                    label: "Weekly · all models", fraction: 1,
                    resetsAt: now.addingTimeInterval(-120), trustedReset: true)
            ],
            readAt: now.addingTimeInterval(-300))
        let glance = WidgetGlance.make(
            quotas: [stored], updatedAt: now.addingTimeInterval(-300), now: now)
        #expect(!glance.heroIsWalled)
        #expect(glance.headline == Localized.text("All clear"))
        #expect(glance.rows.allSatisfy { $0.value != Localized.text("Used up") })
    }
}
