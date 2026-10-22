import CodingAgentKit
import Foundation

/// How old a quota reading may be, in one place for every surface that says so: the strip, the
/// widget's badge and the snapshot the widget is drawn from all read these two numbers, so a
/// reading cannot be fresh on the phone and cached on the lock screen.
public enum QuotaFreshness {
    /// Past this a reading says how old it is even though it is all there is.
    public static let staleAfter: TimeInterval = 600
    /// A last good reading is served, marked cached, until it is this old. Past it, a figure from
    /// yesterday is worse than no figure, and it is dropped.
    public static let keptFor: TimeInterval = 86_400

    public static func isStale(age: TimeInterval) -> Bool { age >= staleAfter }

    public static func isKept(age: TimeInterval) -> Bool { age < keptFor }
}

extension UsageQuota {
    /// Whether this is the account's own number. A bridge whose provider API is unreachable
    /// answers with a figure it worked out from a database on its own disk, and stored beside the
    /// account's numbers an estimate is indistinguishable from one; every surface asks this one
    /// question, so none of them can disagree about what counts as measured.
    public var isMeasured: Bool { !source.lowercased().contains("estimated") }

    public var hasNumbers: Bool { !gauges.isEmpty }

    /// A read that failed for a reason that may not hold the next time. A key that expired or an
    /// account that does not exist is a fact about the account, and a cached figure would hide it.
    public var failedTransiently: Bool {
        guard !hasNumbers else { return false }
        switch errorCode {
        case "key_expired", "no_subscription", "no_account": return false
        default: return true
        }
    }
}

/// What a client does with a report before it keeps or shows it.
public enum QuotaReports {
    /// An estimate is never shown as the account's numbers, and it is never silently dropped
    /// either: a provider whose only reading is an estimate stays on the board as a line that says
    /// there is no measured reading.
    public static func admitted(_ quota: UsageQuota) -> UsageQuota {
        guard !quota.isMeasured else { return quota }
        return UsageQuota(
            providerName: quota.providerName, subtitle: quota.subtitle, source: "unmeasured",
            live: false, gauges: [], details: [],
            error: Localized.text("No measured reading"), errorCode: "estimate_only",
            accountID: quota.accountID, schema: quota.schema)
    }

    public static func admitted(_ quotas: [UsageQuota]) -> [UsageQuota] {
        quotas.map(admitted)
    }
}

/// A last good reading, with the machine that gave it and when.
public struct HeldReading: Sendable, Equatable {
    public let server: String
    public let quota: UsageQuota
    public let readAt: Date

    public init(server: String, quota: UsageQuota, readAt: Date) {
        self.server = server
        self.quota = quota
        self.readAt = readAt
    }
}

/// A failed read keeps the last good numbers. A timed-out machine or an unreachable provider is
/// the commonest thing a poll can meet, and a surface that answers it by deleting the provider
/// turns a hiccup into a hole; instead the last measured reading is served, marked cached, until
/// ``QuotaFreshness/keptFor`` says it is too old.
public enum QuotaKeeping {
    public enum Move: Sendable, Equatable {
        case write
        case keep
        case drop
    }

    /// What a store of last readings does with a report: a measured reading replaces what it held
    /// for that account, and a failed one leaves it alone until it is too old to be worth keeping.
    public static func move(for quota: UsageQuota, heldAt: Date?, now: Date) -> Move {
        if quota.hasNumbers, quota.isMeasured { return .write }
        guard let heldAt else { return .keep }
        return QuotaFreshness.isKept(age: now.timeIntervalSince(heldAt)) ? .keep : .drop
    }

    /// The reports to show: each one that failed for a reason that may pass, and that no other
    /// machine answered for, is replaced by the last reading its machine gave, marked cached.
    public static func carry(
        _ fresh: [(String, UsageQuota)], held: [HeldReading], now: Date
    ) -> [(String, UsageQuota)] {
        fresh.map { server, quota in
            guard quota.failedTransiently,
                !fresh.contains(where: { $0.1.hasNumbers && same($0.1, quota) }),
                let reading = held.first(where: {
                    same($0.quota, quota) && sameMachine($0.server, server)
                        && QuotaFreshness.isKept(age: now.timeIntervalSince($0.readAt))
                })
            else { return (server, quota) }
            var cached = reading.quota
            cached.live = false
            cached.error = nil
            cached.errorCode = nil
            return (server, cached)
        }
    }

    /// The readings worth holding after a poll: every measured report of this poll, and whatever
    /// was held that this poll did not replace and that is not yet too old.
    public static func remember(
        _ fresh: [(String, UsageQuota)], into held: [HeldReading], now: Date
    ) -> [HeldReading] {
        let landed = fresh.filter { $0.1.hasNumbers && $0.1.isMeasured }
        let kept = held.filter { reading in
            QuotaFreshness.isKept(age: now.timeIntervalSince(reading.readAt))
                && !landed.contains { sameMachine($0.0, reading.server) && same($0.1, reading.quota) }
        }
        return kept + landed.map { HeldReading(server: $0.0, quota: $0.1, readAt: now) }
    }

    private static func same(_ lhs: UsageQuota, _ rhs: UsageQuota) -> Bool {
        QuotaBoard.key(providerName: lhs.providerName) == QuotaBoard.key(providerName: rhs.providerName)
            && accountsAgree(lhs.accountID, rhs.accountID)
    }

    private static func accountsAgree(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, !lhs.isEmpty, let rhs, !rhs.isEmpty else { return true }
        return lhs == rhs
    }

    private static func sameMachine(_ lhs: String, _ rhs: String) -> Bool {
        lhs.isEmpty || rhs.isEmpty || lhs == rhs
    }
}
