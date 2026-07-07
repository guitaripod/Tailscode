import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class SettingsViewController: UIViewController {
    var onConnectionChanged: (() -> Void)?

    private enum Section: Int, CaseIterable {
        case connections, appearance, chat, diagnostics, about
    }

    private enum Toggle: Hashable {
        case autoExpandThinking, haptics, sendOnReturn

        var title: String {
            switch self {
            case .autoExpandThinking: return "Auto-expand thinking"
            case .haptics: return "Haptic feedback"
            case .sendOnReturn: return "Send on return key"
            }
        }
        var isOn: Bool {
            switch self {
            case .autoExpandThinking: return AppPreferences.autoExpandThinking
            case .haptics: return AppPreferences.hapticsEnabled
            case .sendOnReturn: return AppPreferences.sendOnReturn
            }
        }
        func set(_ value: Bool) {
            switch self {
            case .autoExpandThinking: AppPreferences.autoExpandThinking = value
            case .haptics: AppPreferences.hapticsEnabled = value
            case .sendOnReturn: AppPreferences.sendOnReturn = value
            }
        }
    }

    private enum Item: Hashable {
        case profile(ConnectionProfile)
        case addConnection
        case appearance
        case toggle(Toggle)
        case viewLogs
        case testAll
        case version
        case source
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var reachable: [String: Bool] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done))
        configure()
        applySnapshot()
        Task { await checkAllHealth() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
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
            self?.configure(cell, item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = ["Connections", "Appearance", "Chat", "Diagnostics", "About"][
                indexPath.section]
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

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        switch item {
        case .profile(let profile):
            content.text = profile.name
            content.secondaryText = "\(profile.backend.displayName) · \(profile.baseURL.host ?? "")"
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(
                systemName: profile.backend == .claudeCode
                    ? "sparkles" : "chevron.left.forwardslash.chevron.right")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [healthDot(for: profile.id), .disclosureIndicator()]
        case .addConnection:
            content.text = "Add connection"
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "plus.circle.fill")
            content.imageProperties.tintColor = Theme.Color.accent
        case .appearance:
            content.text = "Theme"
            content.image = UIImage(systemName: "circle.lefthalf.filled")
            cell.accessories = [.customView(configuration: appearanceAccessory())]
        case .toggle(let toggle):
            content.text = toggle.title
            content.image = UIImage(systemName: icon(for: toggle))
            cell.accessories = [.customView(configuration: switchAccessory(toggle))]
        case .viewLogs:
            content.text = "View logs"
            content.image = UIImage(systemName: "doc.text.magnifyingglass")
            cell.accessories = [.disclosureIndicator()]
        case .testAll:
            content.text = "Test all connections"
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
            content.imageProperties.tintColor = Theme.Color.accent
        case .version:
            content.text = "Version"
            content.secondaryText = Self.versionString
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
        case .source:
            content.text = "Source code"
            content.image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
            cell.accessories = [.disclosureIndicator()]
        }
        cell.contentConfiguration = content
    }

    private func icon(for toggle: Toggle) -> String {
        switch toggle {
        case .autoExpandThinking: return "brain"
        case .haptics: return "hand.tap"
        case .sendOnReturn: return "return"
        }
    }

    private func healthDot(for id: String) -> UICellAccessory {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        dot.layer.cornerRadius = 5
        switch reachable[id] {
        case .some(true): dot.backgroundColor = Theme.Color.success
        case .some(false): dot.backgroundColor = Theme.Color.danger
        case .none: dot.backgroundColor = Theme.Color.separator
        }
        return .customView(configuration: .init(customView: dot, placement: .trailing()))
    }

    private func switchAccessory(_ toggle: Toggle) -> UICellAccessory.CustomViewConfiguration {
        let toggleView = UISwitch()
        toggleView.isOn = toggle.isOn
        toggleView.addAction(
            UIAction { _ in
                toggle.set(toggleView.isOn)
                Theme.Haptics.tap()
            }, for: .valueChanged)
        return .init(customView: toggleView, placement: .trailing())
    }

    private func appearanceAccessory() -> UICellAccessory.CustomViewConfiguration {
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = false
        func rebuild() {
            var config = UIButton.Configuration.plain()
            config.title = AppPreferences.appearance.title
            config.image = UIImage(
                systemName: "chevron.up.chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            config.imagePlacement = .trailing
            config.imagePadding = 4
            config.baseForegroundColor = Theme.Color.secondaryLabel
            button.configuration = config
        }
        button.menu = UIMenu(
            children: AppPreferences.Appearance.allCases.map { option in
                UIAction(
                    title: option.title, state: AppPreferences.appearance == option ? .on : .off
                ) { _ in
                    AppPreferences.appearance = option
                    AppPreferences.applyAppearance()
                    rebuild()
                    button.menu = self.appearanceMenu(button: button, rebuild: rebuild)
                }
            })
        rebuild()
        return .init(customView: button, placement: .trailing())
    }

    private func appearanceMenu(button: UIButton, rebuild: @escaping () -> Void) -> UIMenu {
        UIMenu(
            children: AppPreferences.Appearance.allCases.map { option in
                UIAction(
                    title: option.title, state: AppPreferences.appearance == option ? .on : .off
                ) { _ in
                    AppPreferences.appearance = option
                    AppPreferences.applyAppearance()
                    rebuild()
                    button.menu = self.appearanceMenu(button: button, rebuild: rebuild)
                }
            })
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems(
            ConnectionController.shared.profiles.map { Item.profile($0) } + [.addConnection],
            toSection: .connections)
        snapshot.appendItems([.appearance], toSection: .appearance)
        snapshot.appendItems(
            [.toggle(.autoExpandThinking), .toggle(.haptics), .toggle(.sendOnReturn)],
            toSection: .chat)
        snapshot.appendItems([.viewLogs, .testAll], toSection: .diagnostics)
        snapshot.appendItems([.version, .source], toSection: .about)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func checkAllHealth() async {
        await withTaskGroup(of: (String, Bool).self) { group in
            for profile in ConnectionController.shared.profiles {
                group.addTask {
                    guard let backend = await ConnectionController.shared.makeBackend(for: profile)
                    else { return (profile.id, false) }
                    let ok = (try? await backend.health())?.healthy ?? false
                    return (profile.id, ok)
                }
            }
            for await (id, ok) in group {
                reachable[id] = ok
                reconfigureProfiles()
            }
        }
    }

    private func reconfigureProfiles() {
        var snapshot = dataSource.snapshot()
        let profiles = snapshot.itemIdentifiers.filter {
            if case .profile = $0 { return true }
            return false
        }
        guard !profiles.isEmpty else { return }
        snapshot.reconfigureItems(profiles)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
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

    @objc private func done() { dismiss(animated: true) }
}

extension SettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .profile(let profile):
            let detail = ServerDetailViewController(profile: profile)
            detail.onRemoved = { [weak self] in
                self?.applySnapshot()
                self?.onConnectionChanged?()
            }
            navigationController?.pushViewController(detail, animated: true)
        case .addConnection:
            let onboarding = OnboardingViewController()
            onboarding.onConnected = { [weak self] in self?.onConnectionChanged?() }
            navigationController?.pushViewController(onboarding, animated: true)
        case .viewLogs:
            navigationController?.pushViewController(LogViewerViewController(), animated: true)
        case .testAll:
            Theme.Haptics.tap()
            reachable = [:]
            applySnapshot()
            Task { await checkAllHealth() }
        case .source:
            if let url = URL(string: "https://github.com/guitaripod/CodingAgentKit") {
                UIApplication.shared.open(url)
            }
        case .appearance, .toggle, .version:
            break
        }
    }
}
