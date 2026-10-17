import CodingAgentKit
import Foundation

/// The calendar and locale a time of day is written in. Core never reads the machine's: a client
/// hands its own, and a test hands a fixed one.
public struct RangeClock: Sendable {
    public var calendar: Calendar
    public var locale: Locale

    public init(calendar: Calendar, locale: Locale) {
        self.calendar = calendar
        self.locale = locale
    }

    public static var current: RangeClock { RangeClock(calendar: .current, locale: .current) }

    /// "19:22", or "7:22 PM" where that is how the locale writes it.
    public func time(_ date: Date) -> String { format("jm", date) }

    /// "Fri 13:00": the day is named because the time alone is ambiguous past half a day.
    public func dayTime(_ date: Date) -> String { format("EEEjm", date) }

    private func format(_ template: String, _ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// Every word the range says about a pace, written once so a chip, a row, a notification and a
/// widget cannot disagree about what a window is doing.
public enum RangeWords {
    /// A wall this close is said as a countdown; further off it is said as a time of day.
    static let countdownWithin: TimeInterval = 6 * 3600

    /// What the context chip says in place of a share once the turns left are worth counting.
    public static func turnsChip(_ turns: Int) -> String {
        switch turns {
        case ...0: return Localized.text("Almost full")
        case 1: return Localized.text("~1 turn")
        default: return Localized.text("~%d turns", turns)
        }
    }

    /// The sheet's sentence when the conversation's own window is the first to run out.
    public static func turnsHeadline(_ turns: Int) -> String {
        switch turns {
        case ...0: return Localized.text("This chat is about to be full.")
        case 1: return Localized.text("This chat has room for about 1 more turn.")
        default: return Localized.text("This chat has room for about %d more turns.", turns)
        }
    }

    /// When the limit is reached, as a countdown when it is near and a day and time when it is not,
    /// and always *about*: it is a projection.
    public static func wallWhen(_ wallAt: Date, now: Date, clock: RangeClock) -> String {
        if wallAt.timeIntervalSince(now) <= countdownWithin {
            return Localized.text("in %@", QuotaSurface.countdown(to: wallAt, now: now))
        }
        return Localized.text("about %@", clock.dayTime(wallAt))
    }

    /// How long before the reset the limit comes, as the second half of a wall's sentence.
    public static func slackPhrase(_ pace: QuotaPace, wallAt: Date) -> String {
        let span = QuotaSurface.countdown(to: pace.resetsAt, now: wallAt)
        return pace.approximate
            ? Localized.text("about %@ before it resets", span)
            : Localized.text("%@ before it resets", span)
    }

    public static func wallBody(_ pace: QuotaPace, wallAt: Date, now: Date, clock: RangeClock) -> String {
        Localized.text(
            "%@ — %@", wallWhen(wallAt, now: now, clock: clock), slackPhrase(pace, wallAt: wallAt))
    }

    /// The chip that appears while a window will run out before it resets.
    public static func wallChip(_ wallAt: Date, now: Date, clock: RangeClock) -> String {
        if wallAt.timeIntervalSince(now) <= 12 * 3600 {
            return Localized.text("Wall %@", clock.time(wallAt))
        }
        return Localized.text("Wall %@", clock.dayTime(wallAt))
    }

    public static func resumes(_ pace: QuotaPace, now: Date) -> String {
        let span = QuotaSurface.countdown(to: pace.resetsAt, now: now)
        return pace.approximate
            ? Localized.text("Sends resume in about %@", span)
            : Localized.text("Sends resume in %@", span)
    }

    public static func landing(_ landing: Double) -> String {
        Localized.text("Lands about %d%% — close to the limit", Int((min(landing, 1) * 100).rounded()))
    }

    public static func resets(_ gauge: UsageQuota.Gauge, now: Date) -> String {
        guard let resetsAt = gauge.resetsAt, resetsAt > now else { return "" }
        let remaining = QuotaSurface.countdown(to: resetsAt, now: now)
        return gauge.trustedReset
            ? Localized.text("resets in %@", remaining)
            : Localized.text("resets in about %@", remaining)
    }
}

/// One tank as one row: what it is called, what it says on the right, the bar and the marks on
/// it, and the single line of words it owes when its pace is news.
///
/// A client decides only how a bar is drawn. `fill` is what has been used; `tick` is where an even
/// burn would be by now; `tailEnd` is where the fill lands at the pace so far; `tone` is the
/// register the fill and tail are drawn in; and `tailIsNews` is what separates a surface that is
/// opened (which draws every tail) from one that is glanced at (which draws a tail only when it
/// carries news).
public struct PaceRow: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case context
        case window
        case balance
    }

    public struct News: Sendable, Equatable {
        public let lead: String
        public let body: String
        public let tone: ContextFill.Tone
    }

    public let id: String
    public let kind: Kind
    /// The provider's brand slug, for the colour a quiet fill wears.
    public let slug: String?
    public let title: String
    public let detail: String
    public let amount: String
    public let fill: Double
    public let tick: Double?
    /// The reset the tick is measured against is the provider's estimate.
    public let tickApproximate: Bool
    public let tailEnd: Double?
    public let tailIsNews: Bool
    public let tone: ContextFill.Tone
    public let tailTone: ContextFill.Tone
    public let news: News?
    /// A quiet remark that is not news: the window is too young to read, or a balance's runway.
    public let note: String?
    /// The window is not the one this conversation's model spends against.
    public let dimmed: Bool

    public var accessibilityLabel: String {
        var words = [title, amount]
        if !detail.isEmpty { words.append(detail) }
        if let news { words.append("\(news.lead) \(news.body)") } else if let note { words.append(note) }
        return words.joined(separator: ", ")
    }

    /// A quota window. With a pace the tone follows where the fill lands; without one it follows
    /// the level, by the same ramp the bars have always worn.
    public static func window(
        provider: String, slug: String?, gauge: UsageQuota.Gauge, now: Date = Date(),
        trail: QuotaTrail? = nil, dimmed: Bool = false, clock: RangeClock = .current
    ) -> PaceRow {
        let pace = QuotaPace.read(gauge, provider: provider, now: now, trail: trail, calendar: clock.calendar)
        let fill = min(1, max(0, gauge.fraction))
        let percent = "\(Int((fill * 100).rounded()))%"
        let level = levelTone(gauge.fraction)

        var tone = level
        var news: News?
        var note: String?
        if let pace {
            switch pace.verdict {
            case .wall:
                tone = .danger
                news = News(
                    lead: Localized.text("Used up"), body: RangeWords.resumes(pace, now: now),
                    tone: .danger)
            case .willRunOut(let wallAt):
                tone = .attention
                news = News(
                    lead: Localized.text("Wall"),
                    body: RangeWords.wallBody(pace, wallAt: wallAt, now: now, clock: clock),
                    tone: .attention)
            case .closeToTheLine:
                tone = .quiet
                news = News(
                    lead: Localized.text("Close"), body: RangeWords.landing(pace.landing ?? 1),
                    tone: .attention)
            case .onPace:
                tone = .quiet
            case .tooEarly:
                note = Localized.text("Too early to tell the pace")
            }
        }
        return PaceRow(
            id: QuotaTrail.identity(provider: provider, gauge: gauge), kind: .window, slug: slug,
            title: gauge.label,
            detail: dimmed ? Localized.text("not this model") : RangeWords.resets(gauge, now: now),
            amount: QuotaSurface.amountLabel(fraction: gauge.fraction, percentText: percent),
            fill: fill, tick: pace?.elapsed, tickApproximate: pace?.approximate ?? false,
            tailEnd: pace?.tailEnd, tailIsNews: pace?.isNews ?? false, tone: tone,
            tailTone: pace?.isNews == true ? .attention : .quiet, news: news, note: note,
            dimmed: dimmed)
    }

    /// The conversation's own window, with its tail the next five turns at the recent pace.
    public static func context(fill: ContextFill, burn: ContextBurn?) -> PaceRow {
        var tailEnd: Double?
        if let growth = burn?.growth, burn?.turnsLeft != nil, let window = fill.window, window > 0 {
            let reach = Double(growth * ContextBurn.recentTurns) / Double(window)
            tailEnd = min(1, (fill.fraction ?? 0) + reach)
        }
        var news: News?
        if let burn, burn.isNews, let turnsLeft = burn.turnsLeft {
            var body = Localized.text(
                "at the last five turns' pace, about %@ each",
                StatusFacts.tokens(burn.growth ?? 0))
            if let notable = burn.notableAddition {
                body +=
                    ". "
                    + Localized.text(
                        "The biggest turn added %@, %d%% of what is left.",
                        StatusFacts.tokens(notable.addition.tokens),
                        Int((notable.share * 100).rounded()))
            }
            news = News(lead: RangeWords.turnsChip(turnsLeft), body: body, tone: burn.tone)
        }
        let detail = [fill.model.map(ModelBadge.shortName), fill.window.map(StatusFacts.tokens)]
            .compactMap { $0 }.joined(separator: " · ")
        return PaceRow(
            id: "context", kind: .context, slug: nil, title: Localized.text("Context"),
            detail: detail,
            amount: fill.percent.map { "\($0)%" } ?? StatusFacts.tokens(fill.used),
            fill: fill.fraction ?? 0, tick: nil, tickApproximate: false, tailEnd: tailEnd,
            tailIsNews: burn?.isNews ?? false, tone: max(fill.tone, burn?.tone ?? .quiet),
            tailTone: burn?.isNews == true ? .attention : .quiet, news: news, note: nil,
            dimmed: false)
    }

    /// A prepaid balance: a figure and, once the trail has watched it long enough, a runway.
    public static func balance(
        provider: String, slug: String?, gauge: UsageQuota.Gauge, now: Date = Date(),
        trail: QuotaTrail? = nil
    ) -> PaceRow {
        let dollars = gauge.usedUSD ?? 0
        var note: String?
        if let trail,
            let spend = trail.spendPerDay(
                id: QuotaTrail.identity(provider: provider, gauge: gauge), balance: dollars, now: now)
        {
            note = Localized.text(
                "Lasts about %@ at %@ a day", runway(dollars / spend.perDay),
                QuotaGlance.money(spend.perDay, gauge.currency))
        }
        return PaceRow(
            id: QuotaTrail.identity(provider: provider, gauge: gauge), kind: .balance, slug: slug,
            title: gauge.label, detail: "", amount: QuotaGlance.money(dollars, gauge.currency),
            fill: 0, tick: nil, tickApproximate: false, tailEnd: nil, tailIsNews: false,
            tone: .quiet, tailTone: .quiet, news: nil, note: note, dimmed: false)
    }

    private static func runway(_ days: Double) -> String {
        if days < 2 { return Localized.text("%d hours", max(2, Int((days * 24).rounded()))) }
        if days < 100 { return Localized.text("%d days", Int(days.rounded())) }
        return Localized.text("months")
    }

    private static func levelTone(_ fraction: Double) -> ContextFill.Tone {
        switch QuotaSurface.Pressure(fraction: fraction) {
        case .roomToSpare: return .quiet
        case .gettingTight: return .attention
        case .nearlyOut, .usedUp: return .danger
        }
    }
}

extension ContextFill.Tone: Comparable {
    public static func < (lhs: ContextFill.Tone, rhs: ContextFill.Tone) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .quiet: return 0
        case .attention: return 1
        case .danger: return 2
        }
    }
}
