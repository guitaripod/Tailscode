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

    @Test("A named-provider failure wins over a full gauge on another provider")
    func namedFailureBeatsOtherGauge() {
        let message =
            "monthly usage limit reached. It will reset in 3 days 5 hours. "
            + "https://opencode.ai/workspace/wrk_01KWZ4MWEY0CDNAK0WMP4VRH7Q/go"
        let e = QuotaSurface.resolve(
            failureMessage: message,
            quotas: [quota("Claude", [gauge(label: "Weekly", fraction: 1.0, resetsIn: 600)])])
        #expect(e?.provider == "OpenCode Go")
        #expect(e?.window == Localized.text("Monthly"))
        #expect(e?.source == .failure)
    }

    @Test("A pre-emptive notice only speaks for the chat's own provider family")
    func familyScope() {
        let all = [
            quota("Claude", [gauge(label: "Weekly", fraction: 1.0, resetsIn: 600)]),
            quota("opencode", [gauge(label: "Monthly", fraction: 0.4)]),
        ]
        let opencodeChat = QuotaSurface.relevantQuotas(for: .openCode, among: all)
        #expect(opencodeChat.count == 1)
        #expect(opencodeChat[0].providerName == "opencode")
        #expect(
            QuotaSurface.hottestExhausted(
                in: QuotaSurface.relevantQuotas(for: .openCode, among: all)) == nil)
        let claudeChat = QuotaSurface.relevantQuotas(for: .claudeCode, among: all)
        #expect(claudeChat.count == 1)
        #expect(claudeChat[0].providerName == "Claude")
        #expect(QuotaSurface.hottestExhausted(in: claudeChat)?.window == "Weekly")
        #expect(QuotaSurface.relevantQuotas(for: nil, among: all).count == 2)
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

    @Test("A failure that is not a wall keeps its own words, whatever else is used up")
    func otherFailureOutranksAStandingWall() {
        let spent = [quota("opencode go", [gauge(label: "Monthly", fraction: 1.0, resetsIn: 9000)])]
        let message = "Model not found: ollama/qwen3.5:4b-q8_0. Did you mean: qwen3.8:4b-q8_0?"
        #expect(QuotaSurface.resolve(failureMessage: message, quotas: spent) == nil)
        #expect(
            QuotaSurface.statusFailureMessage(failure: message, quotas: spent) == message,
            "a countdown belonging to a provider this turn never reached is not the reason it died")
        #expect(QuotaSurface.resolve(failureMessage: "connection refused", quotas: spent) == nil)
        #expect(
            QuotaSurface.resolve(failureMessage: nil, quotas: spent)?.window == "Monthly",
            "and the pre-emptive reading is still there for the send that has not happened yet")
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

/// The wall the app kept inventing: a turn that died of something with a limit word in it, over an
/// account with nothing spent.
@Suite("Quota walls answer to the gauges")
struct QuotaEvidenceTests {
    private func gauge(
        _ label: String, _ fraction: Double, resetsIn: TimeInterval? = 3600
    ) -> UsageQuota.Gauge {
        UsageQuota.Gauge(
            key: label.lowercased(), label: label, fraction: fraction,
            resetsAt: resetsIn.map { Date().addingTimeInterval($0) }, trustedReset: true)
    }

    private func quota(
        _ provider: String, _ gauges: [UsageQuota.Gauge], live: Bool = true
    ) -> UsageQuota {
        UsageQuota(
            providerName: provider, subtitle: "", source: "test", live: live, gauges: gauges,
            details: [])
    }

    private var roomy: [UsageQuota] {
        [quota("Claude", [gauge("5-hour session", 0.15), gauge("Weekly · all models", 0.07)])]
    }

    @Test("A reply that ran past its own output ceiling is not a wall")
    func outputCeilingIsNotAWall() {
        let message = """
            API Error: Claude's response exceeded the 32000 output token maximum. To configure this \
            behavior, set the CLAUDE_CODE_MAX_OUTPUT_TOKENS environment variable.
            """
        #expect(!QuotaSurface.isQuotaFailure(message))
        #expect(QuotaSurface.resolve(failureMessage: message, quotas: roomy) == nil)
        #expect(
            QuotaSurface.statusFailureMessage(failure: message, quotas: roomy) == message,
            "the sentence that says how to fix the turn must survive")
    }

    @Test("A prompt past the context window is not a wall either")
    func contextIsNotAWall() {
        for message in [
            "Prompt is too long: 210000 tokens > 200000 maximum context length",
            "Input is too large for the context window",
        ] {
            #expect(!QuotaSurface.isQuotaFailure(message), "\(message)")
        }
    }

    @Test("A provider that is answering and reports room vetoes a guessed wall")
    func liveRoomVetoesTheGuess() {
        let message = "429 rate limit from claude"
        #expect(QuotaSurface.isQuotaFailure(message))
        #expect(QuotaSurface.resolve(failureMessage: message, quotas: roomy) == nil)
    }

    @Test("With no live reading to contradict it, the failure still speaks")
    func noReadingKeepsTheGuess() {
        let message = "429 rate limit from claude"
        let dark = [quota("Claude", [], live: false)]
        let wall = QuotaSurface.resolve(failureMessage: message, quotas: dark)
        #expect(wall?.provider == "Claude")
        #expect(wall?.source == .failure)
        #expect(QuotaSurface.resolve(failureMessage: message, quotas: []) != nil)
    }

    @Test("A full window on another provider cannot explain this provider's failure")
    func anotherProvidersWallIsNotEvidence() {
        let quotas = [
            quota("Claude", [gauge("Weekly", 1.0)]),
            quota("Grok", [gauge("Tokens", 0.2)]),
        ]
        let wall = QuotaSurface.resolve(failureMessage: "grok is throttling you", quotas: quotas)
        #expect(wall == nil, "Grok is answering with room; Claude's wall is not Grok's")
    }

    @Test("A gauge that is genuinely full still speaks, and names its own window")
    func arealWallSurvives() {
        let quotas = [quota("Claude", [gauge("5-hour session", 1.0, resetsIn: 900)])]
        let wall = QuotaSurface.resolve(failureMessage: "usage limit reached", quotas: quotas)
        #expect(wall?.source == .gauge)
        #expect(wall?.window == "5-hour session")
    }

    @Test("A window whose reset has passed is not a wall, whatever the snapshot recorded")
    func aSpentWindowExpires() {
        let stale = [quota("Claude", [gauge("Weekly", 1.0, resetsIn: -60)])]
        #expect(QuotaSurface.walls(in: stale).isEmpty)
        #expect(QuotaSurface.hottestExhausted(in: stale) == nil)
        let standing = [quota("Claude", [gauge("Weekly", 1.0, resetsIn: 60)])]
        #expect(QuotaSurface.hottestExhausted(in: standing) != nil)
    }
}
