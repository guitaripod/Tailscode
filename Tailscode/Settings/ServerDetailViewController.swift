import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class ServerDetailViewController: UIViewController {
    private var profile: ConnectionProfile

    private enum Section: Int, CaseIterable { case info, status, software, defaults, actions }
    private enum Item: Hashable {
        case value(label: String, value: String)
        case status(String)
        case pushState
        case account(signedIn: Bool)
        case test
        case updateState
        case updateVersions
        case updateAction
        case autoUpdate
        case updateCenter
        case makeDefault
        case isDefault
        case defaultModel
        case restart
        case edit
        case remove
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var statusText = String(localized: "Checking…")
    private var sessionCount: Int?
    private var serverVersion: String?
    private var modelCount: Int?
    private var backend: (any CodingAgentBackend)?
    private var modelChoice = ModelChoice()
    private var auth: ServerAuth?

    /// The verdict this screen renders, read from the one ledger every surface renders from.
    ///
    /// Never this screen's own words, and never this screen's own asking either: the press routes
    /// to `UpdateMonitor`, which drives the updater that owns this machine. A second updater held
    /// here would watch nothing — the screen would sit on "Update to X" through the whole build
    /// and restart, and keep offering a press that starts the update again.
    private var reading: UpdateReading?

    /// The sentence the Software footer is currently showing, which is the only way to tell that a
    /// supplementary view needs asking again.
    private var softwareFooter: String?

    private var isDemo: Bool { profile.id.hasPrefix(DemoWorld.profilePrefix) }

    private var component: UpdateComponent { .server(profileID: profile.id) }

    init(profile: ConnectionProfile) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        reading = UpdateLedger.remembered(component)
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(ledgerChanged), name: UpdateLedger.didChange, object: nil)
        Task { await refresh() }
    }

    /// An answer landed for some machine — possibly this one, possibly from a sweep started on
    /// another screen, and during an update every few seconds. The row is redrawn either way.
    @objc private func ledgerChanged() {
        reading = UpdateLedger.remembered(component)
        if let running = reading?.installed.text { serverVersion = running }
        applySnapshot()
        reconfigure([.updateState, .updateVersions, .updateAction, .autoUpdate])
        refreshSoftwareFooter()
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
                let section = self.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section]
            else {
                view.contentConfiguration = nil
                return
            }
            let text = self.footerText(section)
            if section == .software { self.softwareFooter = text }
            guard let text else {
                view.contentConfiguration = nil
                return
            }
            var content = UIListContentConfiguration.footer()
            content.text = text
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

    /// What the switch above it means, in the machine's own words rather than this screen's: what
    /// it will and will not do unattended, what it last did, and what it is holding off for now.
    private func footerText(_ section: Section) -> String? {
        switch section {
        case .software:
            return reading?.automation?.sentence()
        case .defaults:
            return String(
                localized:
                    "The default server is where a new chat starts when you haven't aimed the composer somewhere else."
            )
        case .info, .status, .actions:
            return nil
        }
    }

    /// A footer is not an item, so nothing a diff can see changes when the machine changes its mind
    /// about updating itself. The section is asked for its supplementary again, and only when the
    /// sentence it would print is not the one already on screen.
    private func refreshSoftwareFooter() {
        guard footerText(.software) != softwareFooter else { return }
        var snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.software) else { return }
        snapshot.reloadSections([.software])
        dataSource.apply(snapshot, animatingDifferences: false)
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
        case .value(let label, let value):
            content.text = label
            content.secondaryText = value
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
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
        case .restart:
            content.text = ServerRestart.title
            content.secondaryText = ServerRestart.detail
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: ServerRestart.symbol)
            content.imageProperties.tintColor = Theme.Color.accent
        case .test:
            content.text = String(localized: "Test connection")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
            content.imageProperties.tintColor = Theme.Color.accent
        case .updateState:
            guard let reading else {
                content.text = String(localized: "Server software")
                content.secondaryText = String(localized: "Checking…")
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
                cell.accessories = [.working()]
                break
            }
            content.text = reading.headline
            content.secondaryText = reading.detail()
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.font = Theme.Ramp.font(.panelDetail)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(
                systemName: reading.icon.symbol,
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
            content.imageProperties.tintColor = reading.tone.color
            cell.accessibilityLabel = reading.accessibilityLine()
            if reading.verdict.isBusy { cell.accessories = [.working()] }
        case .updateVersions:
            content.text = String(localized: "Running")
            content.secondaryText = reading?.installed.line
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.font = Theme.Ramp.font(.panelLabel)
        case .updateAction:
            guard let invitation = reading?.invitation else { break }
            content.text = invitation.label
            content.textProperties.color = Theme.Color.accent
            if let promise = invitation.promise {
                content.secondaryText = promise
                content.secondaryTextProperties.numberOfLines = 0
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            }
            content.image = UIImage(systemName: Self.symbol(for: invitation))
            content.imageProperties.tintColor = Theme.Color.accent
        case .autoUpdate:
            guard let automation = reading?.automation else { break }
            content.text = String(localized: "Keep this server up to date")
            content.image = UIImage(systemName: "clock.arrow.2.circlepath")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [autoUpdateAccessory(automation)]
        case .updateCenter:
            content.text = String(localized: "Every machine")
            content.secondaryText = String(
                localized: "This app and every server, and what each one is running")
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "arrow.triangle.2.circlepath")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
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

    private static func symbol(for invitation: UpdateInvitation) -> String {
        switch invitation {
        case .installHere: return "arrow.down.circle"
        case .restartHere: return "arrow.clockwise.circle"
        case .openStore: return "arrow.up.forward.app"
        case .copyCommand: return "doc.on.doc"
        case .openPage: return "safari"
        case .recheck: return "arrow.clockwise"
        }
    }

    /// The verdict, the number it rests on, the one press Core says is available, what this machine
    /// does about updates when nobody is asking, and the way to the screen that answers the same
    /// question about every other machine.
    ///
    /// The switch is drawn only for a machine that has a policy to state. A server too old for one
    /// gets no row rather than a row that would move under the finger and change nothing.
    private func softwareItems() -> [Item] {
        guard let reading else { return [.updateState, .updateCenter] }
        var items: [Item] = [.updateState]
        // A machine that only needs starting already says both numbers in one sentence — the row
        // under it would be the same fact a second time.
        if reading.installed.isKnown, !reading.needsOnlyRestart { items.append(.updateVersions) }
        if reading.invitation != nil { items.append(.updateAction) }
        if reading.automation != nil { items.append(.autoUpdate) }
        items.append(.updateCenter)
        return items
    }

    /// The switch renders from what the machine last answered, and only ever from that: a device
    /// that drew it from what it last sent would show a policy on for a request the bridge never
    /// received. A refusal therefore writes nothing down, and the row snaps back to the server's
    /// own account of itself.
    private func autoUpdateAccessory(_ automation: UpdateAutomation) -> UICellAccessory {
        let toggle = UISwitch()
        toggle.isOn = automation.enabled
        toggle.accessibilityLabel = String(localized: "Keep this server up to date")
        toggle.addAction(
            UIAction { [weak self] action in
                guard let sender = action.sender as? UISwitch else { return }
                Theme.Haptics.tap()
                self?.setAutoUpdate(sender.isOn)
            }, for: .valueChanged)
        return .customView(configuration: .init(customView: toggle, placement: .trailing()))
    }

    private func setAutoUpdate(_ enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let failure = await UpdateMonitor.setAutoUpdate(component, enabled)
            guard let failure else { return }
            self.reconfigure([.autoUpdate])
            Theme.Haptics.warning()
            let alert = UIAlertController(
                title: String(localized: "That server did not change its update policy"),
                message: failure, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
            self.present(alert, animated: true)
        }
    }

    private func showUpdateLog(_ reading: UpdateReading) {
        let alert = UIAlertController(
            title: String(localized: "Update failed"),
            message: reading.log ?? reading.detail(), preferredStyle: .alert)
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
                                quotas: QuotaSurface.relevantQuotas(
                                    for: backend.agentType, among: UsageWidgetStore.cachedQuotas()),
                                actions: ModelMenu.Actions(
                                    selectModel: { [weak self] selection in
                                        self?.setDefaultModel(selection)
                                    },
                                    selectEffort: { [weak self] level in
                                        self?.setDefaultEffort(level)
                                    },
                                    browseAll: { [weak self] in
                                        self?.presentModelPicker(backend: backend, models: models)
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

    private func presentModelPicker(backend: any CodingAgentBackend, models: [ModelInfo]) {
        guard !models.isEmpty else { return }
        Theme.Haptics.tap()
        let source = ModelSource(
            profileID: profile.id, name: profile.name, backend: profile.backend, models: models,
            isCurrent: true, allowsServerDefault: true,
            acceptsAnyModelID: profile.backend == .claudeCode)
        let picker = ModelPickerViewController(
            sources: [source], selected: modelChoice.model,
            quotas: QuotaSurface.relevantQuotas(
                for: profile.backend, among: UsageWidgetStore.cachedQuotas())
        ) { [weak self] pick in
            self?.setDefaultModel(pick.selection)
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
        let contextID = profile.id
        let profileSnapshot = profile
        let sources = { (models: [ModelInfo]) in
            [
                ModelSource(
                    profileID: profileSnapshot.id, name: profileSnapshot.name,
                    backend: profileSnapshot.backend, models: models, isCurrent: true,
                    allowsServerDefault: true,
                    acceptsAnyModelID: profileSnapshot.backend == .claudeCode)
            ]
        }
        let watch = PickerCatalogWatch.keep(
            picker: picker, profileID: contextID, backend: backend, sources: sources)
        picker.onClose = { watch.cancel() }
        Task { @MainActor in
            let fresh = await ModelCatalog.fresh(for: contextID, backend: backend)
            picker.update(sources: sources(fresh))
        }
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
        if profile.backend == .claudeCode, !isDemo {
            statusItems.append(.pushState)
            if let auth { statusItems.append(.account(signedIn: auth.loggedIn)) }
        }
        statusItems.append(.test)
        snapshot.appendItems(statusItems, toSection: .status)

        if !isDemo { snapshot.appendItems(softwareItems(), toSection: .software) }

        var defaults: [Item] = [
            ConnectionController.shared.activeProfileID == profile.id ? .isDefault : .makeDefault
        ]
        if supportsModelDefaults { defaults.append(.defaultModel) }
        snapshot.appendItems(defaults, toSection: .defaults)

        var actions: [Item] = isDemo ? [] : [.edit]
        if !isDemo, ServerRestart.isOffered(profile.backend) { actions.insert(.restart, at: 0) }
        actions.append(.remove)
        snapshot.appendItems(actions, toSection: .actions)
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
            checkSoftware()
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
            }
            if profile.backend == .claudeCode, !isDemo {
                auth = try? await (backend as? any AuthenticatingBackend)?.authStatus()
            }
        } catch {
            statusText = String(localized: "Unreachable")
            ServerHealthMonitor.record(false, for: profile.id)
        }
        checkSoftware()
        applySnapshot()
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SIGNIN"] != nil,
                presentedViewController == nil
            {
                presentSignIn()
            }
        #endif
    }

    /// Asks the monitor about this machine, outside whatever the health probe did.
    ///
    /// A server that never answered still has an answer worth writing down — "it did not answer" —
    /// and hanging the question off a successful `health()` is how the Software row keeps a live
    /// spinner over a state nobody is checking.
    private func checkSoftware() {
        guard !isDemo else { return }
        Task {
            await UpdateMonitor.check(component)
            #if DEBUG
                if ProcessInfo.processInfo.environment["TAILSCODE_RUN_UPDATE"] != nil {
                    await UpdateMonitor.update(component)
                }
            #endif
        }
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

    /// The press states its cost first, then hands the ask over and stops. Nothing waits on a
    /// reply: the connection the ask went over dies with the process it restarted, so the ordinary
    /// reconnect — which every screen already watches — is what says the machine is back.
    private func confirmRestart() {
        let alert = UIAlertController(
            title: ServerRestart.confirmTitle(profile.name),
            message: ServerRestart.confirmBody(
                workingTurns: SessionActivity.shared.workingCount(onProfile: profile.id)),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: ServerRestart.action, style: .destructive) { [weak self] _ in
                self?.restartServer()
            })
        present(alert, animated: true)
    }

    private func restartServer() {
        Theme.Haptics.tap()
        Task { [weak self] in
            guard let self else { return }
            guard
                let backend = (self.backend
                    ?? ConnectionController.shared.makeBackend(for: self.profile)),
                let restartable = backend as? any RestartableBackend
            else { return }
            do {
                try await restartable.restart()
                self.statusText = ServerRestart.underway
                self.applySnapshot()
            } catch {
                self.offerSetup(backend: backend)
            }
        }
    }

    /// A machine set up by hand refuses the restart, and the refusal is the offer: the setup that
    /// makes it restartable is one press, not a terminal instruction.
    private func offerSetup(backend: any CodingAgentBackend) {
        guard let settable = backend as? any ServeManagerBackend else {
            statusText = ServerRestart.refused(profile.name)
            applySnapshot()
            return
        }
        let alert = UIAlertController(
            title: ServerRestart.setupTitle,
            message: ServerRestart.setupDetail,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: ServerRestart.setupAction, style: .default) { [weak self] _ in
                self?.installSetup(settable)
            })
        present(alert, animated: true)
    }

    private func installSetup(_ settable: any ServeManagerBackend) {
        statusText = ServerRestart.setupUnderway
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await settable.installServeManager()
                self.statusText = ServerRestart.underway
            } catch {
                self.statusText = ServerRestart.setupFailedDetail
            }
            self.applySnapshot()
        }
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
        case .restart:
            confirmRestart()
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
            guard let reading else { break }
            if case .failed = reading.verdict, reading.log != nil {
                showUpdateLog(reading)
                break
            }
            guard !reading.verdict.isBusy else { break }
            Theme.Haptics.tap()
            Task { await UpdateMonitor.check(component, force: true) }
        case .updateAction:
            guard let reading else { break }
            UpdatePress.perform(reading, from: self)
        case .autoUpdate:
            break
        case .updateCenter:
            Theme.Haptics.tap()
            UpdateCenterViewController.present(from: self)
        case .account(let signedIn):
            guard !signedIn else { break }
            presentSignIn()
        default:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1,
            case .value(_, let value) = dataSource.itemIdentifier(for: indexPaths[0])
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
