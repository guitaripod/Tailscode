import CodingAgentKit
import Foundation

/// The quota strip at the foot of the chat list, as data: what each line says, what it says on the
/// right, the tone its dot wears and the bar it fills — so a client draws it without deciding
/// anything, and a selftest proves every state without a display.
///
/// The strip answers one question — *can I send, and with what* — and each state owns it:
///
/// - **a wall exists**: one line per used-up window, soonest reset first, and beside them the one
///   line that makes a wall actionable: what still has room. A wall with no relief says so;
/// - **no wall**: one line per provider on the board — its tightest window, in the board's own
///   order so the strip holds still — warm (≥60%) in the attention tone and the rest quiet, with
///   anything past the strip's room counted rather than dropped. A provider the person keeps on
///   the board is on the strip; a strip that listed only the warm ones read as the others having
///   gone.
///
/// A prepaid balance keeps its own line in every state, because it is the one number that moves
/// whatever the windows are doing. A reading that is not live says so before it says anything
/// else — a cached percentage presented as current is how a strip ends up lying about a wall.
public struct QuotaGlance: Sendable, Equatable {
    public enum Tone: String, Sendable {
        case ok
        case warn
        case danger
        case balance
        case quiet
    }

    /// A line's shape rather than its meaning: what the client has to draw. A notice is a sentence
    /// about the reading itself and wears no dot and no bar; a window is a gauge and carries both;
    /// a balance is money, which has no ceiling to fill.
    public enum Kind: String, Sendable {
        case notice
        case window
        case balance
    }

    public struct Line: Sendable, Equatable {
        public let kind: Kind
        public let text: String
        public let trailing: String
        public let tone: Tone
        public let fraction: Double?
        public let slug: String?

        public init(
            kind: Kind, text: String, trailing: String = "", tone: Tone, fraction: Double? = nil,
            slug: String? = nil
        ) {
            self.kind = kind
            self.text = text
            self.trailing = trailing
            self.tone = tone
            self.fraction = fraction
            self.slug = slug
        }
    }

    public let lines: [Line]
    /// The whole picture in words, for the hover the strip already offers: every provider, every
    /// window, and where the numbers came from.
    public let tooltip: String

    public var isEmpty: Bool { lines.isEmpty }

    /// A window at or above this is warm enough to be worth a line of its own.
    public static let warmFloor: Double = 0.6
    /// Past this, a reading is old enough that the strip says so even though it is all we have.
    public static let staleAfter: TimeInterval = 600
    /// How many gauge lines one state may spend. Anything past it is counted in a notice rather
    /// than dropped, because a strip that silently truncates reads as the whole story.
    public static let maxWindows = 3

    /// The strip for what every server reported, folded to the account.
    ///
    /// `answeredAt` is when the last snapshot actually arrived — nil while the first poll is still
    /// out, which is a state with its own line rather than an empty strip: a person who has just
    /// opened the app and sees nothing cannot tell a quiet account from one nobody has asked.
    ///
    /// `board` is the person's board: a provider hidden there is left out of the strip as well,
    /// because the strip is the account glanced at and the board is what the account looks like
    /// to them. What the chat says about a wall is decided elsewhere and never hidden.
    public static func make(
        from reports: [(String, UsageQuota)], answeredAt: Date?, now: Date = Date(),
        board: QuotaBoardPreferences = .default
    ) -> QuotaGlance {
        let holdings = QuotaRollup.account(from: reports).filter {
            !board.isHidden(QuotaBoard.key($0))
        }
        guard !holdings.isEmpty else {
            guard answeredAt == nil else { return QuotaGlance(lines: [], tooltip: "") }
            return QuotaGlance(
                lines: [
                    Line(kind: .notice, text: Localized.text("Reading quotas…"), tone: .quiet)
                ],
                tooltip: Localized.text("Asking every provider what is left."))
        }

        var lines: [Line] = []
        if let notice = freshness(holdings, answeredAt: answeredAt, now: now) {
            lines.append(notice)
        }

        let windows = holdings.flatMap { holding in
            holding.gauges.filter { !isBalance($0) }.map { (holding, $0) }
        }
        let walls =
            windows
            .filter { $0.1.fraction >= QuotaSurface.exhaustedFloor && standing($0.1, now: now) }
            .sorted { soonest($0.1) < soonest($1.1) }

        if !walls.isEmpty {
            lines += walls.prefix(maxWindows).map { line(for: $0.0, $0.1, tone: .danger, now: now) }
            if walls.count > maxWindows {
                lines.append(
                    Line(
                        kind: .notice,
                        text: Localized.text(
                            "+%@ more used up", String(walls.count - maxWindows)),
                        tone: .danger))
            }
            lines += relief(
                among: windows, walls: walls, holdings: holdings, board: board, now: now)
        } else {
            lines += standing(among: windows, holdings: holdings, board: board, now: now)
        }

        if let money = balance(in: holdings) {
            lines.append(balanceLine(money.0, money.1))
        }
        return QuotaGlance(lines: lines, tooltip: tooltip(holdings, answeredAt: answeredAt, now: now))
    }

    /// One window's line: who meters it and which window, the reset as a dim tail, and the number
    /// it is at on the right. The countdown needs no verb — beside a quota window it can only ever
    /// mean the reset.
    private static func line(
        for holding: QuotaHolding, _ gauge: UsageQuota.Gauge, tone: Tone, now: Date
    ) -> Line {
        var text = "\(holding.providerName) \(gauge.label)"
        if let resets = gauge.resetsAt, resets > now {
            let remaining = QuotaSurface.countdown(to: resets, now: now)
            text +=
                " · "
                + (gauge.trustedReset ? remaining : Localized.text("about %@", remaining))
        }
        return Line(
            kind: .window, text: text, trailing: percent(gauge), tone: tone,
            fraction: clamped(gauge.fraction), slug: holding.slug)
    }

    /// The lines a wall is only useful with: where there is still room. A provider is only shut out
    /// by a window that meters its whole account — a wall around one model leaves the provider
    /// open, which is exactly the difference between picking something else and waiting.
    ///
    /// Every provider still open gets a line, in the board's own order, because the board is the
    /// person's answer to which providers they want to see: naming only the roomiest reads as the
    /// whole answer to what is left, and re-ranking them by pressure moves the rows under the
    /// reader every poll. The roomiest is still the one told to say it is *still open* — that is
    /// the sentence a wall is answered with.
    private static func relief(
        among windows: [(QuotaHolding, UsageQuota.Gauge)],
        walls: [(QuotaHolding, UsageQuota.Gauge)], holdings: [QuotaHolding],
        board: QuotaBoardPreferences, now: Date
    ) -> [Line] {
        let blocked = Set(
            walls.filter { QuotaBinding.scope(of: $0.1) == .account }.map { key($0.0) })
        let open = windows.filter {
            !blocked.contains(key($0.0)) && $0.1.fraction < QuotaSurface.exhaustedFloor
        }
        let picks = tightestPerProvider(open, holdings: holdings, board: board)
        guard let roomiest = picks.min(by: { $0.1.fraction < $1.1.fraction }) else {
            if let money = balance(in: holdings), money.1.fraction < QuotaSurface.exhaustedFloor {
                return [
                    Line(
                        kind: .notice, text: Localized.text("Only the prepaid balance is left"),
                        tone: .warn)
                ]
            }
            return [
                Line(kind: .notice, text: Localized.text("Nothing left to send with"), tone: .danger)
            ]
        }
        return picks.map { holding, gauge in
            guard key(holding) == key(roomiest.0), gauge.label == roomiest.1.label else {
                return line(
                    for: holding, gauge, tone: gauge.fraction >= warmFloor ? .warn : .ok, now: now)
            }
            return Line(
                kind: .window,
                text: Localized.text("%@ %@ still open", holding.providerName, gauge.label),
                trailing: percent(gauge), tone: .ok, fraction: clamped(gauge.fraction),
                slug: holding.slug)
        }
    }

    /// The strip with no wall in it: every provider the board shows, one line each, its tightest
    /// window in the board's order. The tone says which are worth watching; the presence says
    /// which the person chose to see.
    private static func standing(
        among windows: [(QuotaHolding, UsageQuota.Gauge)], holdings: [QuotaHolding],
        board: QuotaBoardPreferences, now: Date
    ) -> [Line] {
        let picks = tightestPerProvider(windows, holdings: holdings, board: board)
        guard !picks.isEmpty else {
            return balance(in: holdings) == nil
                ? [Line(kind: .notice, text: Localized.text("Quotas clear"), tone: .ok)] : []
        }
        return picks.map {
            line(for: $0.0, $0.1, tone: $0.1.fraction >= warmFloor ? .warn : .ok, now: now)
        }
    }

    /// One window per provider — the one closest to its wall — with the providers in the order the
    /// board keeps them. Every provider on the board is answered for: a strip that lists only some
    /// of them reads as the others having gone.
    private static func tightestPerProvider(
        _ windows: [(QuotaHolding, UsageQuota.Gauge)], holdings: [QuotaHolding],
        board: QuotaBoardPreferences
    ) -> [(QuotaHolding, UsageQuota.Gauge)] {
        QuotaBoard.arrange(holdings, preferences: board).compactMap { holding in
            windows.filter { key($0.0) == key(holding) }
                .max { $0.1.fraction < $1.1.fraction }
        }
    }

    private static func balanceLine(_ holding: QuotaHolding, _ gauge: UsageQuota.Gauge) -> Line {
        guard gauge.fraction < QuotaSurface.exhaustedFloor else {
            return Line(
                kind: .balance,
                text: Localized.text("%@ balance · top up", holding.providerName),
                trailing: Localized.text("Empty"), tone: .danger)
        }
        return Line(
            kind: .balance, text: Localized.text("%@ balance", holding.providerName),
            trailing: money(gauge.usedUSD ?? 0, gauge.currency), tone: .balance,
            slug: holding.slug)
    }

    /// What the strip says about its own numbers before it says anything about the account: a first
    /// poll still out, a reading nobody could refresh, or an estimate that was never live to begin
    /// with. Silence means the numbers are live and recent, which is the only case worth no words.
    private static func freshness(_ holdings: [QuotaHolding], answeredAt: Date?, now: Date)
        -> Line?
    {
        guard let answeredAt else {
            return Line(kind: .notice, text: Localized.text("Reading quotas…"), tone: .quiet)
        }
        let age = now.timeIntervalSince(answeredAt)
        if holdings.contains(where: { $0.quota.live }) {
            guard age >= staleAfter else { return nil }
            return Line(
                kind: .notice, text: Localized.text("Last read %@ ago", ageWords(age)), tone: .warn)
        }
        if holdings.allSatisfy({ $0.quota.source.lowercased().contains("estimated") }) {
            return Line(kind: .notice, text: Localized.text("Estimated, not live"), tone: .quiet)
        }
        return Line(
            kind: .notice, text: Localized.text("Cached · %@ old", ageWords(age)), tone: .warn)
    }

    /// Every provider, every window and where the numbers came from — the picture the strip has no
    /// room for, one hover away and without opening anything.
    private static func tooltip(_ holdings: [QuotaHolding], answeredAt: Date?, now: Date) -> String {
        var out: [String] = []
        for holding in holdings {
            var head = holding.providerName
            if !holding.quota.subtitle.isEmpty { head += " · \(holding.quota.subtitle)" }
            head += " · \(QuotaSurface.badge(holding.quota))"
            out.append(head)
            for gauge in holding.gauges {
                var row =
                    isBalance(gauge)
                    ? "   \(gauge.label)  \(money(gauge.usedUSD ?? 0, gauge.currency))"
                    : "   \(gauge.label)  \(percent(gauge))"
                if let used = gauge.usedUSD, let limit = gauge.limitUSD {
                    row += "  \(money(used, gauge.currency)) / \(money(limit, gauge.currency))"
                }
                if let resets = gauge.resetsAt, resets > now {
                    let remaining = QuotaSurface.countdown(to: resets, now: now)
                    row +=
                        "  "
                        + (gauge.trustedReset
                            ? Localized.text("resets in %@", remaining)
                            : Localized.text("resets in about %@", remaining))
                }
                out.append(row)
            }
            out.append("   \(QuotaRollup.provenance(holding))")
        }
        if let answeredAt {
            out.append(Localized.text("Read %@ ago", ageWords(now.timeIntervalSince(answeredAt))))
        }
        out.append(Localized.text("The full quota picture"))
        return out.joined(separator: "\n")
    }

    private static func balance(in holdings: [QuotaHolding]) -> (QuotaHolding, UsageQuota.Gauge)? {
        for holding in holdings {
            if let gauge = holding.gauges.first(where: { isBalance($0) }) { return (holding, gauge) }
        }
        return nil
    }

    /// Money with no ceiling is a balance rather than a window — the same rule every renderer
    /// recognises one by.
    private static func isBalance(_ gauge: UsageQuota.Gauge) -> Bool {
        gauge.usedUSD != nil && gauge.limitUSD == nil
    }

    /// A window whose own stated reset has already passed is a photograph of a moment that ended;
    /// it is not news until something refreshes it.
    private static func standing(_ gauge: UsageQuota.Gauge, now: Date) -> Bool {
        gauge.resetsAt.map { $0 > now } ?? true
    }

    private static func soonest(_ gauge: UsageQuota.Gauge) -> TimeInterval {
        gauge.resetsAt?.timeIntervalSince1970 ?? .infinity
    }

    private static func key(_ holding: QuotaHolding) -> String {
        holding.slug ?? holding.providerName.lowercased()
    }

    private static func clamped(_ fraction: Double) -> Double { min(max(fraction, 0), 1) }

    private static func percent(_ gauge: UsageQuota.Gauge) -> String {
        QuotaSurface.amountLabel(
            fraction: gauge.fraction,
            percentText: "\(Int((clamped(gauge.fraction) * 100).rounded()))%")
    }

    public static func money(_ value: Double, _ currency: String?) -> String {
        let symbol = (currency ?? "USD").uppercased() == "CNY" ? "¥" : "$"
        return String(format: "%@%.2f", symbol, value)
    }

    /// How long ago, in the same two-part shape the countdowns wear, so an age and a reset read as
    /// the same kind of number.
    public static func ageWords(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval))
        if seconds < 60 { return Localized.text("moments") }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
