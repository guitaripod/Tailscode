import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quota rollup")
struct QuotaRollupTests {
    private func gauge(
        _ key: String, _ label: String, _ fraction: Double, resetsIn: TimeInterval? = nil,
        trusted: Bool = false, used: Double? = nil, limit: Double? = nil,
        startsIn: TimeInterval? = nil
    ) -> UsageQuota.Gauge {
        UsageQuota.Gauge(
            key: key, label: label, fraction: fraction,
            resetsAt: resetsIn.map { Date().addingTimeInterval($0) }, trustedReset: trusted,
            usedUSD: used, limitUSD: limit,
            startsAt: startsIn.map { Date().addingTimeInterval($0) })
    }

    private func quota(
        _ provider: String, _ gauges: [UsageQuota.Gauge], source: String = "bridge",
        live: Bool = true, subtitle: String = "", details: [UsageQuota.Detail] = [],
        error: String? = nil, errorCode: String? = nil, accountID: String? = nil
    ) -> UsageQuota {
        UsageQuota(
            providerName: provider, subtitle: subtitle, source: source, live: live,
            gauges: gauges, details: details, error: error, errorCode: errorCode,
            accountID: accountID)
    }

    @Test("An account nobody could read keeps the reason it could not be read")
    func keepsFailure() {
        let holdings = QuotaRollup.account(from: [
            (
                "arch",
                quota(
                    "opencode go", [], source: "opencode.ai console", live: false,
                    error: "opencode.ai returned 401")
            ),
            (
                "macbook",
                quota(
                    "opencode go", [], source: "opencode.ai console", live: false,
                    error: "opencode.ai returned 503")
            ),
        ])
        #expect(holdings.count == 1)
        #expect(holdings[0].quota.error == "opencode.ai returned 401")
    }

    @Test("Two accounts of one provider are two holdings")
    func separatesAccounts() {
        let holdings = QuotaRollup.account(from: [
            ("arch", quota("opencode go", [gauge("weekly", "Weekly", 0.1)], accountID: "acc_a")),
            ("macbook", quota("opencode go", [gauge("weekly", "Weekly", 0.2)], accountID: "acc_b")),
        ])
        #expect(holdings.count == 2)
        #expect(Set(holdings.compactMap(\.accountID)) == Set(["acc_a", "acc_b"]))
    }

    @Test("A failed machine joins the only account its provider has, and is not provenance for the live card")
    func failureJoinsTheOnlyAccount() {
        let holdings = QuotaRollup.account(from: [
            (
                "macbook",
                quota(
                    "opencode go", [], source: "opencode.ai console", live: false,
                    error: "401", errorCode: "key_expired")
            ),
            (
                "arch",
                quota(
                    "opencode go",
                    [gauge("weekly", "Weekly", 0.2)],
                    source: "opencode.ai console · live", accountID: "acc_a")
            ),
        ])
        #expect(holdings.count == 1)
        #expect(holdings[0].accountID == "acc_a")
        #expect(holdings[0].machines == ["arch"])
        #expect(holdings[0].failedMachines == ["macbook"])
        #expect(holdings[0].quota.error == "401")
        #expect(holdings[0].quota.errorCode == "key_expired")
    }

    @Test("The old rolling 5-hour window merges with the live five_hour one")
    func canonicalFiveHour() {
        let holdings = QuotaRollup.account(from: [
            (
                "macbook",
                quota(
                    "opencode go",
                    [gauge("rolling", "5-hour", 0.0)],
                    source: "estimated · opencode.db", live: false, accountID: "acc_a")
            ),
            (
                "arch",
                quota(
                    "opencode go",
                    [gauge("five_hour", "5-hour session", 0.11, startsIn: -7_200)],
                    source: "opencode.ai console · live", accountID: "acc_a")
            ),
        ])
        #expect(holdings.count == 1)
        #expect(holdings[0].gauges.count == 1)
        #expect(holdings[0].gauges[0].key == "five_hour")
        #expect(holdings[0].gauges[0].fraction == 0.11)
        #expect(holdings[0].gauges[0].startsAt != nil)
    }

    @Test("A window's stated start survives the fold from whichever machine said it")
    func keepsStartsAt() {
        let holdings = QuotaRollup.account(from: [
            ("macbook", quota("opencode go", [gauge("five_hour", "5-hour session", 0.1)])),
            (
                "arch",
                quota(
                    "opencode go",
                    [gauge("five_hour", "5-hour session", 0.2, startsIn: -7_200)])
            ),
        ])
        #expect(holdings[0].gauges[0].startsAt != nil)
    }

    @Test("A live reading from one machine keeps another's failure as a note, not as the card's state")
    func liveKeepsFailureAsNote() {
        let holdings = QuotaRollup.account(from: [
            (
                "arch",
                quota(
                    "opencode go", [], source: "opencode.ai console", live: false,
                    error: "opencode.ai returned 401")
            ),
            (
                "macbook",
                quota(
                    "opencode go",
                    [
                        gauge(
                            "five_hour", "5-hour session", 0.2, resetsIn: 3_600, trusted: true,
                            used: 2.4, limit: 12)
                    ])
            ),
        ])
        #expect(holdings.count == 1)
        #expect(holdings[0].quota.live)
        #expect(holdings[0].quota.error == "opencode.ai returned 401")
        #expect(holdings[0].machines == ["macbook"])
        #expect(holdings[0].failedMachines == ["arch"])
        #expect(holdings[0].gauges.count == 1)
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
