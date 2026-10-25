import MidgarPortal
import MidgarUI
import TailscodeCore
import UIKit

extension SettingsViewController {
    func configureSearch() {
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search settings")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        definesPresentationContext = true
    }

    func configure() {
        var config = UICollectionLayoutListConfiguration.themed(.insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .profile(let profile) = self.dataSource.itemIdentifier(for: indexPath)
            else { return nil }
            let delete = UIContextualAction(
                style: .destructive, title: String(localized: "Remove")
            ) { _, _, done in
                self.removeProfile(profile)
                done(false)
            }
            delete.image = UIImage(systemName: "trash")
            let config = UISwipeActionsConfiguration(actions: [delete])
            config.performsFirstActionWithFullSwipe = false
            return config
        }
        let layout = UICollectionViewCompositionalLayout.readableList(configurationForSection: { [weak self] index in
            self?.isMidgarSection(at: index) == true ? Self.midgarListConfiguration : config
        })
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<SurfaceListCell, Item> {
            [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let switchCell = UICollectionView.CellRegistration<SettingsSwitchCell, Item> {
            [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let midgarCell = UICollectionView.CellRegistration<SurfaceListCell, Item> {
            cell, _, _ in
            Self.embedMidgarEntry(in: cell)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.section(at: indexPath)?.title
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self, let section = self.section(at: indexPath),
                let text = self.footerText(for: section)
            else {
                view.contentConfiguration = nil
                return
            }
            var content = UIListContentConfiguration.footer()
            content.text = text
            if section == .about { content.textProperties.alignment = .center }
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .midgar:
                return collectionView.dequeueConfiguredReusableCell(
                    using: midgarCell, for: indexPath, item: item)
            case .toggle:
                return collectionView.dequeueConfiguredReusableCell(
                    using: switchCell, for: indexPath, item: item)
            default:
                return collectionView.dequeueConfiguredReusableCell(
                    using: cell, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            let registration =
                kind == UICollectionView.elementKindSectionFooter ? footer : header
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: registration, for: indexPath)
        }
    }

    /// The doorway into the Midgar portal is a card, not a settings row: no header, no footer,
    /// no separator, and a background that lets the card be the only thing drawn.
    private static var midgarListConfiguration: UICollectionLayoutListConfiguration {
        var config = UICollectionLayoutListConfiguration.themed(.insetGrouped)
        config.headerMode = .none
        config.footerMode = .none
        config.showsSeparators = false
        return config
    }

    private func isMidgarSection(at index: Int) -> Bool {
        dataSource?.sectionIdentifier(for: index) == .midgar
    }

    /// Reconfiguring a cell runs this again, so the card is added only once.
    private static func embedMidgarEntry(in cell: SurfaceListCell) {
        cell.surface = .ground
        guard !cell.contentView.subviews.contains(where: { $0 is MidgarEntryView }) else { return }
        MidgarEntryView(config: TailscodeMidgar.shared.portalConfig).embed(
            in: cell.contentView, verticalInset: 8)
    }

    /// Sections are appended conditionally, so a supplementary view's index is
    /// not its position in `allCases`.
    func section(at indexPath: IndexPath) -> Section? {
        dataSource.sectionIdentifier(for: indexPath.section)
    }

    private func footerText(for section: Section) -> String? {
        switch section {
        case .connections:
            guard query.isEmpty, let checked = ServerHealthMonitor.lastCheckedAt else { return nil }
            return String(localized: "Reachability checked \(Self.relative(checked)).")
        case .tailnet:
            return String(
                localized:
                    "Every server in Tailscode is reached over your tailnet. The API token is only used to list your devices during discovery."
            )
        case .notifications:
            let base = String(
                localized:
                    "Approvals and turn alerts come from this device while it watches a session, and, once the app is closed, from a wait each server holds open for it."
            )
            let push = String(
                localized:
                    "A bridge set up with a push key also sends its own alert, which travels through Apple like any push."
            )
            return "\(base) \(TurnWaitFooters.privacy) \(push) \(TurnWaitFooters.forceQuit)"
        case .usage:
            return String(
                localized:
                    "The DeepSeek API key is optional — set it only if you bill DeepSeek models straight to your own platform account, and its prepaid balance joins the usage meters."
            )
        case .software:
            return String(
                localized:
                    "Every machine here reports what it runs and what it could run. A server that could not be reached, or is too old to answer, says so rather than reading as up to date."
            )
        case .about:
            return "\(Self.copyright)\n" + String(localized: "Coding agents over Tailscale.")
        case .midgar, .chat, .appearance, .pro, .diagnostics:
            return nil
        }
    }

    func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = cell.defaultContentConfiguration()
        if !(cell is SettingsSwitchCell) { cell.accessories = [] }
        switch item {
        case .midgar:
            break
        case .connectionAlert:
            let tailnetDown = ServerHealthMonitor.verdict() == .tailnetDown
            content.text =
                tailnetDown
                ? String(localized: "Tailscale looks disconnected")
                : String(localized: "No server is answering")
            content.secondaryText =
                tailnetDown
                ? String(
                    localized:
                        "This device has no tailnet address, so none of your servers can be reached. Open Tailscale and connect."
                )
                : String(
                    localized:
                        "Tailscale is up, so the agent processes are the likely problem. Check that opencode, claude-bridge, or omp-bridge is still running."
                )
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.color = Theme.Color.warning
            content.image = UIImage(
                systemName: tailnetDown ? "network.slash" : "exclamationmark.triangle")
            content.imageProperties.tintColor = Theme.Color.warning
            cell.accessories = [.disclosureIndicator()]
        case .profile(let profile):
            content.text = profile.name
            var detail = "\(profile.backend.displayName) · \(profile.baseURL.host ?? "")"
            if profile.id == ConnectionController.shared.activeProfileID,
                facts.profiles.count > 1
            {
                detail += " · " + String(localized: "default")
            }
            content.secondaryText = detail
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: profile.backend.symbolName)
            content.imageProperties.tintColor = profile.backend.brandColor
            var accessories: [UICellAccessory] = []
            if let mark = updateDot(for: profile.id) { accessories.append(mark) }
            accessories.append(healthDot(for: profile.id))
            accessories.append(.disclosureIndicator())
            cell.accessories = accessories
        case .addConnection:
            content.text = String(localized: "Add connection")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "plus.circle.fill")
            content.imageProperties.tintColor = Theme.Color.accent
        case .discover:
            content.text = String(localized: "Discover on tailnet")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "magnifyingglass")
            content.imageProperties.tintColor = Theme.Color.accent
        case .leaveDemo:
            content.text = String(localized: "Leave the demo")
            content.secondaryText = String(
                localized: "Remove the sample servers and connect your own")
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "play.slash")
            content.imageProperties.tintColor = ThemePalette.color(\.info, system: .systemOrange)
        case .software:
            let rollup = facts.updates
            content.text = rollup.headline
            content.secondaryText = rollup.detail()
            content.secondaryTextProperties.numberOfLines = 2
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: rollup.icon.symbol)
            content.imageProperties.tintColor =
                rollup.showsMark ? rollup.tone.color : Theme.Color.secondaryLabel
            cell.accessibilityLabel = rollup.accessibilityLine()
            cell.accessories = [.disclosureIndicator()]
        case .tailnetStatus:
            content.text = "Tailscale"
            if let tailnetAddress {
                content.secondaryText = String(localized: "Connected · \(tailnetAddress)")
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
                content.image = UIImage(systemName: "checkmark.shield.fill")
                content.imageProperties.tintColor = Theme.Color.success
            } else {
                content.secondaryText = String(localized: "No tailnet address — tap to open Tailscale")
                content.secondaryTextProperties.color = Theme.Color.warning
                content.image = UIImage(systemName: "exclamationmark.shield.fill")
                content.imageProperties.tintColor = Theme.Color.warning
            }
        case .tailnetToken:
            content.text = String(localized: "API access token")
            let key = facts.tailnetKey
            content.secondaryText = key.settingsValue
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color =
                key == .rejected ? Theme.Color.warning : Theme.Color.secondaryLabel
            content.image = UIImage(systemName: key == .rejected ? "key.slash" : "key")
            content.imageProperties.tintColor = key == .rejected ? Theme.Color.warning : Theme.Color.info
            cell.accessories = [.disclosureIndicator()]
        case .tailnetScan:
            content.text = String(localized: "Last discovery")
            if let scan = TailnetCredentials.lastScan {
                content.secondaryText =
                    String(localized: "\(scan.serverCount) of \(scan.deviceCount) devices")
                    + " · \(Self.relative(scan.date))"
            } else {
                content.secondaryText = String(localized: "Never")
            }
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "dot.radiowaves.left.and.right")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
        case .notificationPermission:
            content.text = String(localized: "System permission")
            let (detail, color, symbol) = permissionDetail()
            content.secondaryText = detail
            content.secondaryTextProperties.color = color
            content.imageProperties.tintColor = color
            content.image = UIImage(systemName: symbol)
            if notificationStatus != .authorized { cell.accessories = [.disclosureIndicator()] }
        case .backgroundRefresh:
            let (detail, color, symbol, actionable) = backgroundRefreshDetail()
            content.text = String(localized: "Background App Refresh")
            content.secondaryText = detail
            content.secondaryTextProperties.color = color
            content.imageProperties.tintColor = color
            content.image = UIImage(systemName: symbol)
            if actionable { cell.accessories = [.disclosureIndicator()] }
        case .toggle(let toggle):
            content.text = toggle.title
            if let subtitle = toggle.subtitle {
                content.secondaryText = subtitle
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            }
            content.image = UIImage(systemName: toggle.icon)
            content.imageProperties.tintColor = toggle.tint
            (cell as? SettingsSwitchCell)?.show(title: toggle.title, isOn: toggle.isOn) {
                [weak self] isOn in
                toggle.set(isOn)
                Theme.Haptics.tap()
                self?.toggleDidChange(toggle)
            }
        case .pushState(let profileID):
            let profile = facts.profiles.first { $0.id == profileID }
            let state = profile.map { PushRegistrar.state(for: $0.baseURL) } ?? .unknown
            content.text = profile?.name ?? String(localized: "Server")
            content.secondaryText = pushDetail(state)
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color =
                state == .registered ? Theme.Color.secondaryLabel : Theme.Color.warning
            content.image = UIImage(systemName: "app.badge")
            content.imageProperties.tintColor =
                state == .registered ? Theme.Color.success : Theme.Color.warning
        case .testNotification:
            content.text = String(localized: "Send a test notification")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "paperplane")
            content.imageProperties.tintColor = Theme.Color.accent
        case .usage:
            content.text = String(localized: "Usage and limits")
            content.image = UIImage(systemName: "gauge.with.dots.needle.67percent")
            content.imageProperties.tintColor = Theme.Color.opencode
            cell.accessories = [.disclosureIndicator()]
        case .deepseekKey:
            content.text = String(localized: "DeepSeek API key")
            content.secondaryText =
                facts.hasDeepSeekKey
                ? String(localized: "Saved in Keychain") : String(localized: "Not set")
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "key")
            content.imageProperties.tintColor = Theme.Color.info
            cell.accessories = [.disclosureIndicator()]
        case .ollamaKey:
            content.text = String(localized: "Ollama Cloud API key")
            content.secondaryText =
                facts.hasOllamaKey
                ? String(localized: "Saved in Keychain") : String(localized: "Not set")
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "key")
            content.imageProperties.tintColor = Theme.Color.info
            cell.accessories = [.disclosureIndicator()]
        case .keyboardShortcuts:
            content.text = String(localized: "Keyboard shortcuts")
            content.secondaryText = String(
                localized: "For a hardware keyboard — same keys and rebinding file as the desktops")
            content.image = UIImage(systemName: "keyboard")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.disclosureIndicator()]
        case .streamRenderer:
            content.text = String(localized: "Streaming")
            content.secondaryText = StreamRendererSetting.choice.summary
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
            content.imageProperties.tintColor = Theme.Color.special
            cell.accessories = [rendererBadge(), .disclosureIndicator()]
        case .haptics:
            content.text = String(localized: "Haptic feedback")
            content.secondaryText =
                AppPreferences.hapticsEnabled
                ? String(localized: "The wait reported to your hand — sent, progress, done")
                : String(localized: "Off")
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "hand.tap")
            content.imageProperties.tintColor = Theme.Color.special
            cell.accessories = [strengthBadge(), .disclosureIndicator()]
        case .appearance:
            content.text = String(localized: "Theme")
            content.secondaryText = Self.themeSummary
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "paintpalette")
            content.imageProperties.tintColor = Theme.Color.special
            cell.accessories = [.disclosureIndicator()]
        case .chatDensity:
            content.text = ChatDensitySetting.title
            content.secondaryText = ChatDensitySetting.current.explanation
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "rectangle.compress.vertical")
            content.imageProperties.tintColor = Theme.Color.info
            cell.accessories = [
                .label(text: ChatDensitySetting.current.title), .disclosureIndicator(),
            ]
        case .activityStyle:
            content.text = ActivityStyleSetting.title
            content.secondaryText = ActivityStyleSetting.current.explanation
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "brain.head.profile")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [
                .label(text: ActivityStyleSetting.current.title), .disclosureIndicator(),
            ]
        case .pro:
            content.text = "Tailscode Pro"
            if ProAccess.shared.isPro {
                content.secondaryText = String(localized: "Supporter — thank you ♥")
                content.image = UIImage(systemName: "heart.fill")
                content.imageProperties.tintColor = Theme.Color.danger
            } else {
                content.secondaryText = String(
                    localized: "Unlimited servers, concurrent Live Activities, support development")
                content.image = UIImage(systemName: "sparkles")
                content.imageProperties.tintColor = Theme.Color.special
            }
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .viewLogs:
            content.text = String(localized: "View logs")
            content.image = UIImage(systemName: "doc.text.magnifyingglass")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .testAll:
            content.text = String(localized: "Test all connections")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
            content.imageProperties.tintColor = Theme.Color.accent
        case .copyDiagnostics:
            content.text = String(localized: "Copy diagnostics")
            content.secondaryText = String(
                localized: "Build, tailnet, notifications, servers, usage — as text")
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "doc.on.clipboard")
            content.imageProperties.tintColor = Theme.Color.accent
        case .emailDiagnostics:
            content.text = String(localized: "Email diagnostics")
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "envelope")
            content.imageProperties.tintColor = Theme.Color.accent
        case .version:
            let row = Self.versionRow
            content.text = row.title
            content.secondaryText = row.detail
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
        case .source:
            content.text = String(localized: "Source code")
            content.image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .privacy:
            let row = Self.privacyRow
            content.text = row.title
            content.image = row.systemImage.flatMap { UIImage(systemName: $0) }
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .support:
            let row = Self.supportRow
            content.text = row.title
            content.image = row.systemImage.flatMap { UIImage(systemName: $0) }
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .rate:
            content.text = String(localized: "Rate Tailscode")
            content.image = UIImage(systemName: "star")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .share:
            content.text = String(localized: "Share Tailscode")
            content.image = UIImage(systemName: "square.and.arrow.up")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .licenses:
            content.text = String(localized: "Acknowledgements")
            content.image = UIImage(systemName: "doc.text")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        }
        cell.contentConfiguration = content
    }
}
