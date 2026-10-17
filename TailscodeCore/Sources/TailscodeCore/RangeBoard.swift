import CodingAgentKit
import Foundation

/// The windows that stand between a conversation's model and its next send: the ones a model's
/// provider bills, split by whether the window governs the model on the next send or another one
/// that is merely on the same provider.
enum RangeWindows {
    struct Window {
        let quota: UsageQuota
        let gauge: UsageQuota.Gauge
        let governs: Bool
    }

    static func read(
        quotas: [UsageQuota], model: String?, named name: String?, selection: ModelSelection?
    ) -> [Window] {
        QuotaSurface.billingQuotas(in: quotas, selection: selection, model: model, named: name)
            .flatMap { quota in
                quota.gauges.compactMap { gauge -> Window? in
                    guard gauge.usedUSD == nil || gauge.limitUSD != nil else { return nil }
                    return Window(
                        quota: quota, gauge: gauge,
                        governs: QuotaBinding.governs(gauge, model: model, named: name))
                }
            }
    }
}

/// What the conversation's chrome needs from the range, cheaply: whether the window will not last,
/// whether a quota window that governs this model will run out before it resets, and whether the
/// cache has gone cold. Read on every state a conversation emits, so nothing here costs the size
/// of the conversation.
public struct RangeGlance: Sendable, Equatable {
    public struct Wall: Sendable, Equatable {
        public let provider: String
        public let window: String
        public let wallAt: Date
        public let resetsAt: Date
        public let approximate: Bool
    }

    public let burn: ContextBurn?
    public let wall: Wall?
    public let cache: CacheWarmth?
    public let readAt: Date

    public static func read(
        messages: [ChatMessage], fill: ContextFill?, quotas: [UsageQuota], model: String?,
        named name: String? = nil, selection: ModelSelection? = nil, isRunning: Bool = false,
        trail: QuotaTrail? = nil, now: Date = Date(), calendar: Calendar = .current
    ) -> RangeGlance {
        var wall: Wall?
        let known = model != nil || selection != nil || name != nil
        for window in RangeWindows.read(
            quotas: quotas, model: model, named: name, selection: selection)
        where known && window.governs
        {
            guard
                let pace = QuotaPace.read(
                    window.gauge, provider: window.quota.providerName, now: now, trail: trail,
                    calendar: calendar),
                case .willRunOut(let at) = pace.verdict
            else { continue }
            if wall == nil || at < wall!.wallAt {
                wall = Wall(
                    provider: window.quota.providerName, window: window.gauge.label, wallAt: at,
                    resetsAt: pace.resetsAt, approximate: pace.approximate)
            }
        }
        return RangeGlance(
            burn: fill.flatMap { ContextBurn.read(messages: messages, fill: $0) }, wall: wall,
            cache: CacheWarmth.read(messages: messages, isRunning: isRunning, now: now),
            readAt: now)
    }

    /// What the context chip says in place of its share, when the pace has made it news.
    public var contextWords: String? {
        guard let burn, burn.isNews, let turnsLeft = burn.turnsLeft else { return nil }
        return RangeWords.turnsChip(turnsLeft)
    }

    public func wallWords(clock: RangeClock = .current) -> String? {
        wall.map { RangeWords.wallChip($0.wallAt, now: readAt, clock: clock) }
    }

    public var coldWords: String? {
        guard let cache, cache.coldIsNews else { return nil }
        return Localized.text("Cache cold")
    }
}

/// The cache as one row of the sheet: a countdown while it is warm, a sentence only once the
/// sentence is owed.
public struct CacheRow: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let trailing: String
    public let fractionLeft: Double
    public let isCold: Bool
    public let sentence: String?

    init(_ cache: CacheWarmth) {
        isCold = cache.isCold
        fractionLeft = cache.fractionLeft
        switch cache.state {
        case .warm(let remaining):
            title = Localized.text("Warm")
            detail = Localized.text("the next send reads it from the cache")
            trailing = QuotaGlance.ageWords(remaining)
        case .cold(let span):
            title = Localized.text("Cold")
            detail = Localized.text("the next send reads everything again")
            trailing = Localized.text("%@ ago", QuotaGlance.ageWords(span))
        }
        sentence =
            cache.needsWords
            ? (cache.isCold
                ? Localized.text(
                    "The next send re-reads all %@ tokens at full price instead of from the cache.",
                    StatusFacts.tokens(cache.tokens))
                : Localized.text(
                    "Past that, a send re-reads all %@ tokens at full price.",
                    StatusFacts.tokens(cache.tokens)))
            : nil
    }
}

/// The footprint after each turn, for the sheet's small chart: how the window has filled, where a
/// compaction emptied it, and where the next turns would take it at the recent pace.
public struct RangeFootprint: Sendable, Equatable {
    public struct Bar: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case turn
            case refill
            case projected
        }

        public let kind: Kind
        /// `0...1` of the window, or of the fullest turn when the window is not known.
        public let height: Double
    }

    public let bars: [Bar]
    /// Where the danger line sits on the same scale, when the window is known.
    public let dangerLine: Double?

    private static let widest = 40
    private static let projectedTurns = 3

    static func read(burn: ContextBurn, fill: ContextFill) -> RangeFootprint? {
        guard burn.turns.count >= 2 else { return nil }
        let window = fill.window.map(Double.init)
        let scale = window ?? Double(burn.turns.map(\.footprint).max() ?? 1)
        var bars: [Bar] = []
        for turn in burn.turns {
            if turn.startsEpoch, !bars.isEmpty { bars.append(Bar(kind: .refill, height: 1)) }
            bars.append(Bar(kind: .turn, height: min(1, Double(turn.footprint) / scale)))
        }
        if let growth = burn.growth, let last = burn.turns.last {
            for step in 1...projectedTurns {
                let projected = Double(last.footprint + growth * step) / scale
                bars.append(Bar(kind: .projected, height: min(1, projected)))
            }
        }
        return RangeFootprint(
            bars: Array(bars.suffix(widest)), dangerLine: window == nil ? nil : ContextFill.dangerAt)
    }
}

/// Everything the Range sheet draws, read once for every client.
///
/// A conversation spends from several tanks at once — its own window, the account's quota windows
/// that govern the model it will send with, the cache — and a person asks one question of all of
/// them: *which runs out first, and will I get to the refill?* The verdict is that answer in a
/// sentence; the rows are the tanks it was read from; and everything below them is what a person
/// who wants to act on it asks next. A client draws the rows with the pace-bar grammar (fill, tick,
/// tail) and decides nothing else.
public struct RangeBoard: Sendable, Equatable {
    public struct Verdict: Sendable, Equatable {
        public let headline: String
        public let detail: String?
        public let tone: ContextFill.Tone
    }

    public let verdict: Verdict
    /// The conversation's own window first, then the windows that govern its model, shortest
    /// first — fixed by what they are, never ranked by how hot they are, so the rows hold still.
    public let rows: [PaceRow]
    /// Windows on the same provider that govern some other model.
    public let elsewhere: [PaceRow]
    public let cache: CacheRow?
    public let composition: ContextComposition?
    public let footprint: RangeFootprint?
    public let source: String?

    /// One tank's claim on the verdict: how soon it runs out, and the sentence that says so.
    private struct Claim {
        let soonest: TimeInterval
        let headline: String
        let detail: String
        let tone: ContextFill.Tone
    }

    /// A turn is taken to last this long when only the order of two tanks is being decided.
    private static let turnPace: TimeInterval = 300

    public static func read(
        messages: [ChatMessage], fill: ContextFill?, quotas: [UsageQuota], model: String?,
        named name: String? = nil, selection: ModelSelection? = nil, isRunning: Bool = false,
        trail: QuotaTrail? = nil, now: Date = Date(), clock: RangeClock = .current
    ) -> RangeBoard {
        let burn = fill.flatMap {
            ContextBurn.read(messages: messages, fill: $0, wholeConversation: true)
        }
        var rows: [PaceRow] = []
        var claims: [Claim] = []
        var quiet = false

        if let fill {
            rows.append(PaceRow.context(fill: fill, burn: burn))
            if let burn, burn.isNews, let turns = burn.turnsLeft {
                claims.append(
                    Claim(
                        soonest: TimeInterval(turns) * turnPace,
                        headline: RangeWords.turnsHeadline(turns),
                        detail: RangeWords.turnsHeadline(turns), tone: burn.tone))
            }
        }

        let windows = RangeWindows.read(
            quotas: quotas, model: model, named: name, selection: selection)
        let ordered = windows.sorted { lhs, rhs in
            let a = QuotaWindowSpan.read(lhs.gauge, calendar: clock.calendar) ?? .infinity
            let b = QuotaWindowSpan.read(rhs.gauge, calendar: clock.calendar) ?? .infinity
            return a == b ? lhs.gauge.label < rhs.gauge.label : a < b
        }
        var elsewhere: [PaceRow] = []
        for window in ordered {
            let slug = ProviderBrand.slug(window.quota.providerName)
            let row = PaceRow.window(
                provider: window.quota.providerName, slug: slug, gauge: window.gauge, now: now,
                trail: trail, dimmed: !window.governs, clock: clock)
            guard window.governs else {
                elsewhere.append(row)
                continue
            }
            rows.append(row)
            guard
                let pace = QuotaPace.read(
                    window.gauge, provider: window.quota.providerName, now: now, trail: trail,
                    calendar: clock.calendar)
            else { continue }
            switch pace.verdict {
            case .wall(let resumes):
                claims.append(
                    Claim(
                        soonest: 0,
                        headline: QuotaSurface.headline(
                            QuotaExhaustion(
                                provider: window.quota.providerName, window: window.gauge.label,
                                fraction: window.gauge.fraction, resetsAt: resumes,
                                trustedReset: window.gauge.trustedReset, source: .gauge)),
                        detail: RangeWords.resumes(pace, now: now), tone: .danger))
            case .willRunOut(let wallAt):
                let sentence = Localized.text(
                    "%@ %@ runs out %@, before it resets.", window.quota.providerName,
                    window.gauge.label, RangeWords.wallWhen(wallAt, now: now, clock: clock))
                claims.append(
                    Claim(
                        soonest: wallAt.timeIntervalSince(now), headline: sentence,
                        detail: sentence, tone: .attention))
            case .onPace, .closeToTheLine:
                quiet = true
            case .tooEarly:
                break
            }
        }

        let cache = CacheWarmth.read(messages: messages, isRunning: isRunning, now: now)
        return RangeBoard(
            verdict: verdict(claims: claims, quiet: quiet, fill: fill),
            rows: rows, elsewhere: elsewhere, cache: cache.map(CacheRow.init),
            composition: fill.flatMap { ContextComposition.read(messages: messages, fill: $0) },
            footprint: burn.flatMap { burn in
                fill.flatMap { RangeFootprint.read(burn: burn, fill: $0) }
            },
            source: fill?.source)
    }

    private static func verdict(claims: [Claim], quiet: Bool, fill: ContextFill?) -> Verdict {
        let ranked = claims.sorted { $0.soonest < $1.soonest }
        guard let first = ranked.first else {
            if let fill, !quiet {
                return Verdict(headline: Localized.text("Room to spare."), detail: fill.summary, tone: fill.tone)
            }
            return Verdict(
                headline: Localized.text("Room to spare."),
                detail: quiet ? Localized.text("Every window is on pace.") : nil, tone: .quiet)
        }
        let others = ranked.dropFirst().prefix(2).map(\.detail)
        let rest = others.isEmpty ? (quiet ? Localized.text("Everything else is on pace.") : nil)
            : others.joined(separator: " ")
        return Verdict(headline: first.headline, detail: rest, tone: first.tone)
    }
}

/// What Home says about the account's quotas, which is nothing until a window will run out.
public enum RangeHome {
    /// One sentence for the earliest window on the board that is on course to run out before it
    /// resets, or nil. A provider the person hid from the board is left out, as it is from the
    /// strip, and a model's own window is left out because Home is about the account: a chat on
    /// that model says it in the chat.
    public static func line(
        quotas: [UsageQuota], board: QuotaBoardPreferences = .default, trail: QuotaTrail? = nil,
        now: Date = Date(), clock: RangeClock = .current
    ) -> String? {
        var earliest: (provider: String, window: String, at: Date)?
        for quota in quotas where !board.isHidden(ProviderBrand.slug(quota.providerName) ?? quota.providerName.lowercased()) {
            for gauge in quota.gauges
            where (gauge.usedUSD == nil || gauge.limitUSD != nil)
                && QuotaBinding.scope(of: gauge) == .account
            {
                guard
                    let pace = QuotaPace.read(
                        gauge, provider: quota.providerName, now: now, trail: trail,
                        calendar: clock.calendar),
                    case .willRunOut(let at) = pace.verdict
                else { continue }
                if earliest == nil || at < earliest!.at {
                    earliest = (quota.providerName, gauge.label, at)
                }
            }
        }
        guard let earliest else { return nil }
        return Localized.text(
            "%@ %@ runs out %@", earliest.provider, earliest.window,
            RangeWords.wallWhen(earliest.at, now: now, clock: clock))
    }
}
