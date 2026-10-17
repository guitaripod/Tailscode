import CodingAgentKit
import Foundation

/// What has already been said about each quota window, so that a window which will run out before
/// it resets is announced once and not once per poll.
///
/// A projection wobbles. A rate that sits near the line crosses it, comes back and crosses again
/// as the work comes in bursts, and a notice per crossing would be a notice per afternoon. So a
/// window is announced the first time its pace says it will run out, is not announced again for
/// the rest of that window, and is re-armed only once the projection has stayed comfortably under
/// the limit for half an hour — which is a real change of course, not a wobble. A window that
/// resets is a different window and starts over.
public struct RunningLowLedger: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var windowEnd: Date
        public var announced: Bool
        public var calmSince: Date?
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    fileprivate mutating func set(_ entry: Entry, for id: String) {
        entries[id] = entry
    }

    fileprivate mutating func forget(before cutoff: Date) {
        entries = entries.filter { $0.value.windowEnd >= cutoff }
    }
}

/// One announcement: which window, when it will run out at the pace so far, and the words.
public struct RunningLowNotice: Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: String
    public let window: String
    public let wallAt: Date
    public let resetsAt: Date
    public let title: String
    public let body: String
}

public enum RunningLow {
    /// A projection that has stayed under this share of the limit is a change of course.
    public static let calmBelow = 0.9
    public static let calmFor: TimeInterval = 1800
    private static let keepAfterReset: TimeInterval = 86_400

    /// The windows to announce now, updating what has been said.
    ///
    /// Only windows that meter the whole account are announced: a model's own window running low
    /// is news in a chat on that model, where the chip says it, and a notice for it would be
    /// shouting about a wall that most of what the person does never touches. A window already used
    /// up is not announced either — the wall has its own notice.
    public static func decide(
        quotas: [UsageQuota], ledger: inout RunningLowLedger, trail: QuotaTrail? = nil,
        now: Date = Date(), clock: RangeClock = .current
    ) -> [RunningLowNotice] {
        var notices: [RunningLowNotice] = []
        for quota in quotas {
            for gauge in quota.gauges {
                guard gauge.usedUSD == nil || gauge.limitUSD != nil,
                    QuotaBinding.scope(of: gauge) == .account,
                    let pace = QuotaPace.read(
                        gauge, provider: quota.providerName, now: now, trail: trail,
                        calendar: clock.calendar)
                else { continue }
                let id = QuotaTrail.identity(provider: quota.providerName, gauge: gauge)
                var entry = ledger.entries[id]
                if let held = entry,
                    abs(held.windowEnd.timeIntervalSince(pace.resetsAt)) >= pace.span / 2
                {
                    entry = nil
                }
                var current =
                    entry ?? RunningLowLedger.Entry(
                        windowEnd: pace.resetsAt, announced: false, calmSince: nil)
                current.windowEnd = pace.resetsAt

                switch pace.verdict {
                case .willRunOut(let wallAt):
                    current.calmSince = nil
                    if !current.announced {
                        current.announced = true
                        notices.append(
                            notice(
                                id: id, quota: quota, gauge: gauge, pace: pace, wallAt: wallAt,
                                now: now, clock: clock))
                    }
                case .wall:
                    current.announced = true
                    current.calmSince = nil
                case .tooEarly, .onPace, .closeToTheLine:
                    if current.announced {
                        if (pace.landing ?? 0) < calmBelow {
                            let since = current.calmSince ?? now
                            current.calmSince = since
                            if now.timeIntervalSince(since) >= calmFor {
                                current.announced = false
                                current.calmSince = nil
                            }
                        } else {
                            current.calmSince = nil
                        }
                    }
                }
                ledger.set(current, for: id)
            }
        }
        ledger.forget(before: now.addingTimeInterval(-keepAfterReset))
        return notices
    }

    private static func notice(
        id: String, quota: UsageQuota, gauge: UsageQuota.Gauge, pace: QuotaPace, wallAt: Date,
        now: Date, clock: RangeClock
    ) -> RunningLowNotice {
        RunningLowNotice(
            id: id, provider: quota.providerName, window: gauge.label, wallAt: wallAt,
            resetsAt: pace.resetsAt,
            title: Localized.text("%@ %@ is running low", quota.providerName, gauge.label),
            body: Localized.text(
                "At this pace it runs out %@, %@.",
                RangeWords.wallWhen(wallAt, now: now, clock: clock),
                RangeWords.slackPhrase(pace, wallAt: wallAt)))
    }
}
