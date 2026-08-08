import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quota rollup")
struct QuotaRollupTests {
    private func gauge(
        _ key: String, _ label: String, _ fraction: Double, resetsIn: TimeInterval? = nil,
        trusted: Bool = false, used: Double? = nil, limit: Double? = nil
    ) -> UsageQuota.Gauge {
        UsageQuota.Gauge(
            key: key, label: label, fraction: fraction,
            resetsAt: resetsIn.map { Date().addingTimeInterval($0) }, trustedReset: trusted,
            usedUSD: used, limitUSD: limit)
    }

    private func quota(
        _ provider: String, _ gauges: [UsageQuota.Gauge], source: String = "bridge",
        live: Bool = true, subtitle: String = "", details: [UsageQuota.Detail] = []
    ) -> UsageQuota {
        UsageQuota(
            providerName: provider, subtitle: subtitle, source: source, live: live,
            gauges: gauges, details: details)
    }

    @Test("Two servers on one account become one holding")
    func mergesServers() {
        let holdings = QuotaRollup.account(from: [
            ("macbook", quota("Claude", [gauge("session", "5-hour session", 0.08)])),
            ("desktop", quota("Claude", [gauge("session", "5-hour session", 0.21)])),
        ])
        #expect(holdings.count == 1)
        #expect(holdings[0].machines == ["macbook", "desktop"])
        #expect(holdings[0].gauges.count == 1)
        #expect(holdings[0].gauges[0].fraction == 0.21)
    }

    @Test("A provider named differently by two servers is still one account")
    func mergesBrandAliases() {
        let holdings = QuotaRollup.account(from: [
            ("macbook", quota("Anthropic", [gauge("week", "Weekly", 0.3)])),
            ("desktop", quota("Claude", [gauge("week", "Weekly", 0.5)])),
        ])
        #expect(holdings.count == 1)
        #expect(holdings[0].gauges[0].fraction == 0.5)
    }

    @Test("Different providers stay apart, tightest first")
    func ordersByPressure() {
        let holdings = QuotaRollup.account(from: [
            ("macbook", quota("Grok", [gauge("month", "Monthly spend", 0.18)])),
            ("macbook", quota("Claude", [gauge("week", "Weekly", 0.5)])),
            ("macbook", quota("opencode", [gauge("month", "Monthly", 0.18)])),
        ])
        #expect(holdings.map(\.providerName) == ["Claude", "Grok", "opencode"])
    }

    @Test("Windows only one server knows are kept")
    func unionsWindows() {
        let holdings = QuotaRollup.account(from: [
            ("macbook", quota("Claude", [gauge("session", "5-hour session", 0.08)])),
            (
                "desktop",
                quota(
                    "Claude",
                    [gauge("session", "5-hour session", 0.05), gauge("week", "Weekly", 0.5)])
            ),
        ])
        #expect(holdings[0].gauges.map(\.key) == ["session", "week"])
        #expect(holdings[0].gauges[0].fraction == 0.08)
    }

    @Test("A stated reset beats a guessed one, and money survives the fold")
    func keepsBestFacts() {
        let holdings = QuotaRollup.account(from: [
            ("macbook", quota("Grok", [gauge("month", "Monthly spend", 0.4, used: 7, limit: 40)])),
            (
                "desktop",
                quota("Grok", [gauge("month", "Monthly spend", 0.2, resetsIn: 600, trusted: true)])
            ),
        ])
        let merged = holdings[0].gauges[0]
        #expect(merged.fraction == 0.4)
        #expect(merged.trustedReset)
        #expect(merged.resetsAt != nil)
        #expect(merged.usedUSD == 7)
        #expect(merged.limitUSD == 40)
    }

    @Test("A live report gives the card its identity over a cached one")
    func liveWins() {
        let holdings = QuotaRollup.account(from: [
            (
                "macbook",
                quota(
                    "Claude", [gauge("week", "Weekly", 0.1)], source: "estimated", live: false)
            ),
            (
                "desktop",
                quota(
                    "Claude", [gauge("week", "Weekly", 0.2)], source: "usage API", live: true,
                    subtitle: "Max")
            ),
        ])
        #expect(holdings[0].quota.live)
        #expect(holdings[0].quota.source == "usage API")
        #expect(holdings[0].quota.subtitle == "Max")
    }

    @Test("Provenance names machines only when more than one answered")
    func provenanceIsQuietForOneMachine() {
        let single = QuotaRollup.account(from: [
            ("macbook", quota("Claude", [gauge("week", "Weekly", 0.5)], source: "usage API"))
        ])
        #expect(QuotaRollup.provenance(single[0]) == "usage API")

        let shared = QuotaRollup.account(from: [
            ("macbook", quota("Claude", [gauge("week", "Weekly", 0.5)], source: "usage API")),
            ("desktop", quota("Claude", [gauge("week", "Weekly", 0.6)], source: "usage API")),
        ])
        #expect(QuotaRollup.provenance(shared[0]) == "usage API · macbook, desktop")
    }

    @Test("The tightest window is the account's, across providers")
    func tightestAcrossProviders() {
        let holdings = QuotaRollup.account(from: [
            ("macbook", quota("Claude", [gauge("week", "Weekly", 0.5)])),
            ("macbook", quota("Grok", [gauge("month", "Monthly spend", 0.91)])),
        ])
        let pick = QuotaRollup.tightest(in: holdings)
        #expect(pick?.holding.providerName == "Grok")
        #expect(pick?.gauge.fraction == 0.91)
    }

    @Test("The same machine reporting twice is not two machines")
    func dedupesReporters() {
        let holdings = QuotaRollup.account(from: [
            ("macbook", quota("Claude", [gauge("session", "5-hour session", 0.1)])),
            ("macbook", quota("Claude", [gauge("week", "Weekly", 0.4)])),
        ])
        #expect(holdings[0].machines == ["macbook"])
        #expect(!holdings[0].isShared)
        #expect(holdings[0].gauges.count == 2)
    }
}
