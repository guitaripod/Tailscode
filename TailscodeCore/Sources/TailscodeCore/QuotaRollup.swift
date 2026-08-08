import CodingAgentKit
import Foundation

/// One provider's quota as the account holds it, with the machines that answered for it.
public struct QuotaHolding: Sendable, Equatable {
    public let quota: UsageQuota
    public let machines: [String]

    public init(quota: UsageQuota, machines: [String]) {
        self.quota = quota
        self.machines = machines
    }

    /// The hottest window in this provider's quota — how close the account is to a wall, and the
    /// order a reader wants these in.
    public var peak: Double {
        quota.gauges.map(\.fraction).max() ?? 0
    }

    public var isShared: Bool { machines.count > 1 }
}

/// A limit belongs to the account, not to the machine that happened to be asked. Every server
/// signed into the same provider reports the same windows, so a card per machine says one true
/// thing three times and wears a hostname that carries no information — the reader already knows
/// which machines they own. The rollup folds every server's report into one holding per provider,
/// keeping the strictest reading of each window and the most trustworthy reset, and remembers who
/// answered so a surface can name machines only when there is more than one to name.
public enum QuotaRollup {
    /// One holding per provider, tightest window first, from every server's report.
    public static func account(from reports: [(String, UsageQuota)]) -> [QuotaHolding] {
        var order: [String] = []
        var folded: [String: UsageQuota] = [:]
        var machines: [String: [String]] = [:]
        for (server, quota) in reports {
            let key = family(of: quota)
            if let existing = folded[key] {
                folded[key] = fold(existing, quota)
            } else {
                folded[key] = quota
                order.append(key)
            }
            var reporters = machines[key] ?? []
            if !server.isEmpty, !reporters.contains(server) { reporters.append(server) }
            machines[key] = reporters
        }
        return
            order
            .compactMap { key in
                folded[key].map { QuotaHolding(quota: $0, machines: machines[key] ?? []) }
            }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.peak == rhs.element.peak
                    ? lhs.offset < rhs.offset : lhs.element.peak > rhs.element.peak
            }
            .map(\.element)
    }

    /// The window across the whole account that is closest to its wall — the one that decides
    /// when the next send unlocks.
    public static func tightest(in holdings: [QuotaHolding])
        -> (holding: QuotaHolding, gauge: UsageQuota.Gauge)?
    {
        holdings
            .flatMap { holding in holding.gauges.map { (holding, $0) } }
            .max { $0.1.fraction < $1.1.fraction }
    }

    /// Where the numbers came from: the provider's own source, and the machines that answered
    /// only when more than one did — naming the single server a person has is noise.
    public static func provenance(_ holding: QuotaHolding) -> String {
        guard holding.isShared else { return holding.quota.source }
        return "\(holding.quota.source) · \(holding.machines.joined(separator: ", "))"
    }

    private static func family(of quota: UsageQuota) -> String {
        ProviderBrand.slug(quota.providerName) ?? quota.providerName.lowercased()
    }

    /// Two reports of one account. A live report outranks an estimated one for the identity the
    /// card wears; the windows themselves merge one by one.
    private static func fold(_ base: UsageQuota, _ next: UsageQuota) -> UsageQuota {
        var result = base
        if !base.live, next.live {
            result.providerName = next.providerName
            result.source = next.source
            result.subtitle = next.subtitle.isEmpty ? base.subtitle : next.subtitle
        } else if result.subtitle.isEmpty {
            result.subtitle = next.subtitle
        }
        result.live = base.live || next.live

        var gauges = base.gauges
        for gauge in next.gauges {
            if let index = gauges.firstIndex(where: { window($0) == window(gauge) }) {
                gauges[index] = fold(gauges[index], gauge)
            } else {
                gauges.append(gauge)
            }
        }
        result.gauges = gauges

        var details = base.details
        for detail in next.details where !details.contains(where: { $0.key == detail.key }) {
            details.append(detail)
        }
        result.details = details
        return result
    }

    /// The same window seen twice: the account has spent the larger of the two, and a reset the
    /// provider actually stated beats one a backend guessed.
    private static func fold(_ base: UsageQuota.Gauge, _ next: UsageQuota.Gauge)
        -> UsageQuota.Gauge
    {
        var winner = next.fraction > base.fraction ? next : base
        let other = next.fraction > base.fraction ? base : next
        if other.trustedReset, !winner.trustedReset, let reset = other.resetsAt {
            winner.resetsAt = reset
            winner.trustedReset = true
        } else if winner.resetsAt == nil, let reset = other.resetsAt {
            winner.resetsAt = reset
            winner.trustedReset = other.trustedReset
        }
        if winner.usedUSD == nil { winner.usedUSD = other.usedUSD }
        if winner.limitUSD == nil { winner.limitUSD = other.limitUSD }
        return winner
    }

    private static func window(_ gauge: UsageQuota.Gauge) -> String {
        gauge.key.isEmpty ? gauge.label.lowercased() : gauge.key
    }
}

extension QuotaHolding {
    public var gauges: [UsageQuota.Gauge] { quota.gauges }
    public var providerName: String { quota.providerName }
    public var slug: String? { ProviderBrand.slug(quota.providerName) }
}
