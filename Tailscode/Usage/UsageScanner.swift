import CodingAgentKit
import Foundation

struct UsageSample: Sendable {
    let cost: Double
    let createdAt: Date
    let tokens: Int
    let modelID: String
    let weight: Double

    /// What the request costs against the plan's caps: Go bills some models at a
    /// multiple of their dollar cost.
    var weightedCost: Double { cost * weight }
}

/// A model whose spend counts against the caps at more than face value, as Go
/// advertises it in the provider list ("Kimi K3 (2x usage)").
struct UsageMultiplier: Sendable {
    let modelID: String
    let displayName: String
    let weight: Double
}

/// The Go plan's account-wide dollar caps. The monthly figure is a promotional
/// value for the first subscription month, so it is user-configurable.
enum GoCaps {
    static let rollingCap: Double = 12
    static let weeklyCap: Double = 30
    static var monthlyCap: Double { AppPreferences.goMonthlyCap }
    /// Day of the month the subscription renews; `0` infers it from the oldest
    /// Go request on record.
    static var billingDay: Int { AppPreferences.goBillingDay }

    /// Identity of the configured caps, so a screen or a stored snapshot built
    /// against the old numbers can tell that it is describing a different plan.
    static var signature: String { "\(monthlyCap)|\(billingDay)" }
}

struct UsageScanResult {
    var samples: [UsageSample]
    var timedOut: Int
    var failed: Int
    var scannedHosts: [String] = []
    var failedHosts: [String] = []
    var multipliers: [String: UsageMultiplier] = [:]

    var unavailable: Int { timedOut + failed }
}

enum UsageScanner {
    private static let concurrency = 6
    private static let opencodeProviderID = "opencode-go"
    /// Enough history to cover the longest window plus the idle gap that anchors
    /// the 5-hour block.
    private static let historySpan: TimeInterval = 31 * 24 * 3600
    private static let fallbackMultipliers: [String: UsageMultiplier] = [
        "kimi-k3": UsageMultiplier(modelID: "kimi-k3", displayName: "Kimi K3", weight: 2)
    ]

    /// Go's dollar-cap windows; the single definition behind the Home card, the
    /// Usage screen gauges, and the widget snapshots.
    struct Window: Sendable {
        /// How the window's start is anchored: a block that opens at the first
        /// request following an idle gap of its own length, a plain trailing
        /// span, or the subscription's billing cycle.
        enum Kind: Sendable {
            case rollingBlock(TimeInterval)
            case trailing(TimeInterval)
            case billingCycle
        }

        let name: String
        let kind: Kind
        let cap: Double
    }

    static var windows: [Window] {
        [
            Window(name: "5-hour", kind: .rollingBlock(5 * 3600), cap: GoCaps.rollingCap),
            Window(name: "Weekly", kind: .trailing(7 * 24 * 3600), cap: GoCaps.weeklyCap),
            Window(name: "Monthly", kind: .billingCycle, cap: GoCaps.monthlyCap),
        ]
    }

    /// `background` trims the scan to fit a ~30-second `BGAppRefreshTask` window;
    /// the trimmed tail covers the 5-hour window authoritatively but undercounts
    /// weekly/monthly, so a partial scan refreshes 5-hour and only ratchets the
    /// longer gauges upward against the stored snapshot.
    struct Budget: Sendable {
        var sessionLimit = 200
        var perRequestTimeout: TimeInterval = 12
        var isPartial = false

        static let background = Budget(sessionLimit: 12, perRequestTimeout: 6, isPartial: true)
    }

    /// Scans every opencode host and merges the samples before the gauges are
    /// written: the caps are account-wide, so a single host's spend understates
    /// them whenever more than one machine runs opencode.
    @discardableResult
    static func scanOpencode(
        backends: [(name: String, backend: any CodingAgentBackend)],
        budget: Budget = Budget(),
        reload: Bool = true
    ) async -> UsageScanResult? {
        var merged = UsageScanResult(samples: [], timedOut: 0, failed: 0)
        for (name, backend) in backends {
            guard let result = try? await collect(backend: backend, budget: budget) else {
                merged.failedHosts.append(name)
                continue
            }
            merged.samples.append(contentsOf: result.samples)
            merged.timedOut += result.timedOut
            merged.failed += result.failed
            merged.multipliers.merge(result.multipliers) { current, _ in current }
            merged.scannedHosts.append(name)
        }
        guard !merged.scannedHosts.isEmpty else {
            AppLogger.session.error(
                "usage: opencode scan failed on every host (\(merged.failedHosts.joined(separator: ", ")))")
            return nil
        }
        AppLogger.session.info(
            "usage: opencode scan merged \(merged.samples.count) samples from \(merged.scannedHosts.joined(separator: " + "))"
                + (merged.unavailable > 0
                    ? " — \(merged.timedOut) timed out, \(merged.failed) failed" : "")
                + (merged.failedHosts.isEmpty ? "" : " — unreachable: \(merged.failedHosts.joined(separator: ", "))"))
        writeOpencodeGauges(result: merged, partial: budget.isPartial, reload: reload)
        return merged
    }

    private static func collect(backend: any CodingAgentBackend, budget: Budget) async throws -> UsageScanResult {
        let multipliers = (try? await usageMultipliers(backend: backend)) ?? fallbackMultipliers
        let sessions = try await allSessions(backend: backend, budget: budget)
        let cutoff = Date().addingTimeInterval(-historySpan)
        let scanned = Array(
            sessions
                .filter { $0.updatedAt >= cutoff }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(budget.sessionLimit))
        var result = await scan(
            backend: backend, sessions: scanned, budget: budget, multipliers: multipliers)
        result.multipliers = multipliers
        return result
    }

    /// opencode scopes its session list to the project its server was launched
    /// in, so one call misses every other worktree's spend against an
    /// account-wide cap. Walk the projects too and union by id — the server's own
    /// project answers twice.
    private static func allSessions(
        backend: any CodingAgentBackend, budget: Budget
    ) async throws -> [AgentSession] {
        var byID: [String: AgentSession] = [:]
        for session in try await backend.listSessions() { byID[session.id] = session }
        let worktrees = ((try? await backend.projects()) ?? []).map(\.worktree)
        guard !worktrees.isEmpty else { return Array(byID.values) }
        let timeout = budget.perRequestTimeout
        let listed = await withTaskGroup(of: [AgentSession].self) { group in
            var pending = worktrees.makeIterator()

            func schedule() {
                guard let worktree = pending.next() else { return }
                group.addTask {
                    await withTimeout(timeout) { try? await backend.listSessions(inWorktree: worktree) }
                        ?? []
                }
            }

            for _ in 0..<concurrency { schedule() }
            var all: [AgentSession] = []
            for await sessions in group {
                all.append(contentsOf: sessions)
                schedule()
            }
            return all
        }
        for session in listed { byID[session.id] = session }
        return Array(byID.values)
    }

    /// Go publishes each model's cap weighting in its display name, so the
    /// provider list is the only place the multipliers can be read from. They are
    /// account-wide, which is why any reachable host answers for all of them.
    static func usageMultipliers(
        backend: any CodingAgentBackend
    ) async throws -> [String: UsageMultiplier] {
        guard let browsing = backend as? any FileBrowsingBackend else { return fallbackMultipliers }
        let pattern = #/\((\d+(?:\.\d+)?)x usage\)/#
        let models = try await browsing.providers()
            .first { $0.id == opencodeProviderID }?
            .models ?? []
        var parsed: [String: UsageMultiplier] = [:]
        for model in models {
            guard let match = model.name.firstMatch(of: pattern),
                let weight = Double(match.1), weight != 1
            else { continue }
            parsed[model.id] = UsageMultiplier(
                modelID: model.id, displayName: model.name, weight: weight)
        }
        return fallbackMultipliers.merging(parsed) { _, parsed in parsed }
    }

    private static func scan(
        backend: any CodingAgentBackend, sessions: [AgentSession], budget: Budget,
        multipliers: [String: UsageMultiplier]
    ) async -> UsageScanResult {
        let timeout = budget.perRequestTimeout
        return await withTaskGroup(of: SessionOutcome.self) { group in
            var pending = sessions.makeIterator()

            func schedule() {
                guard let session = pending.next() else { return }
                group.addTask {
                    let outcome = await withTimeout(timeout) { () async -> SessionOutcome? in
                        do {
                            return .samples(
                                try await opencodeSamples(
                                    backend: backend, session: session, multipliers: multipliers))
                        } catch { return .failed }
                    }
                    return outcome ?? .timedOut
                }
            }

            for _ in 0..<concurrency { schedule() }
            var result = UsageScanResult(samples: [], timedOut: 0, failed: 0)
            for await outcome in group {
                switch outcome {
                case .samples(let batch): result.samples.append(contentsOf: batch)
                case .timedOut: result.timedOut += 1
                case .failed: result.failed += 1
                }
                schedule()
            }
            return result
        }
    }

    private static func opencodeSamples(
        backend: any CodingAgentBackend, session: AgentSession,
        multipliers: [String: UsageMultiplier]
    ) async throws -> [UsageSample] {
        let messages = try await backend.messages(for: session.id)
        return messages.compactMap { message in
            guard message.providerID == opencodeProviderID, let cost = message.costUSD, cost > 0
            else { return nil }
            let modelID = message.modelID ?? ""
            return UsageSample(
                cost: cost, createdAt: message.createdAt, tokens: message.totalTokens ?? 0,
                modelID: modelID, weight: multipliers[modelID]?.weight ?? 1)
        }
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private enum SessionOutcome: Sendable {
        case samples([UsageSample])
        case timedOut
        case failed
    }

    /// The merged scan as a renderable quota, so Home and the Usage screen
    /// present the same combined cross-server estimate.
    static func quota(from result: UsageScanResult) -> UsageQuota {
        let now = Date()
        let gauges = windows.map { window -> UsageQuota.Gauge in
            let stats = windowStats(window, samples: result.samples, now: now)
            return UsageQuota.Gauge(
                key: window.name, label: window.name, fraction: stats.fraction,
                resetsAt: stats.resetsAt, trustedReset: false)
        }
        let hosts = result.scannedHosts.count
        return UsageQuota(
            providerName: UsageWidgetStore.opencodeProviderName,
            subtitle: hosts > 1
                ? String(localized: "$10/mo · estimated from \(hosts) servers")
                : String(localized: "$10/mo · estimated from this server"),
            source: "opencode.db estimate",
            live: false,
            gauges: gauges,
            details: [])
    }

    /// Weighted spend inside a window, the fraction of its cap that consumes, and
    /// when the window is expected to roll over. The single implementation behind
    /// every surface that renders Go's caps.
    static func windowStats(
        _ window: Window, samples: [UsageSample], now: Date
    ) -> (spend: Double, requests: Int, fraction: Double, resetsAt: Date?) {
        switch window.kind {
        case .rollingBlock(let span):
            guard let start = blockStart(samples: samples, idleGap: span) else {
                return (0, 0, 0, nil)
            }
            let end = start.addingTimeInterval(span)
            guard end > now else { return (0, 0, 0, nil) }
            return tally(
                samples.filter { $0.createdAt >= start && $0.createdAt < end },
                cap: window.cap, resetsAt: end)
        case .trailing(let span):
            let cutoff = now.addingTimeInterval(-span)
            return tally(samples.filter { $0.createdAt >= cutoff }, cap: window.cap, resetsAt: nil)
        case .billingCycle:
            let cycle = billingCycle(samples: samples, now: now)
            return tally(
                samples.filter { $0.createdAt >= cycle.start }, cap: window.cap,
                resetsAt: cycle.end)
        }
    }

    private static func tally(
        _ samples: [UsageSample], cap: Double, resetsAt: Date?
    ) -> (spend: Double, requests: Int, fraction: Double, resetsAt: Date?) {
        let spend = samples.reduce(0) { $0 + $1.weightedCost }
        return (spend, samples.count, cap > 0 ? min(1, spend / cap) : 0, resetsAt)
    }

    /// Go's 5-hour allowance is anchored, not trailing: it opens on the first
    /// request after an idle gap at least as long as the window and runs five
    /// hours from there. That is the newest sample preceded by such a gap, or the
    /// oldest sample when the account has never been idle that long.
    private static func blockStart(samples: [UsageSample], idleGap: TimeInterval) -> Date? {
        let times = samples.map(\.createdAt).sorted()
        guard var start = times.first else { return nil }
        for (previous, current) in zip(times, times.dropFirst())
        where current.timeIntervalSince(previous) >= idleGap {
            start = current
        }
        return start
    }

    /// The monthly cap follows the subscription's billing cycle rather than a
    /// trailing 30 days. Without an explicit setting the renewal day is inferred
    /// from the oldest Go request the scan has seen.
    private static func billingCycle(samples: [UsageSample], now: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let configured = GoCaps.billingDay
        let day = (1...31).contains(configured)
            ? configured
            : calendar.component(.day, from: samples.map(\.createdAt).min() ?? now)
        var start = anchoredDay(day, inMonthOf: now, calendar: calendar)
        if start > now, let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) {
            start = anchoredDay(day, inMonthOf: lastMonth, calendar: calendar)
        }
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        return (start, anchoredDay(day, inMonthOf: nextMonth, calendar: calendar))
    }

    /// Midnight on the given day of `date`'s month, clamped to the month's length
    /// so a 31st renewal still lands in February.
    private static func anchoredDay(_ day: Int, inMonthOf date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month], from: date)
        let length = calendar.range(of: .day, in: .month, for: date)?.count ?? 28
        components.day = min(day, length)
        components.hour = 0
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    private static func writeOpencodeGauges(result: UsageScanResult, partial: Bool, reload: Bool) {
        let now = Date()
        let computed = windows.map { ($0, windowStats($0, samples: result.samples, now: now)) }
        AppLogger.session.info(
            "usage: go gauges — "
                + computed.map { window, stats in
                    "\(window.name) \(UsageGaugeFormat.percentText(fraction: stats.fraction)) "
                        + "(\(currency(stats.spend))/\(currency(window.cap)), \(stats.requests) req)"
                }.joined(separator: " | "))
        var gauges = computed.map { window, stats in
            var caption = UsageGaugeFormat.spendCaption(
                spend: currency(stats.spend), cap: currency(window.cap),
                requests: stats.requests)
            let reset = UsageGaugeFormat.resetCaption(resetsAt: stats.resetsAt, trustedReset: false)
            if !reset.isEmpty { caption += " · \(reset)" }
            return UsageWidgetEntry.GaugeSnapshot(
                label: window.name,
                fraction: stats.fraction,
                percentText: UsageGaugeFormat.percentText(fraction: stats.fraction),
                caption: caption,
                resetsAt: stats.resetsAt)
        }
        if partial { gauges = ratchetedAgainstStored(gauges) }
        UsageWidgetStore.writeOpencode(gauges: gauges, reload: reload)
    }

    /// A budget-trimmed scan sees too few sessions to recompute the long windows;
    /// keep whichever of the recomputed and stored weekly/monthly gauges reads
    /// higher, while the 5-hour gauge is always replaced.
    private static func ratchetedAgainstStored(
        _ gauges: [UsageWidgetEntry.GaugeSnapshot]
    ) -> [UsageWidgetEntry.GaugeSnapshot] {
        guard
            let stored = UsageWidgetStore.read()?.providers
                .first(where: { $0.providerName == UsageWidgetStore.opencodeProviderName })
        else { return gauges }
        return gauges.map { gauge in
            guard gauge.label != "5-hour",
                let existing = stored.gauges.first(where: { $0.label == gauge.label }),
                existing.fraction > gauge.fraction
            else { return gauge }
            return existing
        }
    }

    private static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
