import Foundation

/// A quota as a widget receives it — the stored snapshot's own shape, with no backend behind it.
///
/// The widget process reads a file written hours ago by another process; it has no connection, no
/// `UsageQuota` to ask and no business rebuilding one. So the reading takes the numbers themselves:
/// what the window is called, how full it is, when it opens again, the money where money is known,
/// and whatever the writer already said about it in words.
public struct WidgetQuota: Sendable, Equatable {
    public struct Gauge: Sendable, Equatable {
        public var label: String
        public var fraction: Double
        public var resetsAt: Date?
        public var trustedReset: Bool
        /// Money spent against a ceiling. `usedUSD` with no `limitUSD` is a prepaid balance rather
        /// than a window — the one rule every renderer recognises money-with-no-wall by.
        public var usedUSD: Double?
        public var limitUSD: Double?
        public var currency: String?
        /// What the writer already said about this gauge (a balance's split, a spend line). Used
        /// where the reading has nothing better of its own to say.
        public var note: String

        public init(
            label: String, fraction: Double, resetsAt: Date? = nil, trustedReset: Bool = true,
            usedUSD: Double? = nil, limitUSD: Double? = nil, currency: String? = nil,
            note: String = ""
        ) {
            self.label = label
            self.fraction = fraction
            self.resetsAt = resetsAt
            self.trustedReset = trustedReset
            self.usedUSD = usedUSD
            self.limitUSD = limitUSD
            self.currency = currency
            self.note = note
        }

        public var isBalance: Bool { usedUSD != nil && limitUSD == nil }
    }

    public var providerName: String
    public var subtitle: String
    public var isLive: Bool
    public var gauges: [Gauge]

    public init(providerName: String, subtitle: String, isLive: Bool, gauges: [Gauge]) {
        self.providerName = providerName
        self.subtitle = subtitle
        self.isLive = isLive
        self.gauges = gauges
    }
}

/// The families a widget is drawn at, as a size rather than as a toolkit type. Core decides how
/// much of the reading each one is allowed to say; a client decides only how tall a bar is.
public enum WidgetSize: String, Sendable, CaseIterable {
    case small
    case medium
    case large
    case rectangular
    case circular
    case inline

    /// How many gauge rows this size can hold before it starts truncating meaning rather than
    /// detail. A row past the budget is counted in a line, never silently dropped.
    public var rowBudget: Int {
        switch self {
        case .small: return 3
        case .medium: return 4
        case .large: return 8
        case .rectangular: return 3
        case .circular, .inline: return 1
        }
    }

    /// Whether the size has room for the second line under a gauge — the money, the reset in words.
    public var affordsCaptions: Bool { self == .large }

    /// Whether the size can name a provider beside its window, or has to pick one of the two.
    public var affordsProviderNames: Bool {
        switch self {
        case .small, .rectangular, .circular, .inline: return false
        case .medium, .large: return true
        }
    }
}

/// Which windows a widget spends its rows on.
public enum WidgetGrouping: String, Sendable, CaseIterable {
    /// One provider fills the widget with its own windows; several share it a row each. The default,
    /// because it is the answer to "what is going on" at either shape of account.
    case automatic
    /// Every window in the account, tightest first, whoever meters it.
    case hottest
    /// One row per provider — its tightest window — however many windows it has.
    case byProvider

    public var title: String {
        switch self {
        case .automatic: return Localized.text("Automatic")
        case .hottest: return Localized.text("Tightest windows")
        case .byProvider: return Localized.text("One per provider")
        }
    }
}

/// How much a row is allowed to say beyond its number.
public enum WidgetDetail: String, Sendable, CaseIterable {
    /// As much as the size can hold — captions where there is room, bare rows where there is not.
    case automatic
    /// Numbers only: no captions, no resets. More windows on screen.
    case compact
    /// Every row states its money and its reset, at the cost of rows.
    case detailed

    public var title: String {
        switch self {
        case .automatic: return Localized.text("Automatic")
        case .compact: return Localized.text("Compact")
        case .detailed: return Localized.text("Detailed")
        }
    }
}

/// Everything a Usage widget says, decided once for every family and every client.
///
/// The widget is the surface furthest from the server and the one least able to ask a question: it
/// renders a file another process wrote, at a moment nobody chose, in a space too small to hedge.
/// So the reading answers the question the glance is actually for — *can I send, and for how long* —
/// and every family draws the same answer at a different length: the tightest window is the hero,
/// a wall reads as a state rather than as 100%, money with no ceiling is a balance rather than a bar
/// at zero, and a number nobody has refreshed says so before it says anything else.
public struct WidgetGlance: Sendable, Equatable {
    /// A row's meaning, which is what decides its colour. `warn` is attention and `danger` is a
    /// wall; nothing between them is invented, because a colour a reader has to measure says less
    /// than the number already beside it.
    public enum Tone: String, Sendable {
        case ok
        case warn
        case danger
        case balance
        case quiet
    }

    public enum Kind: String, Sendable {
        case window
        case balance
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: Kind
        public let providerName: String
        public let providerShort: String
        public let slug: String?
        /// The window's own name, as its provider states it.
        public let label: String
        /// The same name where a column is narrow — "5-hour", "Weekly", "Cache".
        public let shortLabel: String
        /// The number as a person reads it: a percentage, `Used up`, or the money itself.
        public let value: String
        /// `nil` for a balance, which has no ceiling to fill.
        public let fraction: Double?
        public let resetsAt: Date?
        public let trustedReset: Bool
        /// The second line: money against its cap, the reset in words, or whatever the writer said.
        public let caption: String
        /// Just the money, where the provider reports it — for a surface that already draws the
        /// clock itself and would otherwise state the reset twice in two different voices.
        public let money: String
        public let tone: Tone
        /// Past this a window is close enough to its wall to wear a mark of its own, without
        /// spending the failure colour on something that has not failed.
        public let isCritical: Bool
        public let isLive: Bool
        /// The whole row in one sentence, for a screen reader that gets no columns.
        public let spoken: String
    }

    public struct Provider: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let short: String
        public let subtitle: String
        public let slug: String?
        public let isLive: Bool
        public let rows: [Row]
        /// The fullest window this provider meters, which is what floats it up a list.
        public let peak: Double
    }

    /// What the reading says about its own numbers before it says anything about the account.
    public struct Freshness: Sendable, Equatable {
        /// One word beside a provider: LIVE, EST, CACHED.
        public let badge: String
        /// The line a large family has room for: when it was read, or that it is old.
        public let note: String
        public let isStale: Bool
    }

    public let providers: [Provider]
    /// Every row the configuration asked for, ranked: walls first, then tightest, balance last
    /// unless it is empty — an empty balance is a wall like any other.
    public let rows: [Row]
    /// The one window that decides when the next send goes out.
    public let hero: Row?
    public let freshness: Freshness
    public let updatedAt: Date
    /// What the whole account amounts to in one line.
    public let verdict: String
    /// What the widget calls itself: the provider when one fills it, "Usage" when several do.
    public let title: String

    public var isEmpty: Bool { rows.isEmpty }

    /// A window at or past this wears a mark: it is not a wall, but it is the last part of the
    /// window where waiting is still a choice.
    public static let criticalFloor: Double = 0.85
    /// Past this a window is warm enough to be worth a colour.
    public static let warmFloor: Double = 0.6
    /// A snapshot older than this is stale — the same floor the store has always used.
    public static let staleAfter: TimeInterval = 300

    public static let emptyTitle = Localized.text("No usage data")
    public static let emptyDetail = Localized.text("Connect a server to see quotas")

    public static func make(
        quotas: [WidgetQuota], updatedAt: Date, now: Date = Date(),
        grouping: WidgetGrouping = .automatic, detail: WidgetDetail = .automatic,
        providerFilter: Set<String>? = nil
    ) -> WidgetGlance {
        let kept = filter(quotas, by: providerFilter)
        let providers = kept.map { provider(from: $0, now: now, detail: detail) }
            .filter { !$0.rows.isEmpty }
            .sorted { $0.peak > $1.peak }
        let isStale = now.timeIntervalSince(updatedAt) > staleAfter
        let freshness = freshness(providers, updatedAt: updatedAt, now: now, isStale: isStale)
        let rows = ranked(providers, grouping: grouping)
        let hero = rows.first(where: { $0.kind == .window }) ?? rows.first
        return WidgetGlance(
            providers: providers,
            rows: rows,
            hero: hero,
            freshness: freshness,
            updatedAt: updatedAt,
            verdict: verdict(providers, rows: rows, now: now),
            title: providers.count == 1
                ? (providers[0].short) : Localized.text("Usage"))
    }

    /// The rows one family may draw, and what it says instead of the ones it cannot fit.
    public func rows(for size: WidgetSize) -> [Row] {
        Array(rows.prefix(size.rowBudget))
    }

    /// How many windows a size had to leave out. Zero is the ordinary answer; anything else is a
    /// fact the surface states rather than a truncation it hides.
    public func overflow(for size: WidgetSize) -> Int {
        max(0, rows.count - size.rowBudget)
    }

    public func overflowLine(for size: WidgetSize) -> String? {
        let extra = overflow(for: size)
        guard extra > 0 else { return nil }
        return Localized.text("+%@ more", String(extra))
    }

    /// The one line an inline accessory has: who, how full, and how long until it opens again.
    public var inlineText: String {
        guard let hero else { return Self.emptyTitle }
        var text = "\(hero.providerShort) \(hero.value)"
        if let resetsAt = hero.resetsAt, resetsAt > updatedAt {
            text += " · " + QuotaSurface.countdown(to: resetsAt, now: updatedAt)
        }
        return text
    }

    /// The whole glance in words, for a reader that gets none of the columns.
    public var spoken: String {
        guard !isEmpty else { return "\(Self.emptyTitle). \(Self.emptyDetail)" }
        return ([verdict] + rows.map(\.spoken)).joined(separator: ". ")
    }

    // MARK: - Building

    private static func filter(_ quotas: [WidgetQuota], by wanted: Set<String>?) -> [WidgetQuota] {
        guard let wanted, !wanted.isEmpty else { return quotas }
        return quotas.filter { wanted.contains(key(for: $0.providerName)) }
    }

    /// How a provider is named in a stored configuration: its brand where it has one, its own name
    /// folded down where it has not — so a picked provider survives a server renaming its subtitle.
    public static func key(for providerName: String) -> String {
        ProviderBrand.brand(providerName) ?? providerName.lowercased()
    }

    private static func provider(from quota: WidgetQuota, now: Date, detail: WidgetDetail)
        -> Provider
    {
        let slug = ProviderBrand.brand(quota.providerName)
        let short = ProviderBrand.short(quota.providerName)
        let rows = quota.gauges
            .map { row(for: $0, in: quota, slug: slug, short: short, now: now, detail: detail) }
            .sorted(by: precedes)
        let filled = rows.compactMap { $0.fraction }.max()
        let walled = rows.contains { $0.tone == .danger }
        return Provider(
            name: quota.providerName, short: short, subtitle: quota.subtitle, slug: slug,
            isLive: quota.isLive, rows: rows,
            peak: walled ? 1 : (filled ?? 0))
    }

    private static func row(
        for gauge: WidgetQuota.Gauge, in quota: WidgetQuota, slug: String?, short: String,
        now: Date, detail: WidgetDetail
    ) -> Row {
        let clamped = min(max(gauge.fraction, 0), 1)
        let standing = gauge.resetsAt.map { $0 > now } ?? true
        let exhausted = gauge.fraction >= QuotaSurface.exhaustedFloor && standing
        let kind: Kind = gauge.isBalance ? .balance : .window
        let value: String
        let tone: Tone
        if kind == .balance {
            value = exhausted
                ? Localized.text("Empty") : QuotaGlance.money(gauge.usedUSD ?? 0, gauge.currency)
            tone = exhausted ? .danger : .balance
        } else {
            value = QuotaSurface.amountLabel(
                fraction: gauge.fraction,
                percentText: "\(Int((clamped * 100).rounded()))%")
            if exhausted {
                tone = .danger
            } else if clamped >= warmFloor {
                tone = .warn
            } else {
                tone = .ok
            }
        }
        return Row(
            id: "\(quota.providerName):\(gauge.label)",
            kind: kind,
            providerName: quota.providerName,
            providerShort: short,
            slug: slug,
            label: gauge.label,
            shortLabel: shortLabel(gauge.label),
            value: value,
            fraction: kind == .balance ? nil : clamped,
            resetsAt: standing ? gauge.resetsAt : nil,
            trustedReset: gauge.trustedReset,
            caption: caption(for: gauge, kind: kind, now: now, detail: detail),
            money: money(for: gauge),
            tone: tone,
            isCritical: kind == .window && gauge.fraction >= criticalFloor,
            isLive: quota.isLive,
            spoken: spoken(
                provider: short, label: gauge.label, value: value, kind: kind, exhausted: exhausted,
                resetsAt: standing ? gauge.resetsAt : nil, now: now))
    }

    private static func money(for gauge: WidgetQuota.Gauge) -> String {
        guard let used = gauge.usedUSD else { return "" }
        guard let limit = gauge.limitUSD else { return QuotaGlance.money(used, gauge.currency) }
        return "\(QuotaGlance.money(used, gauge.currency)) / \(QuotaGlance.money(limit, gauge.currency))"
    }

    private static func caption(
        for gauge: WidgetQuota.Gauge, kind: Kind, now: Date, detail: WidgetDetail
    ) -> String {
        guard detail != .compact else { return "" }
        if kind == .balance { return gauge.note }
        var parts: [String] = []
        if let used = gauge.usedUSD, let limit = gauge.limitUSD {
            parts.append(
                "\(QuotaGlance.money(used, gauge.currency)) / \(QuotaGlance.money(limit, gauge.currency))"
            )
        }
        if let resetsAt = gauge.resetsAt, resetsAt > now {
            let remaining = QuotaSurface.countdown(to: resetsAt, now: now)
            parts.append(
                gauge.trustedReset
                    ? Localized.text("resets %@", remaining)
                    : Localized.text("~resets %@", remaining))
        }
        if parts.isEmpty, !gauge.note.isEmpty { parts.append(gauge.note) }
        return parts.joined(separator: " · ")
    }

    private static func spoken(
        provider: String, label: String, value: String, kind: Kind, exhausted: Bool,
        resetsAt: Date?, now: Date
    ) -> String {
        if kind == .balance {
            return exhausted
                ? Localized.text("%@ balance is empty", provider)
                : Localized.text("%@ balance %@", provider, value)
        }
        var text = Localized.text("%@ %@ %@", provider, label, value)
        if let resetsAt, resetsAt > now {
            text += ", " + Localized.text("resets in %@", QuotaSurface.countdown(to: resetsAt, now: now))
        }
        return text
    }

    /// Walls first, then the fullest window, with a healthy balance last — money that is not a
    /// wall is context beside a clock somebody is waiting on.
    private static func precedes(_ lhs: Row, _ rhs: Row) -> Bool {
        let lhsWall = lhs.tone == .danger
        let rhsWall = rhs.tone == .danger
        if lhsWall != rhsWall { return lhsWall }
        let lhsBalance = lhs.kind == .balance
        let rhsBalance = rhs.kind == .balance
        if lhsBalance != rhsBalance { return rhsBalance }
        return (lhs.fraction ?? 0) > (rhs.fraction ?? 0)
    }

    private static func ranked(_ providers: [Provider], grouping: WidgetGrouping) -> [Row] {
        let resolved: WidgetGrouping = {
            guard grouping == .automatic else { return grouping }
            return providers.count == 1 ? .hottest : .byProvider
        }()
        switch resolved {
        case .hottest, .automatic:
            return providers.flatMap(\.rows).sorted(by: precedes)
        case .byProvider:
            var rows = providers.compactMap { $0.rows.first }
            let seconds = providers.flatMap { $0.rows.dropFirst() }
            rows.sort(by: precedes)
            return rows + seconds.sorted(by: precedes)
        }
    }

    private static func freshness(
        _ providers: [Provider], updatedAt: Date, now: Date, isStale: Bool
    ) -> Freshness {
        let live = providers.contains(where: \.isLive)
        let badge = live ? Localized.text("LIVE") : Localized.text("EST")
        guard !providers.isEmpty else {
            return Freshness(badge: badge, note: "", isStale: false)
        }
        let age = QuotaGlance.ageWords(now.timeIntervalSince(updatedAt))
        return Freshness(
            badge: isStale ? Localized.text("CACHED") : badge,
            note: isStale
                ? Localized.text("Last read %@ ago", age)
                : Localized.text("Updated %@ ago", age),
            isStale: isStale)
    }

    /// The account in one line: what is in the way, or what is closest to being.
    private static func verdict(_ providers: [Provider], rows: [Row], now: Date) -> String {
        guard !rows.isEmpty else { return emptyTitle }
        let walls = rows.filter { $0.tone == .danger }
        if let wall = walls.first {
            let head = wall.kind == .balance
                ? Localized.text("%@ balance is empty", wall.providerShort)
                : Localized.text("%@ %@ is used up", wall.providerShort, wall.label)
            guard walls.count == 1 else {
                return Localized.text("%@ · +%@ more", head, String(walls.count - 1))
            }
            guard let resetsAt = wall.resetsAt, resetsAt > now else { return head }
            return "\(head) · \(QuotaSurface.countdown(to: resetsAt, now: now))"
        }
        guard let tightest = rows.first(where: { $0.kind == .window }) else {
            guard let balance = rows.first else { return Localized.text("Quotas clear") }
            return Localized.text("%@ balance %@", balance.providerShort, balance.value)
        }
        if (tightest.fraction ?? 0) >= warmFloor {
            return Localized.text(
                "%@ %@ at %@", tightest.providerShort, tightest.shortLabel, tightest.value)
        }
        return Localized.text(
            "Quotas clear · %@ %@ %@", tightest.providerShort, tightest.shortLabel, tightest.value)
    }

    /// A window's name where a column is narrow. The families a provider meters are few and they
    /// repeat; anything unrecognised keeps its own name rather than being cut mid-word.
    public static func shortLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("cache") { return Localized.text("Cache") }
        if lower.contains("input") { return Localized.text("Input") }
        if lower.contains("output") { return Localized.text("Output") }
        if lower.contains("reason") { return Localized.text("Reason") }
        if lower.contains("chat") { return Localized.text("Chat") }
        if lower.contains("build") { return Localized.text("Build") }
        if lower.contains("credit") { return Localized.text("Credits") }
        if lower.contains("balance") { return Localized.text("Balance") }
        if lower.contains("5-hour") || lower.contains("5 hour") || lower.contains("session") {
            return Localized.text("5-hour")
        }
        if lower.contains("month") { return Localized.text("Monthly") }
        if lower.contains("week") {
            guard let model = modelWord(in: label) else { return Localized.text("Weekly") }
            return Localized.text("Weekly · %@", model)
        }
        return label
    }

    /// The model a window is scoped to, when its label names one — "Weekly · Opus" is Opus's, and
    /// dropping the model would make two different windows read as the same one.
    private static func modelWord(in label: String) -> String? {
        let lower = label.lowercased()
        for word in ["opus", "sonnet", "haiku", "fable"] where lower.contains(word) {
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return nil
    }
}
