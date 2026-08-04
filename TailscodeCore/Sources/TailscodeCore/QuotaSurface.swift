import CodingAgentKit
import Foundation

/// A provider window that has nothing left to spend — the fact a person can act on: switch
/// model, wait for the reset, or open usage. Built from live gauges when we have them, and from
/// a failure string when the turn died of a rate limit before a gauge refreshed.
public struct QuotaExhaustion: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case gauge
        case failure
    }

    public let provider: String
    public let window: String
    public let fraction: Double
    public let resetsAt: Date?
    public let trustedReset: Bool
    public let source: Source

    public init(
        provider: String, window: String, fraction: Double, resetsAt: Date?,
        trustedReset: Bool, source: Source
    ) {
        self.provider = provider
        self.window = window
        self.fraction = fraction
        self.resetsAt = resetsAt
        self.trustedReset = trustedReset
        self.source = source
    }
}

/// How the product talks about a used-up quota. Toolkit-free copy so every client says the same
/// thing whether the news arrives as a gauge at full or a raw rate-limit failure mid-turn.
public enum QuotaSurface {
    /// The provider family a chat is on. A pre-emptive wall only speaks in a chat whose provider
    /// it names — Claude's weekly is not news above an opencode composer. No backend known keeps
    /// every quota in play.
    public static func relevantQuotas(for backend: AgentType?, among quotas: [UsageQuota])
        -> [UsageQuota]
    {
        guard let family = quotaFamily(for: backend) else { return quotas }
        return quotas.filter { ProviderBrand.slug($0.providerName) == family }
    }

    private static func quotaFamily(for backend: AgentType?) -> String? {
        switch backend {
        case .claudeCode: return "claude"
        case .openCode: return "opencode"
        default: return nil
        }
    }

    /// A window at or past this fraction is treated as used up. Providers occasionally report
    /// slightly over 1.0 after an over-limit request; clamp presentation elsewhere.
    public static let exhaustedFloor: Double = 1.0

    /// The hottest exhausted window across every quota we know — session over weekly over a
    /// model-specific window when several are full, because the tightest clock is the one that
    /// unlocks the next send.
    public static func hottestExhausted(in quotas: [UsageQuota]) -> QuotaExhaustion? {
        quotas.flatMap { quota in
            quota.gauges
                .filter { $0.fraction >= exhaustedFloor }
                .map {
                    QuotaExhaustion(
                        provider: quota.providerName, window: $0.label, fraction: $0.fraction,
                        resetsAt: $0.resetsAt, trustedReset: $0.trustedReset, source: .gauge)
                }
        }
        .max(by: { a, b in
            if a.fraction != b.fraction { return a.fraction < b.fraction }
            let aReset = a.resetsAt?.timeIntervalSince1970 ?? .infinity
            let bReset = b.resetsAt?.timeIntervalSince1970 ?? .infinity
            return aReset > bReset
        })
    }

    /// Whether a turn failure is the provider saying "no more", not a bug in our plumbing.
    public static func isQuotaFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        let needles = [
            "rate limit", "rate_limit", "ratelimit",
            "usage limit", "usage_limit",
            "quota", "exceeded your", "exceeded the",
            "too many requests", "429",
            "you've hit", "you have hit", "you've reached", "you have reached",
            "out of credits", "out of capacity", "capacity exceeded",
            "spend limit", "billing limit", "limit reached",
            "throttl",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// Prefer the wall the failed turn itself hit, then live gauges for the window name and
    /// reset, and fall back to classifying the failure string alone. A failure that names its
    /// provider is the turn's own wall — a full gauge on some *other* provider (say Claude's
    /// weekly, while this turn died on opencode-go) must not rewrite it.
    public static func resolve(failureMessage: String?, quotas: [UsageQuota]) -> QuotaExhaustion? {
        if let message = failureMessage, isQuotaFailure(message) {
            let named = QuotaExhaustion(
                provider: providerHint(in: message) ?? Localized.text("Provider"),
                window: windowHint(in: message) ?? Localized.text("Usage"),
                fraction: 1, resetsAt: parsedReset(in: message), trustedReset: false,
                source: .failure)
            if providerHint(in: message) != nil {
                return named
            }
            if let gauge = hottestExhausted(in: quotas) { return gauge }
            return named
        }
        return hottestExhausted(in: quotas)
    }

    /// Banner / phase line: names what is used up.
    public static func headline(_ exhaustion: QuotaExhaustion) -> String {
        Localized.text("%@ %@ is used up", exhaustion.provider, exhaustion.window)
    }

    /// What to do next, including a reset when we know one.
    public static func detail(_ exhaustion: QuotaExhaustion) -> String {
        if let reset = resetPhrase(exhaustion) {
            return Localized.text(
                "%@ · switch model, or wait", reset)
        }
        return Localized.text("Switch model, or wait for the window to reset")
    }

    /// Status band / short notice: one line that fits next to other facts.
    public static func short(_ exhaustion: QuotaExhaustion) -> String {
        if let reset = resetPhrase(exhaustion) {
            return "\(exhaustion.provider) \(exhaustion.window) · \(reset)"
        }
        return Localized.text("%@ %@ used up", exhaustion.provider, exhaustion.window)
    }

    /// Banner body: headline facts plus the next step.
    public static func bannerBody(_ exhaustion: QuotaExhaustion) -> String {
        "\(headline(exhaustion)) · \(detail(exhaustion))"
    }

    public static func notificationTitle(_ exhaustion: QuotaExhaustion) -> String {
        headline(exhaustion)
    }

    public static func notificationBody(_ exhaustion: QuotaExhaustion) -> String {
        detail(exhaustion)
    }

    /// Percent label for a gauge that is full: "Used up" rather than "100%", so a bar at the wall
    /// reads as a state, not a measurement.
    public static func amountLabel(fraction: Double, percentText: String) -> String {
        fraction >= exhaustedFloor ? Localized.text("Used up") : percentText
    }

    public static func isExhausted(_ fraction: Double) -> Bool {
        fraction >= exhaustedFloor
    }

    /// The message StatusFacts should show for a failed turn when the failure is a quota wall.
    public static func statusFailureMessage(
        failure: String?, quotas: [UsageQuota]
    ) -> String? {
        guard let failure else { return nil }
        if let exhaustion = resolve(failureMessage: failure, quotas: quotas) {
            return short(exhaustion)
        }
        return failure
    }

    private static func resetPhrase(_ exhaustion: QuotaExhaustion) -> String? {
        guard let resetsAt = exhaustion.resetsAt else { return nil }
        let remaining = countdown(to: resetsAt)
        return exhaustion.trustedReset
            ? Localized.text("resets in %@", remaining)
            : Localized.text("resets in about %@", remaining)
    }

    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let minutes = Int(max(0, date.timeIntervalSince(now)) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    private static func providerHint(in message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("claude") || lower.contains("anthropic") { return "Claude" }
        if lower.contains("grok") || lower.contains("xai") { return "Grok" }
        if lower.contains("opencode") { return "OpenCode Go" }
        if lower.contains("openai") || lower.contains("gpt") { return "OpenAI" }
        if lower.contains("gemini") || lower.contains("google") { return "Gemini" }
        return nil
    }

    /// A quota wall's message often carries its own reset ("It will reset in 3 days 5 hours")
    /// even when no gauge has refreshed; turn that into a real countdown.
    static func parsedReset(in message: String, now: Date = Date()) -> Date? {
        let lower = message.lowercased()
        guard lower.range(of: "reset") != nil else { return nil }
        let patterns: [(pattern: String, multiplier: Double)] = [
            ("(\\d+(?:\\.\\d+)?)\\s*day", 86_400),
            ("(\\d+(?:\\.\\d+)?)\\s*hour", 3_600),
            ("(\\d+(?:\\.\\d+)?)\\s*minute", 60),
        ]
        var seconds: Double = 0
        let ns = lower as NSString
        for entry in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: entry.pattern),
                let match = regex.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
                match.numberOfRanges == 2,
                let value = Double(ns.substring(with: match.range(at: 1)))
            else { continue }
            seconds += value * entry.multiplier
        }
        guard seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    private static func windowHint(in message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("session") || lower.contains("5-hour") || lower.contains("5 hour usage")
        {
            return Localized.text("Session")
        }
        if lower.contains("week") { return Localized.text("Weekly") }
        if lower.contains("month") { return Localized.text("Monthly") }
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        return nil
    }
}
