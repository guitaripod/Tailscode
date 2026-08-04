import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Quota surface")
struct QuotaSurfaceTests {
    private func gauge(
        label: String, fraction: Double, resetsIn: TimeInterval? = 3600, trusted: Bool = true
    ) -> UsageQuota.Gauge {
        UsageQuota.Gauge(
            key: label.lowercased(), label: label, fraction: fraction,
            resetsAt: resetsIn.map { Date().addingTimeInterval($0) }, trustedReset: trusted)
    }

    private func quota(
        _ provider: String, _ gauges: [UsageQuota.Gauge]
    ) -> UsageQuota {
        UsageQuota(
            providerName: provider, subtitle: "", source: "test", live: true, gauges: gauges,
            details: [])
    }

    @Test("A full window is exhausted; a partial one is not")
    func floor() {
        #expect(QuotaSurface.isExhausted(1.0))
        #expect(QuotaSurface.isExhausted(1.02))
        #expect(!QuotaSurface.isExhausted(0.99))
        #expect(
            QuotaSurface.amountLabel(fraction: 1.0, percentText: "100%")
                == Localized.text("Used up"))
        #expect(QuotaSurface.amountLabel(fraction: 0.62, percentText: "62%") == "62%")
    }

    @Test("The hottest full window wins, preferring the nearest reset")
    func hottest() {
        let quotas = [
            quota(
                "Claude",
                [
                    gauge(label: "Session", fraction: 1.0, resetsIn: 7200),
                    gauge(label: "Weekly", fraction: 1.0, resetsIn: 600),
                    gauge(label: "Opus", fraction: 0.4),
                ]),
            quota("Grok", [gauge(label: "Tokens", fraction: 0.9)]),
        ]
        let hit = QuotaSurface.hottestExhausted(in: quotas)
        #expect(hit?.provider == "Claude")
        #expect(hit?.window == "Weekly")
        #expect(hit?.source == .gauge)
    }

    @Test("Rate-limit failure language is classified; ordinary errors are not")
    func classify() {
        #expect(QuotaSurface.isQuotaFailure("Error: rate_limit exceeded for requests"))
        #expect(QuotaSurface.isQuotaFailure("HTTP 429 Too Many Requests"))
        #expect(QuotaSurface.isQuotaFailure("You've hit your usage limit"))
        #expect(!QuotaSurface.isQuotaFailure("connection refused"))
        #expect(!QuotaSurface.isQuotaFailure("tool bash failed with exit 1"))
    }

    @Test("A failure alone still produces an exhaustion, with gauge data preferred when present")
    func resolve() {
        let bare = QuotaSurface.resolve(
            failureMessage: "rate limit: you've hit your session cap", quotas: [])
        #expect(bare?.source == .failure)
        #expect(bare?.window == Localized.text("Session") || bare != nil)

        let withGauge = QuotaSurface.resolve(
            failureMessage: "429 too many requests",
            quotas: [quota("Claude", [gauge(label: "Session", fraction: 1.0, resetsIn: 1800)])])
        #expect(withGauge?.provider == "Claude")
        #expect(withGauge?.window == "Session")
        #expect(withGauge?.source == .gauge)
        #expect(withGauge?.resetsAt != nil)
    }

    @Test("Copy names the wall and the next step")
    func copy() {
        let e = QuotaExhaustion(
            provider: "Claude", window: "Session", fraction: 1.0,
            resetsAt: Date().addingTimeInterval(3600), trustedReset: true, source: .gauge)
        let head = QuotaSurface.headline(e)
        #expect(head.contains("Claude"))
        #expect(head.contains("Session"))
        let short = QuotaSurface.short(e)
        #expect(short.contains("Claude"))
        let body = QuotaSurface.detail(e)
        #expect(body.lowercased().contains("switch") || body.lowercased().contains("wait"))
    }

    @Test("Status failure message rewrites rate limits and leaves other failures alone")
    func statusFailure() {
        let rewritten = QuotaSurface.statusFailureMessage(
            failure: "rate_limit exceeded",
            quotas: [quota("Claude", [gauge(label: "Weekly", fraction: 1.0, resetsIn: 400)])])
        #expect(rewritten?.contains("Claude") == true)
        #expect(rewritten?.contains("Weekly") == true)

        let plain = QuotaSurface.statusFailureMessage(
            failure: "connection refused", quotas: [])
        #expect(plain == "connection refused")
    }

    @Test("An opencode retry message names the provider, window, and reset countdown")
    func opencodeRetryMessage() {
        let message =
            "monthly usage limit reached. It will reset in 3 days 5 hours. To continue using "
            + "this model now, enable usage from your available balance - "
            + "https://opencode.ai/workspace/wrk_01KWZ4MWEY0CDNAK0WMP4VRH7Q/go"
        let e = QuotaSurface.resolve(failureMessage: message, quotas: [])
        #expect(e?.provider == "OpenCode Go")
        #expect(e?.window == Localized.text("Monthly"))
        #expect(e?.source == .failure)
        #expect(e?.resetsAt != nil)
        let remaining = e!.resetsAt!.timeIntervalSinceNow
        let target: TimeInterval = 3 * 86_400 + 5 * 3_600
        #expect(abs(remaining - target) < 60)
    }

    @Test("A reset is only read from a message that speaks of one")
    func parsedReset() {
        #expect(QuotaSurface.parsedReset(in: "resets in 45 minutes") != nil)
        #expect(QuotaSurface.parsedReset(in: "it will reset in 2 hours") != nil)
        #expect(QuotaSurface.parsedReset(in: "try again later") == nil)
    }
}
