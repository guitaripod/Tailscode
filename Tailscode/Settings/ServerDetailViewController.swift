import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class ServerDetailViewController: UIViewController {
    private var profile: ConnectionProfile

    private enum Section: Int, CaseIterable { case info, status, defaults, actions }
    private enum Item: Hashable {
        case value(label: String, value: String, warning: Bool = false)
        case status(String)
        case pushState
        case test
        case makeDefault
        case isDefault
        case defaultModel
        case edit
        case remove
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var statusText = String(localized: "Checking…")
    private var sessionCount: Int?
    private var serverVersion: String?
    private var modelCount: Int?
    private var latestVersion: String?
    private var backend: (any CodingAgentBackend)?
    private var modelChoice = ModelChoice()

    private var isDemo: Bool { profile.id.hasPrefix(DemoWorld.profilePrefix) }

    init(profile: ConnectionProfile) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = profile.name
        view.backgroundColor = Theme.Color.groupedBackground
        configure()
        applySnapshot()
        NotificationCenter.default.addObserver(
            self, selector: #selector(pushStatesChanged), name: PushRegistrar.didChangeStates,
            object: nil)
        Task { await refresh() }
    }

    private func configure() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
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
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.sectionTitle(at: indexPath.section)
            view.contentConfiguration = content
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self,
                let section = self.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section],
                section == .defaults
            else {
                view.contentConfiguration = nil
                return
            }
            var content = UIListContentConfiguration.footer()
            content.text = String(
                localized:
                    "The default server is where a new chat starts when you haven't aimed the composer somewhere else."
            )
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            let registration = kind == UICollectionView.elementKindSectionFooter ? footer : header
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: registration, for: indexPath)
        }
    }

    private func sectionTitle(at index: Int) -> String? {
        switch dataSource.snapshot().sectionIdentifiers[safe: index] {
        case .info: return String(localized: "Server")
        case .status: return String(localized: "Health")
        case .defaults: return String(localized: "Defaults")
        case .actions, .none: return nil
        }
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        switch item {
        case .value(let label, let value, let warning):
            content.text = label
            content.secondaryText = value
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color =
                warning ? Theme.Color.warning : Theme.Color.secondaryLabel
        case .status(let text):
            content.text = String(localized: "Status")
            content.secondaryText = text
            content.prefersSideBySideTextAndSecondaryText = true
        case .pushState:
            let state = PushRegistrar.state(for: profile.baseURL)
            content.text = String(localized: "Push notifications")
            content.secondaryText = Self.pushDetail(state)
            content.secondaryTextProperties.color =
                state == .registered ? Theme.Color.secondaryLabel : Theme.Color.warning
        case .test:
            content.text = String(localized: "Test connection")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
            content.imageProperties.tintColor = Theme.Color.accent
        case .makeDefault:
            content.text = String(localized: "Make default server")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "star")
            content.imageProperties.tintColor = Theme.Color.accent
        case .isDefault:
            content.text = String(localized: "Default server")
            content.image = UIImage(systemName: "star.fill")
            content.imageProperties.tintColor = .systemYellow
            cell.accessories = [.checkmark()]
        case .defaultModel:
            content.text = String(localized: "Default model")
            content.image = UIImage(systemName: "cpu")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.customView(configuration: modelAccessory())]
        case .edit:
            content.text = String(localized: "Edit server")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "pencil")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.disclosureIndicator()]
        case .remove:
            content.text =
                isDemo
                ? String(localized: "Leave the demo") : String(localized: "Remove connection")
            content.textProperties.color = Theme.Color.danger
            content.image = UIImage(systemName: "trash")
            content.imageProperties.tintColor = Theme.Color.danger
        }
        cell.contentConfiguration = content
    }

    private static func pushDetail(_ state: PushRegistrar.State) -> String {
        switch state {
        case .registered: return String(localized: "Registered")
        case .unsupported: return String(localized: "Bridge too old for pushes")
        case .failed(let reason): return String(localized: "Failed — \(reason)")
        case .unknown:
            return AppPreferences.pushAlertsEnabled
                ? String(localized: "Not registered yet") : String(localized: "Turned off")
        }
    }

    private func modelAccessory() -> UICellAccessory.CustomViewConfiguration {
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        var config = UIButton.Configuration.plain()
        config.title = ModelBadge.label(model: modelChoice.model, effort: modelChoice.effort)
        config.image = UIImage(
            systemName: "chevron.up.chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = Theme.Color.secondaryLabel
        button.configuration = config
        button.menu = modelMenu()
        return .init(customView: button, placement: .trailing())
    }

    /// Rebuilt on every present so a catalog that was still loading when the row
    /// was drawn is complete by the time the menu opens.
    private func modelMenu() -> UIMenu {
        UIMenu(
            title: String(localized: "Default model"),
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    Task { @MainActor in
                        guard let self, let backend = self.backend else { return completion([]) }
                        let models =
                            backend.capabilities.supportsModelSelection
                            ? await ModelCatalog.models(for: self.profile.id, backend: backend) : []
                        completion(
                            ModelMenu.elements(
                                models: models,
                                choice: self.modelChoice,
                                efforts: backend.reasoningEffortOptions,
                                allowsServerDefault: ChatModelResolver.honoursServerDefault(backend),
                                actions: ModelMenu.Actions(
                                    selectModel: { [weak self] selection in
                                        self?.setDefaultModel(selection)
                                    },
                                    selectEffort: { [weak self] level in
                                        self?.setDefaultEffort(level)
                                    },
                                    browseAll: { [weak self] in
                                        self?.presentModelPicker(models: models)
                                    })))
                    }
                }
            ])
    }

    private func setDefaultModel(_ selection: ModelSelection?) {
        if let selection { RecentModelsStore.record(selection) }
        ModelPreferenceStore.setGlobalModel(selection, forContextID: profile.id)
        modelChoice.model = selection
        Theme.Haptics.selection()
        reconfigure([.defaultModel])
    }

    private func setDefaultEffort(_ level: String?) {
        EffortPreferenceStore.setGlobalEffort(level, forContextID: profile.id)
        modelChoice.effort = level
        Theme.Haptics.selection()
        reconfigure([.defaultModel])
    }

    private func presentModelPicker(models: [ModelInfo]) {
        guard !models.isEmpty else { return }
        Theme.Haptics.tap()
        let picker = ModelPickerViewController(models: models, selected: modelChoice.model) {
            [weak self] selection in
            self?.setDefaultModel(selection)
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private var supportsModelDefaults: Bool {
        guard let backend else { return false }
        return backend.capabilities.supportsModelSelection
            || backend.capabilities.supportsReasoningEffort
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        var info: [Item] = [
            .value(label: String(localized: "Backend"), value: profile.backend.displayName),
            .value(label: String(localized: "Host"), value: profile.baseURL.host ?? "—"),
            .value(
                label: String(localized: "Port"),
                value: profile.baseURL.port.map(String.init) ?? "—"),
        ]
        if let serverVersion {
            info.append(.value(label: String(localized: "Version"), value: serverVersion))
        }
        if let modelCount {
            info.append(.value(label: String(localized: "Models"), value: String(modelCount)))
        }
        if let sessionCount {
            info.append(.value(label: String(localized: "Sessions"), value: String(sessionCount)))
        }
        snapshot.appendItems(info, toSection: .info)

        var statusItems: [Item] = [.status(statusText)]
        if let latestVersion, let serverVersion, serverVersion != latestVersion {
            statusItems.append(
                .value(
                    label: String(localized: "Update available"), value: latestVersion,
                    warning: true))
        }
        if profile.backend == .claudeCode, !isDemo { statusItems.append(.pushState) }
        statusItems.append(.test)
        snapshot.appendItems(statusItems, toSection: .status)

        var defaults: [Item] = [
            ConnectionController.shared.activeProfileID == profile.id ? .isDefault : .makeDefault
        ]
        if supportsModelDefaults { defaults.append(.defaultModel) }
        snapshot.appendItems(defaults, toSection: .defaults)

        snapshot.appendItems(isDemo ? [.remove] : [.edit, .remove], toSection: .actions)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func pushStatesChanged() { reconfigure([.pushState]) }

    private func refresh() async {
        statusText = String(localized: "Checking…")
        sessionCount = nil
        serverVersion = nil
        modelCount = nil
        applySnapshot()
        let policy = ConnectionPolicy(requestTimeout: .seconds(8), resourceTimeout: .seconds(12))
        guard let backend = ConnectionController.shared.makeBackend(for: profile, policy: policy)
        else {
            statusText = String(localized: "No credentials")
            applySnapshot()
            return
        }
        self.backend = backend
        modelChoice = await ChatModelResolver.choice(profileID: profile.id, backend: backend)
        do {
            let health = try await backend.health()
            statusText =
                health.healthy ? String(localized: "Healthy") : String(localized: "Unhealthy")
            serverVersion = health.version
            ServerHealthMonitor.record(health.healthy, for: profile.id)
            sessionCount = (try? await backend.listSessions())?.count
            if profile.backend == .openCode {
                modelCount = try? await backend.availableModels().count
                latestVersion = await fetchLatestOpencodeRelease()
            }
        } catch {
            statusText = String(localized: "Unreachable")
            ServerHealthMonitor.record(false, for: profile.id)
        }
        applySnapshot()
    }

    /// GitHub's latest opencode release tag, so the user can see at a glance
    /// whether the server process is behind and might be missing new models.
    private func fetchLatestOpencodeRelease() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/anomalyco/opencode/releases/latest")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 6
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String
        else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private func presentEditor() {
        let editor = ServerEditViewController(profile: profile)
        editor.onSaved = { [weak self] updated in
            guard let self else { return }
            self.profile = updated
            self.title = updated.name
            self.applySnapshot()
            Task { await self.refresh() }
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func makeDefault() {
        ConnectionController.shared.setActive(profile.id)
        Theme.Haptics.success()
        applySnapshot()
    }

    private func confirmRemove() {
        let alert = UIAlertController(
            title: isDemo
                ? String(localized: "Leave the demo?")
                : String(localized: "Remove \(profile.name)?"),
            message: isDemo
                ? String(localized: "This removes both sample servers.")
                : String(
                    localized: "This deletes the saved server and its password from the Keychain."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Remove"), style: .destructive) {
                [weak self] _ in
            guard let self else { return }
            try? ConnectionController.shared.delete(profile.id)
            ServerHealthMonitor.forget(profile.id)
            Theme.Haptics.warning()
            navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
}

extension ServerDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .test:
            Theme.Haptics.tap()
            Task { await refresh() }
        case .makeDefault:
            makeDefault()
        case .edit:
            presentEditor()
        case .remove:
            confirmRemove()
        case .pushState:
            PushRegistrar.reregisterIfNeeded()
            Theme.Haptics.tap()
        default:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1,
            case .value(_, let value, _) = dataSource.itemIdentifier(for: indexPaths[0])
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")
                ) {
                    _ in
                    UIPasteboard.general.string = value
                    Theme.Haptics.tap()
                }
            ])
        }
    }
}
