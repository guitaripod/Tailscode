import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Fetches live provider quotas (Claude, Grok) straight from every saved Claude Code
/// bridge and folds them into the account's own numbers — a limit belongs to the account, not
/// to the machine that answered first. Compiled into both the app and the widget extension, so
/// widget timeline reloads and background refreshes can pull fresh numbers without the app ever
/// foregrounding.
enum LiveQuotaFetcher {
    private static let policy = ConnectionPolicy(
        requestTimeout: .seconds(8), resourceTimeout: .seconds(12))

    /// Returns whatever was fetched by the time `deadline` elapses: every bridge is
    /// queried concurrently and each one's results land as they arrive, so a dead
    /// bridge can't starve the reachable ones and a fired deadline keeps the
    /// partial haul. An unreachable tailnet yields `[]` and the caller keeps
    /// serving its stored snapshot.
    static func fetch(deadline: TimeInterval) async -> [UsageQuota] {
        async let deepseek: Void = DeepSeekBalance.refresh()
        guard
            let store = try? SharedConnectionStore.make(),
            let profiles = try? store.profiles()
        else {
            _ = await deepseek
            return []
        }
        let bridges = profiles.filter { $0.backend == .claudeCode }.enumerated()
            .compactMap { index, profile in
                (try? store.makeBackend(profile, policy: policy)).map { (index, profile.name, $0) }
            }
        guard !bridges.isEmpty else {
            _ = await deepseek
            return []
        }
        let results = await withTaskGroup(
            of: (index: Int, server: String, quotas: [UsageQuota])?.self
        ) { group in
            for (index, name, backend) in bridges {
                group.addTask { (index, name, await fetchQuotas(from: backend)) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            var collected: [(index: Int, server: String, quotas: [UsageQuota])] = []
            while collected.count < bridges.count, let outcome = await group.next() {
                guard let outcome else { break }
                collected.append(outcome)
            }
            group.cancelAll()
            return collected
        }
        let reports = results.sorted(by: { $0.index < $1.index })
            .flatMap { entry in entry.quotas.map { (entry.server, $0) } }
        _ = await deepseek
        return QuotaRollup.account(from: reports).map(\.quota)
    }

    private static func fetchQuotas(from backend: any CodingAgentBackend) async -> [UsageQuota] {
        var fetched: [UsageQuota] = []
        if let primary = try? await backend.usageQuota() { fetched.append(primary) }
        if let extra = try? await backend.additionalUsageQuotas() {
            fetched.append(contentsOf: extra)
        }
        return fetched
    }
}
