import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class SettingsViewController: UIViewController {
    var onConnectionChanged: (() -> Void)?

    private enum Section: Int, CaseIterable {
        case connections, server, about
    }
    private enum Item: Hashable {
        case profile(ConnectionProfile)
        case addConnection
        case health(String)
        case version(String)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var healthText = "Checking…"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done))
        configure()
        applySnapshot()
        Task { await refreshHealth() }
    }

    private func configure() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .profile(let profile) = self.dataSource.itemIdentifier(for: indexPath)
            else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
                self.removeProfile(profile)
                done(true)
            }
            delete.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [delete])
        }
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            guard let self else { return }
            var content = cell.defaultContentConfiguration()
            cell.accessories = []
            switch item {
            case .profile(let profile):
                content.text = profile.name
                content.secondaryText = "\(profile.backend.displayName) · \(profile.baseURL.host ?? "")"
                content.image = UIImage(
                    systemName: profile.backend == .claudeCode
                        ? "sparkles" : "chevron.left.forwardslash.chevron.right")
                content.imageProperties.tintColor = Theme.Color.accent
                if profile.id == ConnectionController.shared.activeProfile?.id {
                    cell.accessories = [.checkmark()]
                }
            case .addConnection:
                content.text = "Add connection"
                content.textProperties.color = Theme.Color.accent
                content.image = UIImage(systemName: "plus.circle")
                content.imageProperties.tintColor = Theme.Color.accent
            case .health(let text):
                content.text = "Active server"
                content.secondaryText = text
            case .version(let text):
                content.text = "Tailscode"
                content.secondaryText = text
            }
            cell.contentConfiguration = content
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = ["Connections", "Status", "About"][indexPath.section]
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(
            ConnectionController.shared.profiles.map { Item.profile($0) } + [.addConnection],
            toSection: .connections)
        snapshot.appendItems([.health(healthText)], toSection: .server)
        snapshot.appendItems([.version("Version 0.1.0")], toSection: .about)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func refreshHealth() async {
        guard let backend = ConnectionController.shared.makeBackend() else {
            healthText = "No active connection"
            applySnapshot()
            return
        }
        do {
            let health = try await backend.health()
            healthText = health.healthy ? "Healthy · \(health.version ?? "connected")" : "Unhealthy"
        } catch {
            healthText = "Unreachable"
        }
        applySnapshot()
    }

    @objc private func done() { dismiss(animated: true) }
}

extension SettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .profile(let profile):
            ConnectionController.shared.setActive(profile.id)
            Theme.Haptics.success()
            onConnectionChanged?()
        case .addConnection:
            let onboarding = OnboardingViewController()
            onboarding.onConnected = { [weak self] in self?.onConnectionChanged?() }
            navigationController?.pushViewController(onboarding, animated: true)
        case .health, .version:
            break
        }
    }

    private func removeProfile(_ profile: ConnectionProfile) {
        let alert = UIAlertController(
            title: "Remove \(profile.name)?",
            message: "This deletes the saved server and its password from the Keychain.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            try? ConnectionController.shared.delete(profile.id)
            Theme.Haptics.warning()
            self?.applySnapshot()
            self?.onConnectionChanged?()
        })
        present(alert, animated: true)
    }
}
