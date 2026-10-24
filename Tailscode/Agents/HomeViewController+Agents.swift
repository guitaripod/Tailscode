import CodingAgentKit
import TailscodeCore
import UIKit

extension HomeViewController: AgentsListSource {
    func registerAgents() { AgentsHub.shared.register(self) }

    func agentsSnapshot() -> AgentsSnapshot {
        let isUnread = SessionSeenStore.unreadEvaluator()
        let servers = viewModel.servers
        var backends: [String: any CodingAgentBackend] = [:]
        for server in servers {
            if let backend = viewModel.backend(forProfileID: server.id) { backends[server.id] = backend }
        }
        let reachability: [String: Bool] =
            hasLoadedOnce
            ? Dictionary(
                servers.map { ($0.id, !viewModel.unreachable.contains($0.id)) },
                uniquingKeysWith: { first, _ in first })
            : [:]
        let unread = Set(
            viewModel.entries.filter { isUnread($0.session.id, $0.session.updatedAt) }
                .map { "\($0.profileID)/\($0.session.id)" })
        return AgentsSnapshot(
            entries: viewModel.entries, reachability: reachability, unread: unread,
            backends: backends, heard: viewModel.observedAt)
    }

    func presentAgents() { AgentsPresenter.present(from: self) }
}
