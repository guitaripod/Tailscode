import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class ServerDetailViewController: UIViewController {
    private var profile: ConnectionProfile

    private enum Section: Int, CaseIterable { case info, status, software, defaults, actions }
    private enum Item: Hashable {
        case value(label: String, value: String, warning: Bool = false)
        case status(String)
        case pushState
        case account(signedIn: Bool)
        case test
        case updateState
        case runUpdate(String)
        case copyInstallCommand
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
    private var auth: ServerAuth?
    private let updater = BridgeUpdater()

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
        updater.onChange = { [weak self] state in
            guard let self else { return }
            if let version = state.status?.version { self.serverVersion = version }
            self.applySnapshot()
            self.reconfigure([.updateState])
        }
        Task { await refresh() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent { updater.stop() }
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
        case .software: return String(localized: "Software")
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
        case .account(let signedIn):
            content.text = String(localized: "Claude account")
            content.secondaryText =
                signedIn
                ? (auth?.accountLabel ?? String(localized: "Signed in"))
                : String(localized: "Signed out — tap to sign in")
            content.prefersSideBySideTextAndSecondaryText = signedIn
            content.secondaryTextProperties.color =
                signedIn ? Theme.Color.secondaryLabel : Theme.Color.warning
            if !signedIn {
                content.image = UIImage(systemName: "person.badge.key")
                content.imageProperties.tintColor = Theme.Color.warning
                cell.accessories = [.disclosureIndicator()]
            }
        case .test:
            content.text = String(localized: "Test connection")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
            content.imageProperties.tintColor = Theme.Color.accent
        case .updateState:
            content.text = String(localized: "Server software")
            content.secondaryText = updateDetail()
            content.secondaryTextProperties.color =
                updateIsWarning ? Theme.Color.warning : Theme.Color.secondaryLabel
            if case .checking = updater.state { cell.accessories = [spinner()] }
            if case .working = updater.state { cell.accessories = [spinner()] }
        case .runUpdate(let version):
            content.text = String(localized: "Update to \(version)")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "arrow.down.circle")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.disclosureIndicator()]
        case .copyInstallCommand:
            content.text = String(localized: "Copy update command")
            content.secondaryText = String(localized: "Run it on the server over ssh or a terminal")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "doc.on.doc")
            content.imageProperties.tintColor = Theme.Color.accent
        case .makeDefault:
            content.text = String(localized: "Make default server")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "star")
            content.imageProperties.tintColor = Theme.Color.accent
        case .isDefault:
            content.text = String(localized: "Default server")
            content.image = UIImage(systemName: "star.fill")
            content.imageProperties.tintColor = Theme.Color.special
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

    private func spinner() -> UICellAccessory {
        let view = UIActivityIndicatorView(style: .medium)
        view.startAnimating()
        return .customView(configuration: .init(customView: view, placement: .trailing()))
    }

    /// One line that says where this server's software stands, whatever the answer turned out to
    /// be: a version, a job in flight, or the reason the server can't move itself forward.
    private func updateDetail() -> String {
        switch updater.state {
        case .unknown, .checking:
            return String(localized: "Checking…")
        case .current(let status):
            return String(localized: "\(status.version) — up to date")
        case .available(let status):
            let version = status.latestVersion ?? status.latestCommit ?? ""
            guard let behind = status.behind, behind > 0 else {
                return String(localized: "\(version) available")
            }
            guard behind > 1 else { return String(localized: "\(version) available — 1 commit newer") }
            return String(localized: "\(version) available — \(behind) commits newer")
        case .blocked(let status):
            return status.reason ?? String(localized: "This server can't update itself")
        case .unsupported:
            return String(localized: "Too old to update itself")
        case .unreachable:
            return String(localized: "Couldn't check")
        case .working(let status):
            switch status.phase {
            case .building: return String(localized: "Building…")
            case .restarting: return String(localized: "Restarting…")
            default: return String(localized: "Updating…")
            }
        case .failed(let status):
            return status.log?.split(separator: "\n").last.map(String.init)
                ?? String(localized: "The last update failed")
        }
    }

    private var updateIsWarning: Bool {
        switch updater.state {
        case .available, .blocked, .unsupported, .failed: return true
        case .unknown, .checking, .current, .unreachable, .working: return false
        }
    }

    private func softwareItems() -> [Item] {
        var items: [Item] = [.updateState]
        switch updater.state {
        case .available(let status):
            items.append(.runUpdate(status.latestVersion ?? String(localized: "the latest build")))
        case .failed:
            items.append(.runUpdate(String(localized: "try again")))
            items.append(.copyInstallCommand)
        case .blocked, .unsupported:
            items.append(.copyInstallCommand)
        case .unknown, .checking, .current, .unreachable, .working:
            break
        }
        return items
    }

    /// The changes an update would bring, before it is taken: an update restarts the server, and a
    /// person is entitled to know what they are restarting it for.
    private func confirmUpdate(_ status: ServerUpdate) {
        let changes = status.changes.prefix(8).map { "• \($0)" }.joined(separator: "\n")
        let alert = UIAlertController(
            title: String(localized: "Update this server?"),
            message: changes.isEmpty
                ? String(
                    localized:
                        "The server pulls the new code, rebuilds it, and restarts. It stops answering for a moment while it does."
                )
                : String(
                    localized:
                        "\(changes)\n\nThe server rebuilds and restarts, so it stops answering for a moment."
                ),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Update"), style: .default) { [weak self] _ in
                Theme.Haptics.tap()
                Task { await self?.updater.update() }
            })
        present(alert, animated: true)
    }

    private func showUpdateLog(_ status: ServerUpdate) {
        let alert = UIAlertController(
            title: String(localized: "Update failed"),
            message: status.log ?? status.reason
                ?? String(localized: "The server didn't say why."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    /// The sign-in is the server's, so it is presented over this screen rather than pushed: it
    /// belongs to the machine, not to the settings hierarchy.
    private func presentSignIn() {
        guard let backend = backend as? any AuthenticatingBackend else { return }
        Theme.Haptics.tap()
        let signIn = ServerSignInViewController(profile: profile, backend: backend)
        signIn.onSignedIn = { [weak self] status in
            self?.auth = status
            self?.applySnapshot()
        }
        let nav = UINavigationController(rootViewController: signIn)
        present(nav, animated: true)
    }

    private func copyInstallCommand() {
        UIPasteboard.general.string = BridgeUpdater.installCommand
        Theme.Haptics.success()
        let alert = UIAlertController(
            title: String(localized: "Copied"),
            message: String(
                localized:
                    "Run it on the machine the server runs on. It updates in place and keeps your password."
            ),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
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
        ModelPreferenceStore.recordPick(selection, sessionKey: nil, contextID: profile.id)
        modelChoice.model = selection
        Theme.Haptics.selection()
        reconfigure([.defaultModel])
    }

    private func setDefaultEffort(_ level: String?) {
        EffortPreferenceStore.recordPick(level, sessionKey: nil, contextID: profile.id)
        modelChoice.effort = level
        Theme.Haptics.selection()
        reconfigure([.defaultModel])
    }

    private func presentModelPicker(models: [ModelInfo]) {
        guard !models.isEmpty else { return }
        Theme.Haptics.tap()
        let source = ModelSource(
            profileID: profile.id, name: profile.name, backend: profile.backend, models: models,
            isCurrent: true, allowsServerDefault: true,
            acceptsAnyModelID: profile.backend == .claudeCode)
        let picker = ModelPickerViewController(sources: [source], selected: modelChoice.model) {
            [weak self] pick in
            self?.setDefaultModel(pick.selection)
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
        if profile.backend == .claudeCode, !isDemo {
            statusItems.append(.pushState)
            if let auth { statusItems.append(.account(signedIn: auth.loggedIn)) }
        }
        statusItems.append(.test)
        snapshot.appendItems(statusItems, toSection: .status)

        if profile.backend == .claudeCode, !isDemo {
            snapshot.appendItems(softwareItems(), toSection: .software)
        }

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
            sessionCount = (try? await backend.listAllSessions(knownDirectories: []))?.count
            if profile.backend == .openCode {
                modelCount = try? await backend.availableModels().count
                latestVersion = await fetchLatestOpencodeRelease()
            }
            if profile.backend == .claudeCode, !isDemo {
                auth = try? await (backend as? any AuthenticatingBackend)?.authStatus()
                updater.attach(backend)
                Task {
                    await updater.check()
                    #if DEBUG
                        if ProcessInfo.processInfo.environment["TAILSCODE_RUN_UPDATE"] != nil {
                            await updater.update()
                        }
                    #endif
                }
            }
        } catch {
            statusText = String(localized: "Unreachable")
            ServerHealthMonitor.record(false, for: profile.id)
        }
        applySnapshot()
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SIGNIN"] != nil,
                presentedViewController == nil
            {
                presentSignIn()
            }
        #endif
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
        case .updateState:
            if case .failed(let status) = updater.state {
                showUpdateLog(status)
            } else if case .working = updater.state {
                break
            } else {
                Theme.Haptics.tap()
                Task { await updater.check() }
            }
        case .runUpdate:
            guard let status = updater.state.status else { break }
            confirmUpdate(status)
        case .account(let signedIn):
            guard !signedIn else { break }
            presentSignIn()
        case .copyInstallCommand:
            copyInstallCommand()
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
