import CodingAgentKit
import Foundation
import TailscodeCore

/// Pulls the account's whole ledger from every saved Claude Code bridge at once — each
/// machine holds its own transcripts, so the month only adds up when all of them answer.
/// Every bridge is queried concurrently and a fired deadline keeps the partial haul; a
/// bridge too old for the route is named so its absence is a stated fact, while an
/// unreachable one simply isn't part of this pass.
enum AnalyticsFetcher {
    struct Haul: Sendable {
        let servers: [(name: String, report: UsageAnalyticsReport)]
        let missing: [String]
    }

    private enum Answer: Sendable {
        case report(index: Int, name: String, report: UsageAnalyticsReport)
        case tooOld(index: Int, name: String)
        case unreachable
    }

    private static let policy = ConnectionPolicy(
        requestTimeout: .seconds(25), resourceTimeout: .seconds(30))

    @MainActor
    static func fetch(
        days: Int = UsageAnalytics.defaultWindowDays, deadline: TimeInterval = 30
    ) async -> Haul {
        let controller = ConnectionController.shared
        var seen = Set<URL>()
        let bridges = controller.profiles
            .filter { $0.backend == .claudeCode && seen.insert($0.baseURL).inserted }
            .enumerated()
            .compactMap { index, profile in
                controller.makeBackend(for: profile, policy: policy).map {
                    (index: index, name: profile.name, backend: $0)
                }
            }
        guard !bridges.isEmpty else { return Haul(servers: [], missing: []) }
        let answers = await withTaskGroup(of: Answer?.self) { group in
            for (index, name, backend) in bridges {
                group.addTask {
                    do {
                        guard let report = try await backend.usageAnalytics(days: days) else {
                            return .tooOld(index: index, name: name)
                        }
                        return .report(index: index, name: name, report: report)
                    } catch {
                        return .unreachable
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            var collected: [Answer] = []
            while collected.count < bridges.count, let answer = await group.next() {
                guard let answer else { break }
                collected.append(answer)
            }
            group.cancelAll()
            return collected
        }
        var servers: [(index: Int, name: String, report: UsageAnalyticsReport)] = []
        var missing: [(index: Int, name: String)] = []
        for answer in answers {
            switch answer {
            case .report(let index, let name, let report):
                servers.append((index, name, report))
            case .tooOld(let index, let name):
                missing.append((index, name))
            case .unreachable:
                break
            }
        }
        AppLogger.session.info(
            "analytics: \(servers.count)/\(bridges.count) bridge(s) reported, \(missing.count) too old")
        return Haul(
            servers: servers.sorted { $0.index < $1.index }.map { ($0.name, $0.report) },
            missing: missing.sorted { $0.index < $1.index }.map(\.name))
    }
}
