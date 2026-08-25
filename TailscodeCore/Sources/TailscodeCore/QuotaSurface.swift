import CodingAgentKit
import Foundation

/// A provider window that has nothing left to spend — the fact a person can act on: switch
/// model, wait for the reset, or open usage. Built from live gauges when we have them, and from
/// a failure string when the turn died of a rate limit before a gauge refreshed.
public struct QuotaExhaustion: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case gauge
        case failure
    }

    public let provider: String
    public let window: String
    public let fraction: Double
    public let resetsAt: Date?
    public let trustedReset: Bool
    public let source: Source
    /// Which models this wall is actually in front of.
    public let scope: QuotaScope

    public init(
        provider: String, window: String, fraction: Double, resetsAt: Date?,
        trustedReset: Bool, source: Source, scope: QuotaScope = .account
    ) {
        self.provider = provider
        self.window = window
        self.fraction = fraction
        self.resetsAt = resetsAt
        self.trustedReset = trustedReset
        self.source = source
        self.scope = scope
    }

    /// True when this wall stops every model on the provider rather than the one it names — the
    /// difference between "pick something else" and "wait".
    public var isAccountWide: Bool { scope == .account }
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
        guard let families = quotaFamilies(for: backend) else { return quotas }
        return quotas.filter {
            guard let slug = ProviderBrand.slug($0.providerName) else { return false }
            return families.contains(slug)
        }
    }

    /// Which provider families a chat on this backend spends against. An opencode chat may send
    /// with a DeepSeek model billed out of a prepaid DeepSeek balance, or a Grok model through
    /// xAI OAuth, so those quotas stay in play there; a Claude Code chat spends only against
    /// Claude's. Billing then narrows to the door the model actually runs through — Go's wall is
    /// not news above a chat on the xAI key.
    private static func quotaFamilies(for backend: AgentType?) -> Set<String>? {
        switch backend {
        case .claudeCode: return ["claude"]
        case .openCode: return ["opencode", "deepseek", "grok"]
        case .omp: return []
        default: return nil
        }
    }

    /// A window at or past this fraction is treated as used up. Providers occasionally report
    /// slightly over 1.0 after an over-limit request; clamp presentation elsewhere.
    public static let exhaustedFloor: Double = 1.0

    /// The quotas whose provider actually bills the model a chat would send with — read from the
    /// model's own door (its provider id) with the family as fallback, by the same rule the
    /// chooser wears walls with. A wall that is not in front of the model this chat is on is a
    /// fact for the gauges, not a banner over the conversation.
    public static func billingQuotas(
        in quotas: [UsageQuota], selection: ModelSelection?, model: String? = nil,
        named name: String? = nil
    ) -> [UsageQuota] {
        quotas.filter { QuotaBinding.bills($0, selection: selection, model: model, named: name) }
    }

    /// Every exhausted window standing in front of `model` — account-wide walls always, and a
    /// model-scoped wall only when it is that model's. A model nobody named is answered by the
    /// account-wide walls alone, because a scoped wall attributed to a chat that may not be on
    /// that model is exactly the notice nobody can act on.
    ///
    /// A window whose own stated reset has already passed is not a wall, whatever fraction the last
    /// snapshot recorded. The reading is a photograph of a moment that has ended: the provider said
    /// when the window would open again, that time is behind us, and continuing to quote the
    /// photograph is how a spent window ends up telling somebody it is used up and resets in 0m.
    public static func walls(
        in quotas: [UsageQuota], model: String? = nil, named name: String? = nil,
        now: Date = Date()
    ) -> [QuotaExhaustion] {
        quotas.flatMap { quota in
            quota.gauges
                .filter { $0.fraction >= exhaustedFloor && ($0.resetsAt.map { $0 > now } ?? true) }
                .compactMap { gauge -> QuotaExhaustion? in
                    let scope = QuotaBinding.scope(of: gauge)
                    guard QuotaBinding.governs(scope, model: model, named: name) else { return nil }
                    return QuotaExhaustion(
                        provider: quota.providerName, window: gauge.label,
                        fraction: gauge.fraction, resetsAt: gauge.resetsAt,
                        trustedReset: gauge.trustedReset, source: .gauge, scope: scope)
                }
        }
    }

    /// The hottest exhausted window in the way of `model` — session over weekly over a
    /// model-specific window when several are full, because the tightest clock is the one that
    /// unlocks the next send.
    public static func hottestExhausted(
        in quotas: [UsageQuota], model: String? = nil, named name: String? = nil,
        now: Date = Date()
    ) -> QuotaExhaustion? {
        walls(in: quotas, model: model, named: name, now: now)
            .max(by: { a, b in
                if a.fraction != b.fraction { return a.fraction < b.fraction }
                let aReset = a.resetsAt?.timeIntervalSince1970 ?? .infinity
                let bReset = b.resetsAt?.timeIntervalSince1970 ?? .infinity
                return aReset > bReset
            })
    }

    /// Failures that carry a limit word and are not a wall: a reply that ran past its own output
    /// ceiling, a prompt that ran past the context window, an attachment too big to send.
    ///
    /// These are the shape of one turn, not the state of the month, and they are the reason this
    /// list exists rather than a longer needle list. Reading one as a wall costs twice: it invents
    /// a wall nobody hit, and it replaces the one sentence that says how to fix the turn — raise
    /// the ceiling, shorten the prompt — with an invitation to switch model and wait for a reset
    /// that is never coming. A limit the account can spend past by waiting is a wall; a limit that
    /// describes the request is not.
    private static let notWalls = [
        "output token", "output_token", "token maximum", "max_tokens", "maximum tokens",
        "context window", "context length", "context_length", "context limit",
        "prompt is too", "input is too", "too long", "too large",
    ]

    /// Whether a turn failure is the provider saying "no more", not a bug in our plumbing and not
    /// the turn describing its own size.
    public static func isQuotaFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        guard !notWalls.contains(where: { lower.contains($0) }) else { return false }
        let needles = [
            "rate limit", "rate_limit", "ratelimit",
            "usage limit", "usage_limit",
            "quota", "exceeded your",
            "too many requests", "429",
            "you've hit", "you have hit", "you've reached", "you have reached",
            "out of credits", "out of capacity", "capacity exceeded",
            "credit balance is too low", "insufficient",
            "spend limit", "billing limit", "limit reached",
            "throttl",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// The wall standing in front of this turn, or nil when nothing is.
    ///
    /// A failure string is a guess and the gauges are a measurement, so the measurement decides.
    /// The guess is only ever needed for the one case it was written for: the turn died of a wall
    /// the gauges have not caught up with yet. Where a provider is answering and reports room, the
    /// account demonstrably has room, and whatever killed the turn was something else — which is
    /// the whole difference between telling somebody to switch model and wait, and letting them
    /// read the sentence that actually says what went wrong.
    ///
    /// The measurement is asked of the provider the failure names, never of the account: a full
    /// Claude weekly is not the explanation for a turn that died on opencode-go, and a live
    /// opencode-go reading is not permission to dismiss Claude's wall.
    ///
    /// A turn that died of something else keeps its own sentence. A standing wall is an answer to
    /// *why the next send will not go*, never to *why this one failed*: a model the server does not
    /// have, a refused connection, a tool that exited non-zero are each the only thing worth reading
    /// on that screen, and covering one with a countdown belonging to a provider the turn never
    /// reached is how a person is sent to wait three hours for a wall that was never in their way.
    /// So a failure is answered only where it is itself a wall; the pre-emptive reading is what
    /// `failureMessage == nil` asks for, and nothing else may summon it.
    public static func resolve(
        failureMessage: String?, quotas: [UsageQuota], model: String? = nil,
        named name: String? = nil, selection: ModelSelection? = nil, now: Date = Date()
    ) -> QuotaExhaustion? {
        guard let message = failureMessage else {
            let billed = billingQuotas(in: quotas, selection: selection, model: model, named: name)
            return hottestExhausted(in: billed, model: model, named: name, now: now)
        }
        guard isQuotaFailure(message) else { return nil }
        let hint = providerHint(in: message)
        let attributed = hint.map { provider in
            quotas.filter { ProviderBrand.slug($0.providerName) == ProviderBrand.slug(provider) }
        } ?? billingQuotas(in: quotas, selection: selection, model: model, named: name)
        if let gauge = hottestExhausted(in: attributed, model: model, named: name, now: now) {
            return gauge
        }
        guard !attributed.contains(where: \.live) else { return nil }
        return QuotaExhaustion(
            provider: hint ?? Localized.text("Provider"),
            window: windowHint(in: message) ?? Localized.text("Usage"),
            fraction: 1, resetsAt: parsedReset(in: message, now: now), trustedReset: false,
            source: .failure)
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

    /// The note a spent model wears in a chooser. A wall the row is itself the subject of needs no
    /// gloss; an account-wide one names its window, because "used up" on every row in the list is
    /// only an answer if it says what ran out.
    public static func rowNote(_ exhaustion: QuotaExhaustion) -> String {
        let head =
            exhaustion.isAccountWide
            ? Localized.text("%@ used up", exhaustion.window) : Localized.text("Used up")
        guard let reset = resetPhrase(exhaustion) else { return head }
        return "\(head) · \(reset)"
    }

    /// The same note where there is only room for a pill: the state, and the clock that ends it.
    /// A countdown is legible without the verb; what ran out is not, so the window's name is the
    /// part that goes rather than the time.
    public static func rowMark(_ exhaustion: QuotaExhaustion) -> String {
        let head = Localized.text("Used up")
        guard let resetsAt = exhaustion.resetsAt else { return head }
        return "\(head) · \(countdown(to: resetsAt))"
    }

    /// Percent label for a gauge that is full: "Used up" rather than "100%", so a bar at the wall
    /// reads as a state, not a measurement.
    public static func amountLabel(fraction: Double, percentText: String) -> String {
        fraction >= exhaustedFloor ? Localized.text("Used up") : percentText
    }

    /// What a quota card's provenance badge says, one word on every client: an estimate names
    /// itself, a live reading names its source, and anything else is a cached snapshot.
    public static func badge(_ quota: UsageQuota) -> String {
        if quota.source.lowercased().contains("estimated") { return Localized.text("EST") }
        return quota.live ? Localized.text("LIVE") : Localized.text("CACHED")
    }

    public static func isExhausted(_ fraction: Double) -> Bool {
        fraction >= exhaustedFloor
    }

    /// The message StatusFacts should show for a failed turn when the failure is a quota wall.
    public static func statusFailureMessage(
        failure: String?, quotas: [UsageQuota], model: String? = nil, named name: String? = nil
    ) -> String? {
        guard let failure else { return nil }
        if let exhaustion = resolve(
            failureMessage: failure, quotas: quotas, model: model, named: name)
        {
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
        if lower.contains("deepseek") { return "DeepSeek" }
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
