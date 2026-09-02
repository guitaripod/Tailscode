import CodingAgentKit
import Foundation
import TailscodeCore

/// Pulls the account's whole ledger from every saved server at once — each machine holds its own
/// transcripts, so the month only adds up when all of them answer, and every model the person
/// runs belongs in it whichever agent served it. Every server is queried concurrently and a fired
/// deadline keeps the partial haul; one too old for the route is named so its absence is a stated
/// fact, while an unreachable one simply isn't part of this pass.
enum AnalyticsFetcher {
    struct Haul: Sendable {
        let servers: [(name: String, report: UsageAnalyticsReport)]
        let missing: [String]
    }

    private enum Answer: Sendable {
        case report(index: Int, name: String, report: UsageAnalyticsReport)
        case tooOld(index: Int, name: String)
        case unreadable(index: Int, name: String)
        case unreachable
    }

    private static let policy = ConnectionPolicy(
        requestTimeout: .seconds(25), resourceTimeout: .seconds(30))

    @MainActor
    static func fetch(
        window: UsageWindow = .current, deadline: TimeInterval = 30
    ) async -> Haul {
        let days = window.days
        let controller = ConnectionController.shared
        var seen = Set<URL>()
        let servers = controller.profiles
            .filter { seen.insert($0.baseURL).inserted }
            .enumerated()
            .compactMap { index, profile in
                controller.makeBackend(for: profile, policy: policy).map {
                    (index: index, name: ServerLabel.display(profile), backend: $0)
                }
            }
        guard !servers.isEmpty else { return Haul(servers: [], missing: []) }
        let answers = await withTaskGroup(of: Answer?.self) { group in
            for (index, name, backend) in servers {
                group.addTask {
                    do {
                        guard let report = try await backend.usageAnalytics(days: days) else {
                            return .tooOld(index: index, name: name)
                        }
                        return .report(index: index, name: name, report: report)
                    } catch AgentError.decoding(let detail) {
                        AppLogger.session.error("analytics: \(name) answered unreadably: \(detail)")
                        return .unreadable(index: index, name: name)
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
            while collected.count < servers.count, let answer = await group.next() {
                guard let answer else { break }
                collected.append(answer)
            }
            group.cancelAll()
            return collected
        }
        var reported: [(index: Int, name: String, report: UsageAnalyticsReport)] = []
        var missing: [(index: Int, name: String)] = []
        for answer in answers {
            switch answer {
            case .report(let index, let name, let report):
                reported.append((index, name, report))
            case .tooOld(let index, let name), .unreadable(let index, let name):
                missing.append((index, name))
            case .unreachable:
                break
            }
        }
        AppLogger.session.info(
            "analytics: \(reported.count)/\(servers.count) server(s) reported, "
                + "\(missing.count) too old")
        return Haul(
            servers: reported.sorted { $0.index < $1.index }.map { ($0.name, $0.report) },
            missing: missing.sorted { $0.index < $1.index }.map(\.name))
    }
}
