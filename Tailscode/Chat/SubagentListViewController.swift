import CodingAgentKit
import UIKit

/// The subagents a session has spawned, each opening as a read-only live
/// transcript rendered by the regular chat UI.
@MainActor
final class SubagentListViewController: UIViewController {
    private enum Section { case main }

    private let backend: any CodingAgentBackend
    private let parentSessionID: String
    private var agents: [SubagentSummary]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, SubagentSummary>!
    private var refreshTask: Task<Void, Never>?

    init(backend: any CodingAgentBackend, parentSessionID: String, agents: [SubagentSummary]) {
        self.backend = backend
        self.parentSessionID = parentSessionID
        self.agents = agents
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Agents"
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        configureCollectionView()
        configureDataSource()
        applySnapshot()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.reload()
            }
        }
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_AGENTS"] == "first",
                let first = agents.first
            {
                open(first)
            }
        #endif
    }

    deinit { refreshTask?.cancel() }

    private func reload() async {
        guard let fresh = try? await backend.subagents(for: parentSessionID) else { return }
        agents = fresh
        applySnapshot()
    }

    private func configureCollectionView() {
        let config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, SubagentSummary> {
            cell, _, agent in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = agent.title
            content.textProperties.font = Theme.Font.body()
            content.textProperties.numberOfLines = 2
            var parts: [String] = []
            if agent.isCompleted {
                parts.append("finished \(agent.updatedAt.formatted(.relative(presentation: .named)))")
            } else if agent.isActive {
                parts.append("working")
            } else {
                parts.append("idle since \(agent.updatedAt.formatted(.relative(presentation: .named)))")
            }
            if let type = agent.agentType { parts.append(type) }
            content.secondaryText = parts.joined(separator: " · ")
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
            content.secondaryTextProperties.color =
                agent.isActive ? Theme.Color.success : Theme.Color.tertiaryLabel
            content.textToSecondaryTextVerticalPadding = 2
            if agent.isCompleted {
                content.image = UIImage(systemName: "checkmark.circle.fill")
                content.imageProperties.tintColor = Theme.Color.success
                content.imageProperties.maximumSize = CGSize(width: 16, height: 16)
                content.imageProperties.reservedLayoutSize = CGSize(width: 16, height: 16)
            } else {
                content.image = UIImage(systemName: "circle.fill")
                content.imageProperties.tintColor =
                    agent.isActive ? Theme.Color.success : Theme.Color.separator
                content.imageProperties.maximumSize = CGSize(width: 10, height: 10)
                content.imageProperties.reservedLayoutSize = CGSize(width: 16, height: 16)
            }
            content.imageToTextPadding = Theme.Spacing.m
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, agent in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: agent)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, SubagentSummary>()
        snapshot.appendSections([.main])
        snapshot.appendItems(agents, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

extension SubagentListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let agent = dataSource.itemIdentifier(for: indexPath) else { return }
        open(agent)
    }
}

extension SubagentListViewController {
    fileprivate func open(_ agent: SubagentSummary) {
        let transcriptBackend = SubagentTranscriptBackend(
            base: backend, parentSessionID: parentSessionID, agentID: agent.id)
        let session = AgentSession(
            id: "subagent:\(parentSessionID):\(agent.id)", agentType: backend.agentType,
            title: agent.title, createdAt: agent.updatedAt, updatedAt: agent.updatedAt)
        let viewModel = ChatViewModel(backend: transcriptBackend, session: session)
        navigationController?.pushViewController(
            ChatViewController(viewModel: viewModel, readOnly: true), animated: true)
    }
}
