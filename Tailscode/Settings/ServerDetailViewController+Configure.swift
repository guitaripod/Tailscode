import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

extension ServerDetailViewController {
    /// An answer landed for some machine — possibly this one, possibly from a sweep started on
    /// another screen, and during an update every two seconds. The card rewrites itself in place.
    @objc func ledgerChanged() {
        reading = UpdateLedger.remembered(component)
        if let running = reading?.installed.text { serverVersion = running }
        applySnapshot()
        reconfigure([.software])
    }

    func configure() {
        var config = UICollectionLayoutListConfiguration.themed(.insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.readableList(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<SurfaceListCell, Item> {
            [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let software = UICollectionView.CellRegistration<UpdateCardCell, Item> {
            [weak self] cell, _, _ in
            self?.configure(cell)
        }
        let permissions = UICollectionView.CellRegistration<MachinePermissionsCardCell, Item> {
            [weak self] cell, _, _ in
            self?.configure(cell)
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
            guard let text = self.footerText(section) else {
                view.contentConfiguration = nil
                return
            }
            var content = UIListContentConfiguration.footer()
            content.text = text
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .software:
                return collectionView.dequeueConfiguredReusableCell(
                    using: software, for: indexPath, item: item)
            case .permissions:
                return collectionView.dequeueConfiguredReusableCell(
                    using: permissions, for: indexPath, item: item)
            default:
                return collectionView.dequeueConfiguredReusableCell(
                    using: cell, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            let registration = kind == UICollectionView.elementKindSectionFooter ? footer : header
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: registration, for: indexPath)
        }
    }

    private func footerText(_ section: Section) -> String? {
        switch section {
        case .software:
            return nil
        case .permissions, .capabilities:
            return nil
        case .defaults:
            return String(
                localized:
                    "The default server is where a new chat starts when you haven't aimed the composer somewhere else."
            )
        case .delegate:
            return DelegateEntryPoint.subtitle
        case .preview:
            return nil
        case .info, .status, .actions:
            return nil
        }
    }

    private func sectionTitle(at index: Int) -> String? {
        switch dataSource.snapshot().sectionIdentifiers[safe: index] {
        case .info: return String(localized: "Server")
        case .status: return String(localized: "Health")
        case .software: return String(localized: "Software")
        case .permissions: return permissions.map(MachinePermissionReading.sectionTitle)
        case .capabilities: return SetupCapabilityRow.sectionTitle
        case .defaults: return String(localized: "Defaults")
        case .delegate: return DelegateEntryPoint.title
        case .preview, .actions, .none: return nil
        }
    }

    func configure(_ cell: UICollectionViewListCell, _ item: Item) {
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
        case .turnWaitAvailability:
            content.text = String(localized: "When closed")
            content.secondaryText = turnWaitAvailability.sentence
            content.secondaryTextProperties.color =
                turnWaitAvailability == .waits ? Theme.Color.secondaryLabel : Theme.Color.warning
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
        case .software, .permissions:
            break
        case .updateCenter:
            content.text = String(localized: "All software updates")
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
        case .delegate:
            content.text = DelegateEntryPoint.serverRowTitle
            content.secondaryText = profile.baseURL.host.map(DelegateGate.rowDetail) ?? ""
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = DelegateGate.isOpen ? Theme.Color.secondaryLabel : Theme.Color.special
            content.image = UIImage(systemName: DelegateEntryPoint.symbol)
            content.imageProperties.tintColor = DelegateGate.isOpen ? Theme.Color.accent : Theme.Color.special
            cell.accessories = [.disclosureIndicator()]
        case .capability(let id):
            guard let row = capabilities.rows.first(where: { $0.capability == id }) else { break }
            content.text = row.title
            content.secondaryText = row.line
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: row.icon.symbol)
            content.imageProperties.tintColor = row.icon.tone.color
            cell.accessibilityLabel = row.spoken
            cell.accessories = [.customView(configuration: capabilityChip(row)), .disclosureIndicator()]
        case .previewHost:
            content.text = Localized.text("Preview host")
            content.secondaryText = previewReach.line
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color =
                previewReach.asksForPassword ? Theme.Color.warning : Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "iphone")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = isPreviewHostChosen ? [.checkmark()] : [.customView(configuration: previewChoice())]
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

    /// The card for this machine, drawn from the ledger — or, before anything has been asked, the
    /// card of a machine being asked.
    func configure(_ cell: UpdateCardCell) {
        let snapshot = UpdateMonitor.snapshot
        let reading =
            self.reading
            ?? UpdateReading(
                component: component, title: profile.name, installed: .unknown,
                verdict: .unverified(.neverChecked),
                product: UpdateProduct.name(for: profile.backend))
        cell.card.apply(
            UpdateCard(
                reading, acknowledged: UpdateLedger.isAcknowledged(reading),
                busy: snapshot.isBusy(component) || self.reading == nil))
        cell.card.onAction = { [weak self] action in
            guard let self, let reading = self.reading else { return }
            UpdatePress.perform(action, for: reading, from: self)
        }
        cell.card.onAutomation = { [weak self, weak cell] enabled in
            guard let self, let cell, let reading = self.reading else { return }
            UpdatePress.setAutomation(enabled, for: reading, card: cell.card, from: self)
        }
    }

    /// The checklist for whatever this Mac's grants are missing, rendered from the one reading
    /// every surface renders from and driven by this screen's own polling task.
    func configure(_ cell: MachinePermissionsCardCell) {
        guard let permissions else { return }
        cell.permissionsView.onRequest = { [weak self] kind in self?.requestPermission(kind) }
        cell.permissionsView.apply(permissions, local: false, requesting: permissionRequesting)
    }

    /// The sign-in is the server's, so it is presented over this screen rather than pushed: it
    /// belongs to the machine, not to the settings hierarchy.
    func presentSignIn() {
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

    private func previewChoice() -> UICellAccessory.CustomViewConfiguration {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Theme.Color.accent
        config.baseForegroundColor = Theme.Color.onAccent
        config.title = Localized.text("Use for previews")
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        let button = UIButton(configuration: config)
        button.addAction(UIAction { [weak self] _ in self?.choosePreviewHost() }, for: .touchUpInside)
        return .init(customView: button, placement: .trailing())
    }

    private func modelAccessory() -> UICellAccessory.CustomViewConfiguration {
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        var config = UIButton.Configuration.plain()
        config.title = ModelBadge.label(
            model: modelChoice.model, effort: modelChoice.effort,
            catalog: ModelCatalog.cached(for: profile.id))
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
}
