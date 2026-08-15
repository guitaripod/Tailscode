import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The extension's own road to the numbers.
///
/// A widget is rendered at a moment nobody chose, in a process the app never started, so waiting to
/// be handed a snapshot is waiting for a window to be open — which is the whole thing this surface
/// exists to spare somebody. It therefore reads the same profile store the Mac app writes (the Kit's
/// own directory in Application Support, which is where `ServerDirectory` puts it) and asks each
/// machine itself, every one at once behind one deadline so a sleeping server cannot starve the
/// reachable ones.
///
/// Where the extension cannot reach a password — the data-protection keychain scopes an item to the
/// access group of the process that wrote it, and an unsigned build shares none — the fetch simply
/// comes back with less, or with nothing, and the stored snapshot is served instead. That is not an
/// error state: it is exactly what the reading's CACHED badge already says out loud.
enum MacWidgetQuotas {
    private static let policy = ConnectionPolicy(
        requestTimeout: .seconds(8), resourceTimeout: .seconds(12))

    static func fetch(deadline: TimeInterval) async -> [UsageQuota] {
        guard let store = try? ConnectionProfileStore(),
            let profiles = try? store.profiles(), !profiles.isEmpty
        else { return [] }
        let servers = profiles.enumerated().compactMap { index, profile in
            (try? store.makeBackend(profile, policy: policy)).map { (index, profile.name, $0) }
        }
        guard !servers.isEmpty else { return [] }
        let landed = await withTaskGroup(
            of: (index: Int, server: String, quotas: [UsageQuota])?.self
        ) { group in
            for (index, name, backend) in servers {
                group.addTask { (index, name, await report(from: backend)) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            var collected: [(index: Int, server: String, quotas: [UsageQuota])] = []
            while collected.count < servers.count, let outcome = await group.next() {
                guard let outcome else { break }
                collected.append(outcome)
            }
            group.cancelAll()
            return collected
        }
        let reports = landed.sorted { $0.index < $1.index }
            .flatMap { entry in entry.quotas.map { (entry.server, $0) } }
        return QuotaRollup.account(from: reports).map(\.quota)
    }

    /// A machine that cannot reach its provider's own usage API answers with a figure it worked out
    /// from a database on its own disk. It is not the account's number, and stored beside the
    /// account's numbers it is indistinguishable from one — so the widget takes the measurement or
    /// nothing at all.
    private static func report(from backend: any CodingAgentBackend) async -> [UsageQuota] {
        var fetched: [UsageQuota] = []
        if let primary = (try? await backend.usageQuota()) ?? nil { fetched.append(primary) }
        fetched += (try? await backend.additionalUsageQuotas()) ?? []
        return fetched.filter { !$0.source.lowercased().contains("estimated") }
    }
}
