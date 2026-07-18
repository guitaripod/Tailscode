import CodingAgentKit
import Foundation

struct UsageSample: Sendable {
    let cost: Double
    let createdAt: Date
    let tokens: Int
}

struct UsageScanResult {
    var samples: [UsageSample]
    var timedOut: Int
    var failed: Int
    var scannedHosts: [String] = []
    var failedHosts: [String] = []

    var unavailable: Int { timedOut + failed }
}

enum UsageScanner {
    private static let concurrency = 6
    private static let opencodeProviderID = "opencode-go"

    /// `background` trims the scan to fit a ~30-second `BGAppRefreshTask` window;
    /// the trimmed tail covers the 5-hour window authoritatively but undercounts
    /// weekly/monthly, so a partial scan refreshes 5-hour and only ratchets the
    /// longer gauges upward against the stored snapshot.
    struct Budget: Sendable {
        var sessionLimit = 40
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
            merged.scannedHosts.append(name)
        }
        guard !merged.scannedHosts.isEmpty else {
            AppLogger.session.error(
                "usage: opencode scan failed on every host (\(merged.failedHosts.joined(separator: ", ")))")
            return nil
        }
        AppLogger.session.info(
            "usage: opencode scan merged \(merged.samples.count) samples from \(merged.scannedHosts.joined(separator: " + "))"
                + (merged.failedHosts.isEmpty ? "" : " — unreachable: \(merged.failedHosts.joined(separator: ", "))"))
        writeOpencodeGauges(result: merged, partial: budget.isPartial, reload: reload)
        return merged
    }

    private static func collect(backend: any CodingAgentBackend, budget: Budget) async throws -> UsageScanResult {
        let sessions = try await backend.listSessions()
        let scanned = Array(sessions.prefix(budget.sessionLimit))
        let result = await scan(backend: backend, sessions: scanned, budget: budget)
        return result
    }

    private static func scan(
        backend: any CodingAgentBackend, sessions: [AgentSession], budget: Budget
    ) async -> UsageScanResult {
        let timeout = budget.perRequestTimeout
        return await withTaskGroup(of: SessionOutcome.self) { group in
            var pending = sessions.makeIterator()

            func schedule() {
                guard let session = pending.next() else { return }
                group.addTask {
                    let outcome = await withTimeout(timeout) { () async -> SessionOutcome? in
                        do { return .samples(try await opencodeSamples(backend: backend, session: session)) } catch { return .failed }
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
        backend: any CodingAgentBackend, session: AgentSession
    ) async throws -> [UsageSample] {
        let messages = try await backend.messages(for: session.id)
        return messages.compactMap { message in
            guard message.providerID == opencodeProviderID, let cost = message.costUSD else { return nil }
            return UsageSample(cost: cost, createdAt: message.createdAt, tokens: message.totalTokens ?? 0)
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

    private static func writeOpencodeGauges(result: UsageScanResult, partial: Bool, reload: Bool) {
        let now = Date()
        let windows: [(String, TimeInterval, Double)] = [
            ("5-hour", 5 * 3600, 12),
            ("Weekly", 7 * 24 * 3600, 30),
            ("Monthly", 30 * 24 * 3600, 60),
        ]
        var gauges = windows.map { name, seconds, cap in
            let cutoff = now.addingTimeInterval(-seconds)
            let inWindow = result.samples.filter { $0.createdAt >= cutoff }
            let spend = inWindow.reduce(0) { $0 + $1.cost }
            let fraction = cap > 0 ? min(1, spend / cap) : 0
            return UsageWidgetEntry.GaugeSnapshot(
                label: name,
                fraction: fraction,
                percentText: "\(Int((fraction * 100).rounded()))%",
                caption: "\(currency(spend)) / \(currency(cap)) \u{00b7} \(inWindow.count) req",
                resetsAt: nil)
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
