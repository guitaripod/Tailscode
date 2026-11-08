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
        let layout = UICollectionViewCompositionalLayout.readableList(configurationForSection: {
            [weak self] index in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: index) else { return config }
            if section == .midgar { return Self.midgarListConfiguration }
            var shaped = config
            shaped.headerMode = section.header == nil ? .none : .supplementary
            shaped.footerMode = self.hasFooter(section) ? .supplementary : .none
            return shaped
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
        let resultCell = UICollectionView.CellRegistration<SurfaceListCell, Item> {
            [weak self] cell, indexPath, item in
            guard let self, case .results(let page)? = self.section(at: indexPath) else { return }
            self.configure(result: cell, item, on: page)
        }
        let midgarCell = UICollectionView.CellRegistration<SurfaceListCell, Item> {
            cell, _, _ in
            Self.embedMidgarEntry(in: cell)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.section(at: indexPath)?.header
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            self?.configureFooter(view, at: indexPath)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, item in
            if case .results(let page)? = self?.section(at: indexPath), page != .root {
                return collectionView.dequeueConfiguredReusableCell(
                    using: resultCell, for: indexPath, item: item)
            }
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

    /// Reconfiguring a cell runs this again, so the card is added only once.
    private static func embedMidgarEntry(in cell: SurfaceListCell) {
        cell.surface = .ground
        guard !cell.contentView.subviews.contains(where: { $0 is MidgarEntryView }) else { return }
        MidgarEntryView(config: TailscodeMidgar.shared.portalConfig).embed(
            in: cell.contentView, verticalInset: 8)
    }

    /// Sections are appended conditionally, so a supplementary view's index is
    /// not its position in a page's list.
    func section(at indexPath: IndexPath) -> Section? {
        dataSource.sectionIdentifier(for: indexPath.section)
    }

    /// Whether a group carries a footer at all, decided by what the group is rather than by what
    /// its footer says right now, so a footer that changes its words never changes the layout.
    private func hasFooter(_ section: Section) -> Bool {
        switch section {
        case .servers, .discovery, .permission, .finished, .needsYou, .muted, .usageAlerts,
            .liveActivities, .push, .testNotice, .composer, .dictation, .agentSteps, .answers, .resume, .density,
            .orb, .keys, .report, .legal:
            return true
        case .midgar, .alerts, .network, .experience, .accounts, .pro, .support, .addServer, .demo,
            .testServers, .tailnetStatus, .theme, .logs, .version, .feedback, .results:
            return false
        }
    }

    private func configureFooter(_ view: UICollectionViewListCell, at indexPath: IndexPath) {
        guard let section = section(at: indexPath), let text = footerText(for: section) else {
            view.contentConfiguration = nil
            return
        }
        var content = UIListContentConfiguration.footer()
        content.text = text
        if section == .legal { content.textProperties.alignment = .center }
        view.contentConfiguration = content
    }

    /// A footer's words can change while the page is open — a reachability check landing, Background
    /// App Refresh turned off — and a snapshot that only reconfigures rows leaves them as they were.
    func refreshFooters() {
        let kind = UICollectionView.elementKindSectionFooter
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: path)
                as? UICollectionViewListCell
            else { continue }
            configureFooter(view, at: path)
        }
    }

    private func footerText(for section: Section) -> String? {
        switch section {
        case .servers:
            guard let checked = ServerHealthMonitor.lastCheckedAt else { return nil }
            return String(localized: "Reachability checked \(Self.relative(checked)).")
        case .discovery:
            return String(
                localized:
                    "Every server in Tailscode is reached over your tailnet. The API token is only used to list your devices during discovery."
            )
        case .permission:
            return backgroundRefreshDetail().actionable ? BackgroundWakeReading.deniedLine : nil
        case .finished:
            return "\(NoticeRulesWords.groupDescription) \(NoticeRulesWords.minimumSubtitle)"
        case .needsYou:
            return String(localized: "Tells you when an agent is waiting on you, even in a muted chat.")
        case .muted:
            return NoticeRulesWords.mutedCount(AppPreferences.noticeRules.muted.count)
        case .usageAlerts:
            return String(
                localized:
                    "Usage warnings come once per window when a plan limit passes 90%. Running low tells you when an account-wide window is on course to run out before it resets."
            )
        case .liveActivities:
            return String(localized: "Shows a turn’s progress on the Lock Screen while it runs.")
        case .push:
            return String(
                localized:
                    "Keeps this device registered with claude-bridge, which pushes turn alerts and refreshes the usage widget while the app is closed."
            )
        case .testNotice:
            let base = String(
                localized:
                    "Approvals and turn alerts come from this device while it watches a session, and, once the app is closed, from a wait each server holds open for it."
            )
            let push = String(
                localized:
                    "A bridge set up with a push key also sends its own alert, which travels through Apple like any push."
            )
            return "\(base) \(TurnWaitFooters.privacy) \(push) \(TurnWaitFooters.forceQuit)"
        case .dictation:
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            let chord = UIDevice.current.userInterfaceIdiom == .pad ? "⌃⇧D" : nil
            return DictationReading.settingsFooter(device: device, chord: chord, surface: .touch)
        case .composer:
            return String(
                localized:
                    "Hold Send to refine a draft with the on-device model. Keyboard shortcuts are for a hardware keyboard and use the same keys and rebinding file as the desktop apps."
            )
        case .agentSteps:
            let switches = String(
                localized:
                    "Compact agent steps fold each step to a slim line you tap to unfold. Auto-expand thinking shows the agent’s reasoning without a tap."
            )
            return "\(ActivityStyleSetting.explanation) \(switches)"
        case .answers:
            return "\(ResponseStatsSetting.explanation) \(LinkEmbedsSetting.explanation)"
        case .resume:
            return AutoResumeSetting.explanation
        case .density:
            return ChatDensitySetting.explanation
        case .orb:
            return String(
                localized:
                    "Alpha. A creature drawn on the GPU over Home that breathes what every conversation is doing. It may cost battery."
            )
        case .keys:
            return String(
                localized:
                    "The DeepSeek API key is optional — set it only if you bill DeepSeek models straight to your own platform account, and its prepaid balance joins the usage meters."
            )
        case .report:
            return String(
                localized:
                    "A plain-text report of this build, the tailnet, notifications, servers and usage, to send with a question to support."
            )
        case .legal:
            return "\(Self.copyright)\n" + String(localized: "Coding agents over Tailscale.")
        case .midgar, .alerts, .network, .experience, .accounts, .pro, .support, .addServer, .demo,
            .testServers, .tailnetStatus, .theme, .logs, .version, .feedback, .results:
            return nil
        }
    }

    /// A search result on another page reads as the iPhone's own do: the name of the setting under
    /// the tile of the page it lives on, opening that page rather than acting from the list.
    private func configure(result cell: SurfaceListCell, _ item: Item, on page: Page) {
        configure(cell, item)
        var content = UIListContentConfiguration.cell()
        content.text = (cell.contentConfiguration as? UIListContentConfiguration)?.text
        content.image = page.tile.image(for: collectionView.traitCollection)
        content.imageProperties.maximumSize = SettingsTile.size(for: collectionView.traitCollection)
        cell.contentConfiguration = content
        cell.accessories = [.disclosureIndicator()]
    }

    private func tile(_ tile: SettingsTile) -> UIImage {
        tile.image(for: collectionView.traitCollection)
    }

    func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = quiet(.cell())
        if !(cell is SettingsSwitchCell) { cell.accessories = [] }
        cell.accessibilityLabel = nil
        let secondary = Theme.Color.secondaryLabel
        switch item {
        case .midgar:
            break
        case .page(let page):
            content = quiet(.valueCell())
            content.text = page.title
            content.image = tile(page.tile)
            switch page {
            case .connections:
                content.secondaryText = defaultServerName
            case .tailnet:
                let connected = tailnetAddress != nil
                content.secondaryText =
                    connected ? String(localized: "Connected") : String(localized: "Not connected")
                if !connected { content.secondaryTextProperties.color = Theme.Color.warning }
            default:
                break
            }
            cell.accessories = [.disclosureIndicator()]
        case .connectionAlert:
            let tailnetDown = ServerHealthMonitor.verdict() == .tailnetDown
            content = quiet(.subtitleCell())
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
            content.image = tile(
                SettingsTile(tailnetDown ? "network.slash" : "exclamationmark.triangle.fill", .orange))
            cell.accessories = [.disclosureIndicator()]
        case .software:
            let rollup = facts.updates
            content = quiet(.subtitleCell())
            content.text = rollup.headline
            content.secondaryText = rollup.detail()
            content.secondaryTextProperties.numberOfLines = 2
            content.image = tile(SettingsTile(rollup.icon.symbol, Self.hue(for: rollup.tone)))
            cell.accessibilityLabel = rollup.accessibilityLine()
            cell.accessories = [.disclosureIndicator()]
        case .softwareUpdate:
            let rollup = facts.updates
            content = quiet(.valueCell())
            content.text = String(localized: "Software Update")
            content.image = tile(SettingsTile("gearshape.fill", .gray))
            if rollup.standing.isEmpty, !rollup.busy.isEmpty {
                content.secondaryText = String(localized: "Updating")
            }
            var accessories: [UICellAccessory] = []
            if !rollup.standing.isEmpty { accessories.append(countBadge(rollup.standing.count)) }
            accessories.append(.disclosureIndicator())
            cell.accessories = accessories
            cell.accessibilityLabel = rollup.accessibilityLine()
        case .profile(let profile) where facts.resting.contains(profile.id):
            content = quiet(.subtitleCell())
            content.text = profile.name
            content.textProperties.color = secondary
            content.secondaryText = ProWeek.restingDetail
            content.image = tile(SettingsTile("moon.zzz.fill", .gray))
            cell.accessories = [.disclosureIndicator()]
        case .profile(let profile):
            content = quiet(.subtitleCell())
            content.text = profile.name
            var detail = "\(profile.backend.displayName) · \(profile.baseURL.host ?? "")"
            if profile.id == ConnectionController.shared.activeProfileID,
                facts.profiles.count > 1
            {
                detail += " · " + String(localized: "default")
            }
            content.secondaryText = detail
            content.image = tile(SettingsTile(profile.backend.symbolName, .brand(profile.backend)))
            var accessories: [UICellAccessory] = []
            if let mark = updateDot(for: profile.id) { accessories.append(mark) }
            accessories.append(healthDot(for: profile.id))
            accessories.append(.disclosureIndicator())
            cell.accessories = accessories
        case .addConnection:
            action(&content, String(localized: "Add connection"))
        case .discover:
            action(&content, String(localized: "Discover on tailnet"))
        case .leaveDemo:
            content = quiet(.subtitleCell())
            action(&content, String(localized: "Leave the demo"))
            content.secondaryText = String(
                localized: "Remove the sample servers and connect your own")
        case .testAll:
            action(&content, String(localized: "Test all connections"))
        case .tailnetStatus:
            content = quiet(.valueCell())
            content.text = String(localized: "Status")
            if let tailnetAddress {
                content.secondaryText = String(localized: "Connected · \(tailnetAddress)")
            } else {
                content.secondaryText = String(localized: "No tailnet address — tap to open Tailscale")
                content.secondaryTextProperties.color = Theme.Color.warning
            }
            cell.accessories = [.disclosureIndicator()]
        case .tailnetToken:
            let key = facts.tailnetKey
            content = quiet(.valueCell())
            content.text = String(localized: "API access token")
            content.secondaryText = key.settingsValue
            if key == .rejected { content.secondaryTextProperties.color = Theme.Color.warning }
            cell.accessories = [.disclosureIndicator()]
        case .tailnetScan:
            content = quiet(.valueCell())
            content.text = String(localized: "Last discovery")
            if let scan = TailnetCredentials.lastScan {
                content.secondaryText =
                    String(localized: "\(scan.serverCount) of \(scan.deviceCount) devices")
                    + " · \(Self.relative(scan.date))"
            } else {
                content.secondaryText = String(localized: "Never")
            }
        case .notificationPermission:
            let (detail, color) = permissionDetail()
            content = quiet(.valueCell())
            content.text = String(localized: "System permission")
            content.secondaryText = detail
            content.secondaryTextProperties.color = color
            if notificationStatus != .authorized { cell.accessories = [.disclosureIndicator()] }
        case .backgroundRefresh:
            let (detail, color, actionable) = backgroundRefreshDetail()
            content = quiet(.valueCell())
            content.text = String(localized: "Background App Refresh")
            content.secondaryText = detail
            content.secondaryTextProperties.color = color
            if actionable { cell.accessories = [.disclosureIndicator()] }
        case .toggle(let toggle):
            content.text = toggle.title
            (cell as? SettingsSwitchCell)?.show(title: toggle.title, isOn: toggle.isOn) {
                [weak self] isOn in
                toggle.set(isOn)
                Theme.Haptics.tap()
                self?.toggleDidChange(toggle)
            }
        case .pushState(let profileID):
            let profile = facts.profiles.first { $0.id == profileID }
            let state = profile.map { PushRegistrar.state(for: $0.baseURL) } ?? .unknown
            content = quiet(.valueCell())
            content.text = profile?.name ?? String(localized: "Server")
            content.secondaryText = pushDetail(state)
            if state != .registered { content.secondaryTextProperties.color = Theme.Color.warning }
        case .testNotification:
            action(&content, String(localized: "Send a test notification"))
        case .usage:
            content.text = String(localized: "Usage")
            content.image = tile(SettingsTile("gauge.with.dots.needle.67percent", .orange))
            cell.accessories = [.disclosureIndicator()]
        case .deepseekKey:
            content = quiet(.valueCell())
            content.text = String(localized: "DeepSeek API key")
            content.secondaryText =
                facts.hasDeepSeekKey
                ? String(localized: "Saved in Keychain") : String(localized: "Not set")
            cell.accessories = [.disclosureIndicator()]
        case .ollamaKey:
            content = quiet(.valueCell())
            content.text = String(localized: "Ollama Cloud API key")
            content.secondaryText =
                facts.hasOllamaKey
                ? String(localized: "Saved in Keychain") : String(localized: "Not set")
            cell.accessories = [.disclosureIndicator()]
        case .keyboardShortcuts:
            content.text = String(localized: "Keyboard shortcuts")
            cell.accessories = [.disclosureIndicator()]
        case .dictationLanguage:
            content = quiet(.valueCell())
            content.text = DictationReading.languageTitle
            content.secondaryText =
                DictationPreferences.language.map(DictationReading.languageName) ?? DictationReading.automatic
            cell.accessories = [.disclosureIndicator()]
        case .streamRenderer:
            content = quiet(.valueCell())
            content.text = String(localized: "Streaming")
            content.secondaryText = StreamRendererSetting.choice.title
            cell.accessories = alphaMark() + [.disclosureIndicator()]
        case .haptics:
            content = quiet(.valueCell())
            content.text = String(localized: "Haptics")
            content.secondaryText =
                AppPreferences.hapticsEnabled
                ? HapticStrength.label(AppPreferences.hapticIntensity) : String(localized: "Off")
            content.image = tile(SettingsTile("hand.tap.fill", .pink))
            cell.accessories = [.disclosureIndicator()]
        case .appearance:
            content = quiet(.valueCell())
            content.text = String(localized: "Theme")
            content.secondaryText = Self.themeSummary
            cell.accessories = [.disclosureIndicator()]
        case .noticeFinish:
            content = quiet(.valueCell())
            content.text = NoticeRulesWords.finishTitle
            content.secondaryText = NoticeRulesWords.title(AppPreferences.noticeRules.finish)
            cell.accessories = [.disclosureIndicator()]
        case .noticeMinimum:
            content = quiet(.valueCell())
            content.text = NoticeRulesWords.minimumTitle
            content.secondaryText = NoticeRulesWords.minimum(AppPreferences.noticeRules.minimumWork)
            cell.accessories = [.disclosureIndicator()]
        case .unmuteAll:
            action(&content, NoticeRulesWords.unmuteAll)
        case .chatDensity:
            content = quiet(.valueCell())
            content.text = ChatDensitySetting.title
            content.secondaryText = ChatDensitySetting.current.title
            cell.accessories = [.disclosureIndicator()]
        case .activityStyle:
            content = quiet(.valueCell())
            content.text = ActivityStyleSetting.title
            content.secondaryText = ActivityStyleSetting.current.title
            cell.accessories = [.disclosureIndicator()]
        case .pro:
            content = quiet(.subtitleCell())
            content.text = "Tailscode Pro"
            if ProAccess.shared.isPro {
                content.secondaryText = String(localized: "Supporter — thank you ♥")
                content.image = tile(SettingsTile("heart.fill", .red))
            } else if let endsAt = ProAccess.shared.proWeekEndsAt {
                content.secondaryText = ProWeek.daysLeftText(until: endsAt)
                content.image = tile(SettingsTile("sparkles", .purple))
            } else {
                content.secondaryText = String(
                    localized: "Unlimited servers, concurrent Live Activities, support development")
                content.image = tile(SettingsTile("sparkles", .purple))
            }
            cell.accessories = [.disclosureIndicator()]
        case .viewLogs:
            content.text = String(localized: "View logs")
            cell.accessories = [.disclosureIndicator()]
        case .copyDiagnostics:
            action(&content, String(localized: "Copy diagnostics"))
        case .emailDiagnostics:
            action(&content, String(localized: "Email diagnostics"))
        case .version:
            let row = Self.versionRow
            content = quiet(.valueCell())
            content.text = row.title
            content.secondaryText = row.detail
        case .source:
            content.text = String(localized: "Source code")
            cell.accessories = [.disclosureIndicator()]
        case .privacy:
            content.text = Self.privacyRow.title
            cell.accessories = [.disclosureIndicator()]
        case .support:
            content.text = Self.supportRow.title
            cell.accessories = [.disclosureIndicator()]
        case .rate:
            content.text = String(localized: "Rate Tailscode")
            cell.accessories = [.disclosureIndicator()]
        case .share:
            content.text = String(localized: "Share Tailscode")
            cell.accessories = [.disclosureIndicator()]
        case .licenses:
            content.text = String(localized: "Acknowledgements")
            cell.accessories = [.disclosureIndicator()]
        }
        if content.image != nil {
            content.imageProperties.maximumSize = SettingsTile.size(for: collectionView.traitCollection)
        }
        cell.contentConfiguration = content
    }

    /// A row style whose second line is set in the theme's quiet register; a row with something to
    /// say in that line colours it itself.
    private func quiet(_ style: UIListContentConfiguration) -> UIListContentConfiguration {
        var style = style
        style.secondaryTextProperties.color = Theme.Color.secondaryLabel
        return style
    }

    /// A row that does something rather than opening something: the accent's words and nothing
    /// else, as the system's own "Add Language…" rows are.
    private func action(_ content: inout UIListContentConfiguration, _ title: String) {
        content.text = title
        content.textProperties.color = Theme.Color.accent
    }

    /// The server a person reaches by default, named on the first page the way the system names
    /// the Wi-Fi network it is on.
    private var defaultServerName: String? {
        let profiles = facts.profiles
        let active = profiles.first { $0.id == ConnectionController.shared.activeProfileID }
        return (active ?? profiles.first)?.name
    }

    /// The tile an update banner wears says how loud the update is, the way its mark does in Home's
    /// chrome: a failure is red, a decision waiting is orange, anything else is the plain blue.
    private static func hue(for tone: ActivityTone) -> SettingsTile.Hue {
        switch tone {
        case .danger: return .red
        case .attention: return .orange
        case .live, .quiet: return .blue
        }
    }

    /// The red count the system puts on a row with something waiting in it.
    private func countBadge(_ count: Int) -> UICellAccessory {
        let badge = SettingsCountBadge()
        badge.text = String(min(count, 99))
        badge.sizeToFit()
        return .customView(configuration: .init(customView: badge, placement: .trailing()))
    }
}

/// A count in a red capsule, as the system draws one on a row that has something waiting: a circle
/// for one digit, a pill for two, growing with the text size.
@MainActor
private final class SettingsCountBadge: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
        textColor = Theme.Color.onAccent
        textAlignment = .center
        backgroundColor = Theme.Color.danger
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { capsule(around: super.intrinsicContentSize) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        capsule(around: super.sizeThatFits(size))
    }

    private func capsule(around text: CGSize) -> CGSize {
        let height = ceil(font.lineHeight + 4)
        return CGSize(width: max(height, ceil(text.width + 12)), height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
