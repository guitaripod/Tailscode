import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quota identity, failure and keeping")
struct QuotaKeepingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600

    private func gauge(
        _ label: String, _ fraction: Double, resetsIn: TimeInterval? = 7_200,
        trusted: Bool = true, startsIn: TimeInterval? = nil, key: String? = nil
    ) -> UsageQuota.Gauge {
        UsageQuota.Gauge(
            key: key ?? label.lowercased(), label: label, fraction: fraction,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, trustedReset: trusted,
            startsAt: startsIn.map { now.addingTimeInterval($0) })
    }

    private func quota(
        _ provider: String, _ gauges: [UsageQuota.Gauge], account: String? = nil,
        source: String = "bridge", live: Bool = true, error: String? = nil,
        code: String? = nil
    ) -> UsageQuota {
        UsageQuota(
            providerName: provider, subtitle: "", source: source, live: live, gauges: gauges,
            details: [], error: error, errorCode: code, accountID: account)
    }

    private func failure(
        _ provider: String, code: String = "unreachable", account: String? = nil
    ) -> UsageQuota {
        quota(
            provider, [], account: account, live: false, error: "could not read", code: code)
    }

    @Test("Two accounts of one provider are two lines on the strip, each its own window")
    func twoAccountsTwoLines() {
        let strip = QuotaGlance.make(
            from: [
                ("arch", quota("Claude", [gauge("Weekly", 0.2)], account: "a")),
                ("mini", quota("Claude", [gauge("Weekly", 0.7)], account: "b")),
            ], answeredAt: now, now: now)
        let lines = strip.lines.filter { $0.kind == .window }
        #expect(lines.count == 2)
        #expect(Set(lines.map(\.trailing)) == ["20%", "70%"])
    }

    @Test("A wall in one account does not close the provider's other account")
    func wallStaysWithItsAccount() {
        let strip = QuotaGlance.make(
            from: [
                ("arch", quota("Claude", [gauge("Weekly", 1.0)], account: "a")),
                ("mini", quota("Claude", [gauge("Weekly", 0.3)], account: "b")),
            ], answeredAt: now, now: now)
        let windows = strip.lines.filter { $0.kind == .window }
        #expect(windows.count == 2)
        #expect(windows.contains { $0.tone == .danger })
        #expect(windows.contains { $0.text.contains("still open") })
    }

    @Test("A holding's identity is its provider and its account")
    func identity() {
        let holdings = QuotaRollup.account(from: [
            ("arch", quota("Claude", [gauge("Weekly", 0.2)], account: "a")),
            ("mini", quota("Claude", [gauge("Weekly", 0.7)], account: "b")),
        ])
        #expect(Set(holdings.map(\.identity)).count == 2)
        #expect(QuotaBoard.keys(of: holdings) == ["claude"])
    }

    @Test("A failed read leaves the failure's account on the holding it joined")
    func failureCarriesTheOnlyAccount() {
        let holdings = QuotaRollup.account(from: [
            ("arch", quota("Claude", [gauge("Weekly", 0.2)], account: "a")),
            ("mini", failure("Claude")),
        ])
        #expect(holdings.count == 1)
        #expect(holdings[0].identity == QuotaRollup.identity(providerName: "Claude", accountID: "a"))
        #expect(holdings[0].quota.accountID == "a")
    }

    @Test("A start is taken only with the reset it belongs to")
    func startTravelsWithItsReset() {
        let old = quota("opencode go", [gauge("5-hour", 0.5, resetsIn: 3_600, trusted: false, key: "five_hour")])
        let stated = quota(
            "opencode go",
            [gauge("5-hour", 0.2, resetsIn: 7_200, trusted: true, startsIn: -3_600, key: "five_hour")])
        let holdings = QuotaRollup.account(from: [("old", old), ("new", stated)])
        let merged = holdings[0].gauges[0]
        #expect(merged.fraction == 0.5)
        #expect(merged.trustedReset)
        #expect(merged.resetsAt == now.addingTimeInterval(7_200))
        #expect(merged.startsAt == now.addingTimeInterval(-3_600))
    }

    @Test("A start from another window is not stitched onto the winner's own reset")
    func startIsNotStitched() {
        let winner = quota(
            "opencode go",
            [gauge("5-hour", 0.5, resetsIn: 3_600, trusted: true, key: "five_hour")])
        let other = quota(
            "opencode go",
            [gauge("5-hour", 0.2, resetsIn: 9_000, trusted: true, startsIn: -3_600, key: "five_hour")])
        let merged = QuotaRollup.account(from: [("a", winner), ("b", other)])[0].gauges[0]
        #expect(merged.resetsAt == now.addingTimeInterval(3_600))
        #expect(merged.startsAt == nil)
    }

    @Test("A key that must be replaced outranks a machine that was merely unreachable, in either order")
    func failurePrecedence() {
        for reports in [
            [("a", failure("opencode go")), ("b", failure("opencode go", code: "key_expired"))],
            [("b", failure("opencode go", code: "key_expired")), ("a", failure("opencode go"))],
        ] {
            let holding = QuotaRollup.account(from: reports)[0]
            #expect(holding.quota.errorCode == "key_expired")
            #expect(holding.failedMachines.first == "b")
        }
    }

    @Test("A window with a guessed reset has no stated range")
    func windowLineNeedsATrustedReset() {
        let trusted = gauge("5-hour", 0.2, startsIn: -3_600)
        let guessed = gauge("5-hour", 0.2, trusted: false, startsIn: -3_600)
        #expect(QuotaSurface.windowLine(trusted, now: now)?.contains("→") == true)
        #expect(QuotaSurface.windowLine(guessed, now: now) == nil)
    }

    @Test("A window that already reset is not drawn as a range")
    func resetsIsQuietOnceOver() {
        let over = gauge("5-hour", 0.2, resetsIn: -60, startsIn: -3_600 * 6)
        #expect(RangeWords.resets(over, now: now) == "")
    }

    @Test("A window with a stated start is drawn flat wherever it is drawn")
    func statedWindowIsFlat() {
        let stated = gauge("5-hour", 0.5, resetsIn: 3 * hour, startsIn: -2 * hour)
        let inferred = gauge("5-hour", 0.5, resetsIn: 3 * hour)
        let flat = PaceRow.window(provider: "opencode go", slug: "opencode", gauge: stated, now: now)
        let drawn = PaceRow.window(provider: "opencode go", slug: "opencode", gauge: inferred, now: now)
        #expect(flat.tick == nil)
        #expect(flat.tailEnd == nil)
        #expect(drawn.tick != nil)
    }

    @Test("A full spend window reads Used up beside its bar, a part-spent one reads as money")
    func fullWindowReadsUsedUp() {
        func spend(_ fraction: Double, used: Double) -> UsageQuota.Gauge {
            UsageQuota.Gauge(
                key: "monthly", label: "Monthly", fraction: fraction, resetsAt: nil,
                trustedReset: false, usedUSD: used, limitUSD: 10)
        }
        #expect(QuotaSurface.windowAmount(spend(1, used: 10)) == "Used up")
        #expect(QuotaSurface.windowAmount(spend(0.4, used: 4)) == "$4.00 / $10.00")
        #expect(QuotaSurface.windowAmount(gauge("Weekly", 0.42)) == "42%")
        #expect(QuotaSurface.windowAmount(gauge("Weekly", 1.2)) == "Used up")
    }

    @Test("One predicate says whether a report is the account's own number")
    func measured() {
        #expect(quota("Claude", [gauge("Weekly", 0.2)]).isMeasured)
        #expect(!quota("opencode go", [gauge("Weekly", 0.2)], source: "estimated from sessions").isMeasured)
    }

    @Test("An estimate-only provider stays as a line that says there is no measured reading")
    func estimateIsNotSilent() {
        let estimate = quota(
            "opencode go", [gauge("Weekly", 0.2)], account: "a", source: "estimated (local db)")
        let admitted = QuotaReports.admitted(estimate)
        #expect(admitted.gauges.isEmpty)
        #expect(admitted.errorCode == "estimate_only")
        #expect(admitted.accountID == "a")
        let strip = QuotaGlance.make(from: [("arch", admitted)], answeredAt: now, now: now)
        #expect(strip.lines.contains { $0.text.contains("No measured reading") })
        #expect(QuotaReports.admitted(quota("Claude", [gauge("Weekly", 0.2)])).gauges.count == 1)
    }

    @Test("A measured reading from another machine outranks the estimate that came with it")
    func measuredBeatsEstimatePlaceholder() {
        let holdings = QuotaRollup.account(from: [
            ("arch", QuotaReports.admitted(quota("opencode go", [gauge("Weekly", 0.9)], source: "estimated"))),
            ("mini", quota("opencode go", [gauge("Weekly", 0.3)])),
        ])
        #expect(holdings.count == 1)
        #expect(holdings[0].gauges[0].fraction == 0.3)
    }

    @Test("One staleness constant answers for the strip, the widget and the store")
    func oneStaleness() {
        let strip = QuotaGlance.make(
            from: [("arch", quota("Claude", [gauge("Weekly", 0.2)]))],
            answeredAt: now.addingTimeInterval(-QuotaFreshness.staleAfter), now: now)
        #expect(strip.lines.contains { $0.text.hasPrefix("Last read") })
        let fresh = QuotaGlance.make(
            from: [("arch", quota("Claude", [gauge("Weekly", 0.2)]))],
            answeredAt: now.addingTimeInterval(-QuotaFreshness.staleAfter + 1), now: now)
        #expect(!fresh.lines.contains { $0.text.hasPrefix("Last read") })
        let widget = WidgetGlance.make(
            quotas: [WidgetQuota(providerName: "Claude", subtitle: "", isLive: true, gauges: [WidgetQuota.Gauge(label: "Weekly", fraction: 0.2)])],
            updatedAt: now.addingTimeInterval(-QuotaFreshness.staleAfter), now: now)
        #expect(widget.freshness.isStale)
    }

    @Test("A provider whose last read failed is cached in the widget even while another is fresh")
    func widgetCachesPerProvider() {
        let wide = WidgetQuota.Gauge(label: "Weekly", fraction: 0.2)
        let glance = WidgetGlance.make(
            quotas: [
                WidgetQuota(providerName: "Claude", subtitle: "", isLive: true, gauges: [wide], readAt: now),
                WidgetQuota(
                    providerName: "Grok", subtitle: "", isLive: true, gauges: [wide],
                    readAt: now.addingTimeInterval(-2 * hour)),
            ], updatedAt: now, now: now)
        let byName = Dictionary(uniqueKeysWithValues: glance.providers.map { ($0.name, $0.isLive) })
        #expect(byName["Claude"] == true)
        #expect(byName["Grok"] == false)
    }

    @Test("A failed read is kept, not written, until the last good one is a day old")
    func keepingMoves() {
        let good = quota("Claude", [gauge("Weekly", 0.2)])
        #expect(QuotaKeeping.move(for: good, heldAt: nil, now: now) == .write)
        let bad = failure("Claude")
        #expect(QuotaKeeping.move(for: bad, heldAt: now.addingTimeInterval(-hour), now: now) == .keep)
        #expect(QuotaKeeping.move(for: bad, heldAt: nil, now: now) == .keep)
        #expect(
            QuotaKeeping.move(
                for: bad, heldAt: now.addingTimeInterval(-QuotaFreshness.keptFor), now: now) == .drop)
        #expect(
            QuotaKeeping.move(for: QuotaReports.admitted(quota("x", [gauge("Weekly", 0.2)], source: "estimated")), heldAt: now.addingTimeInterval(-hour), now: now) == .keep)
    }

    @Test("A failed read serves the last good numbers, marked cached, and only for that account")
    func carryServesCached() {
        let good = quota("Claude", [gauge("Weekly", 0.4)], account: "a")
        let held = QuotaKeeping.remember([("arch", good)], into: [], now: now.addingTimeInterval(-hour))
        let served = QuotaKeeping.carry(
            [("arch", failure("Claude", account: "a"))], held: held, now: now)
        #expect(served[0].1.gauges.first?.fraction == 0.4)
        #expect(served[0].1.live == false)
        #expect(served[0].1.error == nil)
        let other = QuotaKeeping.carry(
            [("arch", failure("Claude", account: "b"))], held: held, now: now)
        #expect(other[0].1.gauges.isEmpty)
    }

    @Test("A key that expired is never masked by a cached number")
    func definitiveFailuresShow() {
        let good = quota("opencode go", [gauge("Weekly", 0.4)])
        let held = QuotaKeeping.remember([("arch", good)], into: [], now: now)
        let served = QuotaKeeping.carry(
            [("arch", failure("opencode go", code: "key_expired"))], held: held, now: now)
        #expect(served[0].1.gauges.isEmpty)
        #expect(served[0].1.errorCode == "key_expired")
    }

    @Test("A cached reading never competes with a fresh one for the same account")
    func freshBeatsCached() {
        let held = QuotaKeeping.remember(
            [("arch", quota("Claude", [gauge("Weekly", 0.9)]))], into: [], now: now.addingTimeInterval(-hour))
        let served = QuotaKeeping.carry(
            [("arch", failure("Claude")), ("mini", quota("Claude", [gauge("Weekly", 0.1)]))],
            held: held, now: now)
        #expect(served[0].1.gauges.isEmpty)
    }

    @Test("A reading older than a day is not served")
    func tooOldIsNotServed() {
        let held = [
            HeldReading(
                server: "arch", quota: quota("Claude", [gauge("Weekly", 0.4)]),
                readAt: now.addingTimeInterval(-QuotaFreshness.keptFor - 1))
        ]
        let served = QuotaKeeping.carry([("arch", failure("Claude"))], held: held, now: now)
        #expect(served[0].1.gauges.isEmpty)
        #expect(QuotaKeeping.remember([], into: held, now: now).isEmpty)
    }

    @Test("Estimates are never remembered as readings")
    func estimatesAreNotRemembered() {
        let held = QuotaKeeping.remember(
            [("arch", QuotaReports.admitted(quota("opencode go", [gauge("Weekly", 0.4)], source: "estimated")))],
            into: [], now: now)
        #expect(held.isEmpty)
    }
}
