import CodingAgentKit
import CodingAgentKitApple
import SafariServices
import UIKit
import UserNotifications

@MainActor
final class SettingsViewController: UIViewController {
    /// Sections double as deep-link targets, so anything that spots a broken
    /// setting can send the user straight at it: `tailscode://settings/notifications`.
    enum Section: String, CaseIterable {
        case connections, tailnet, notifications, usage, chat, appearance, pro, diagnostics, about

        var title: String {
            switch self {
            case .connections: return "Connections"
            case .tailnet: return "Tailnet"
            case .notifications: return "Notifications"
            case .usage: return "Usage"
            case .chat: return "Chat"
            case .appearance: return "Appearance"
            case .pro: return "Tailscode Pro"
            case .diagnostics: return "Diagnostics"
            case .about: return "About"
            }
        }
    }

    private enum Toggle: Hashable {
        case autoExpandThinking, haptics, sendOnReturn, promptEnhancement
        case notifyTurnComplete, notifyApprovals, notifyUsage, serverPush, liveActivities

        var title: String {
            switch self {
            case .autoExpandThinking: return "Auto-expand thinking"
            case .haptics: return "Haptic feedback"
            case .sendOnReturn: return "Send on return key"
            case .promptEnhancement: return "Enhance prompts"
            case .notifyTurnComplete: return "Turn finished"
            case .notifyApprovals: return "Approvals and questions"
            case .notifyUsage: return "Usage warnings"
            case .serverPush: return "Push from servers"
            case .liveActivities: return "Live Activities"
            }
        }

        var subtitle: String? {
            switch self {
            case .autoExpandThinking:
                return "Show the agent's reasoning without tapping to unfold it"
            case .haptics: return "Taps and thumps as messages send and land"
            case .sendOnReturn: return "Return sends instead of inserting a newline"
            case .promptEnhancement:
                return "Hold Send to refine your draft with the on-device model"
            case .notifyTurnComplete:
                return "When an agent this device is watching goes idle"
            case .notifyApprovals: return "When an agent stops to ask permission or a question"
            case .notifyUsage:
                return "Once per window when a plan limit passes 90%"
            case .serverPush:
                return "Keeps this device registered with claude-bridge, which pushes "
                    + "turn alerts and refreshes the usage widget while the app is closed"
            case .liveActivities: return "Live turn progress on the Lock Screen"
            }
        }

        var icon: String {
            switch self {
            case .autoExpandThinking: return "brain"
            case .haptics: return "hand.tap"
            case .sendOnReturn: return "return"
            case .promptEnhancement: return "sparkles"
            case .notifyTurnComplete: return "checkmark.bubble"
            case .notifyApprovals: return "hand.raised"
            case .notifyUsage: return "gauge.with.needle"
            case .serverPush: return "antenna.radiowaves.left.and.right"
            case .liveActivities: return "rectangle.inset.filled.badge.record"
            }
        }

        var tint: UIColor {
            switch self {
            case .autoExpandThinking: return .systemPurple
            case .haptics: return .systemPink
            case .sendOnReturn: return .systemTeal
            case .promptEnhancement: return Theme.Color.accent
            case .notifyTurnComplete: return Theme.Color.success
            case .notifyApprovals: return Theme.Color.warning
            case .notifyUsage: return .systemIndigo
            case .serverPush: return Theme.Color.accent
            case .liveActivities: return .systemPink
            }
        }

        var isOn: Bool {
            switch self {
            case .autoExpandThinking: return AppPreferences.autoExpandThinking
            case .haptics: return AppPreferences.hapticsEnabled
            case .sendOnReturn: return AppPreferences.sendOnReturn
            case .promptEnhancement: return AppPreferences.promptEnhancement
            case .notifyTurnComplete: return AppPreferences.notifyTurnComplete
            case .notifyApprovals: return AppPreferences.notifyApprovals
            case .notifyUsage: return AppPreferences.notifyUsageWarnings
            case .serverPush: return AppPreferences.pushAlertsEnabled
            case .liveActivities: return AppPreferences.liveActivitiesEnabled
            }
        }

        @MainActor
        func set(_ value: Bool) {
            switch self {
            case .autoExpandThinking: AppPreferences.autoExpandThinking = value
            case .haptics: AppPreferences.hapticsEnabled = value
            case .sendOnReturn: AppPreferences.sendOnReturn = value
            case .promptEnhancement: AppPreferences.promptEnhancement = value
            case .notifyTurnComplete: AppPreferences.notifyTurnComplete = value
            case .notifyApprovals: AppPreferences.notifyApprovals = value
            case .notifyUsage: AppPreferences.notifyUsageWarnings = value
            case .serverPush:
                AppPreferences.pushAlertsEnabled = value
                PushRegistrar.applyPreference()
            case .liveActivities: AppPreferences.liveActivitiesEnabled = value
            }
        }
    }

    private enum Item: Hashable {
        case connectionAlert
        case profile(ConnectionProfile)
        case addConnection
        case discover
        case leaveDemo
        case tailnetStatus
        case tailnetToken
        case tailnetScan
        case notificationPermission
        case toggle(Toggle)
        case pushState(String)
        case testNotification
        case usage
        case goMonthlyCap
        case goBillingDay
        case appearance
        case pro
        case viewLogs
        case testAll
        case copyDiagnostics
        case emailDiagnostics
        case version
        case source
        case privacy
        case support
        case licenses
    }

    private static let privacyURL = "https://midgarcorp.cc/tailscode/privacy"
    private static let supportURL = "https://midgarcorp.cc/tailscode/support"
    private static let sourceURL = "https://github.com/guitaripod/Tailscode"
    private static let supportEmail = "guitaripod@gmail.com"

    /// Called once Settings is off screen. Removing the last server has to change
    /// the app's root, and doing that while this screen is still up would tear it
    /// down mid-interaction.
    var onFinish: (() -> Void)?

    private let initialSection: Section?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var query = ""
    private var notificationStatus: UNAuthorizationStatus?
    private var tailnetAddress: String?
    private var hasScrolledToInitialSection = false

    init(initialSection: Section? = nil) {
        self.initialSection = initialSection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done))
        configureSearch()
        configure()
        applySnapshot()
        observe()
        refreshEnvironment()
        Task { await ServerHealthMonitor.checkAll() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
        refreshEnvironment()
        Task { await ServerHealthMonitor.checkAll() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            if let seeded = ProcessInfo.processInfo.environment["TAILSCODE_SETTINGS_QUERY"],
                query.isEmpty
            {
                navigationItem.searchController?.searchBar.text = seeded
                query = seeded
                applySnapshot()
            }
            pushServerDetailForDebugIfNeeded()
        #endif
        guard !hasScrolledToInitialSection, let initialSection else { return }
        hasScrolledToInitialSection = true
        scroll(to: initialSection)
    }

    #if DEBUG
        /// Opens a server's detail screen on launch so it can be screenshotted
        /// without driving touches. The value is a name prefix; empty takes the
        /// first saved server.
        private func pushServerDetailForDebugIfNeeded() {
            guard navigationController?.viewControllers.count == 1 else { return }
            let environment = ProcessInfo.processInfo.environment
            if let wanted = environment["TAILSCODE_OPEN_SERVER"],
                let profile = ConnectionController.shared.profiles.first(where: {
                    wanted.isEmpty || $0.name.hasPrefix(wanted)
                })
            {
                navigationController?.pushViewController(
                    ServerDetailViewController(profile: profile), animated: false)
                return
            }
            switch environment["TAILSCODE_OPEN_SCREEN"] {
            case "licenses":
                navigationController?.pushViewController(LicensesViewController(), animated: false)
            case "token":
                navigationController?.pushViewController(
                    TailnetTokenViewController(), animated: false)
            case "logs":
                navigationController?.pushViewController(LogViewerViewController(), animated: false)
            default:
                break
            }
        }
    #endif

    private func observe() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(proStateChanged), name: ProStore.didChange, object: nil)
        center.addObserver(
            self, selector: #selector(healthChanged), name: ServerHealthMonitor.didChange, object: nil)
        center.addObserver(
            self, selector: #selector(pushStatesChanged), name: PushRegistrar.didChangeStates,
            object: nil)
        center.addObserver(
            self, selector: #selector(connectionsChanged), name: ConnectionController.didChange,
            object: nil)
        center.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// The two facts that live outside the app — the system notification
    /// permission and whether the tailnet is up — and so can change while
    /// Settings is open.
    private func refreshEnvironment() {
        tailnetAddress = TailnetStatus.localAddress()
        Task { [weak self] in
            let status = await NotificationManager.authorizationStatus()
            guard let self else { return }
            self.notificationStatus = status
            self.reconfigure([.notificationPermission, .tailnetStatus])
        }
    }

    @objc private func appDidBecomeActive() {
        refreshEnvironment()
        Task { await ServerHealthMonitor.checkAll() }
    }

    @objc private func proStateChanged() { reconfigure([.pro]) }

    @objc private func healthChanged() { applySnapshot() }

    @objc private func pushStatesChanged() { applySnapshot() }

    @objc private func connectionsChanged() { applySnapshot() }

    private func configureSearch() {
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search settings"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        definesPresentationContext = true
    }

    private func configure() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .profile(let profile) = self.dataSource.itemIdentifier(for: indexPath)
            else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
                self.removeProfile(profile)
                done(false)
            }
            delete.image = UIImage(systemName: "trash")
            let config = UISwipeActionsConfiguration(actions: [delete])
            config.performsFirstActionWithFullSwipe = false
            return config
        }
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            self?.configure(cell, item)
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
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            let registration =
                kind == UICollectionView.elementKindSectionFooter ? footer : header
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: registration, for: indexPath)
        }
    }

    /// Sections are appended conditionally, so a supplementary view's index is
    /// not its position in `allCases`.
    private func section(at indexPath: IndexPath) -> Section? {
        dataSource.snapshot().sectionIdentifiers[safe: indexPath.section]
    }

    private func footerText(for section: Section) -> String? {
        switch section {
        case .connections:
            guard query.isEmpty, let checked = ServerHealthMonitor.lastCheckedAt else { return nil }
            return "Reachability checked \(Self.relative(checked))."
        case .tailnet:
            return "Every server in Tailscode is reached over your tailnet. The API token is "
                + "only used to list your devices during discovery."
        case .notifications:
            return "Approvals and turn alerts are raised by this device while it is watching a "
                + "session. Push from servers is what reaches you after the app is closed."
        case .usage:
            guard showsGoCaps else { return nil }
            return "Go has no usage API, so the Usage screen estimates spend against these "
                + "caps. The first subscription month runs on a $40 promotional ceiling; the "
                + "published one is $60. Auto reads the renewal day from your oldest Go request."
        case .about:
            return "\(Self.copyright)\nCoding agents over Tailscale."
        case .chat, .appearance, .pro, .diagnostics:
            return nil
        }
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        switch item {
        case .connectionAlert:
            let tailnetDown = ServerHealthMonitor.verdict() == .tailnetDown
            content.text = tailnetDown ? "Tailscale looks disconnected" : "No server is answering"
            content.secondaryText =
                tailnetDown
                ? "This device has no tailnet address, so none of your servers can be reached. "
                    + "Open Tailscale and connect."
                : "Tailscale is up, so the agent processes are the likely problem. Check that "
                    + "opencode or claude-bridge is still running."
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
                ConnectionController.shared.profiles.count > 1
            {
                detail += " · default"
            }
            content.secondaryText = detail
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: profile.backend.symbolName)
            content.imageProperties.tintColor = profile.backend.brandColor
            cell.accessories = [healthDot(for: profile.id), .disclosureIndicator()]
        case .addConnection:
            content.text = "Add connection"
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "plus.circle.fill")
            content.imageProperties.tintColor = Theme.Color.accent
        case .discover:
            content.text = "Discover on tailnet"
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "magnifyingglass")
            content.imageProperties.tintColor = Theme.Color.accent
        case .leaveDemo:
            content.text = "Leave the demo"
            content.secondaryText = "Remove the sample servers and connect your own"
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "play.slash")
            content.imageProperties.tintColor = .systemOrange
        case .tailnetStatus:
            content.text = "Tailscale"
            if let tailnetAddress {
                content.secondaryText = "Connected · \(tailnetAddress)"
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
                content.image = UIImage(systemName: "checkmark.shield.fill")
                content.imageProperties.tintColor = Theme.Color.success
            } else {
                content.secondaryText = "No tailnet address — tap to open Tailscale"
                content.secondaryTextProperties.color = Theme.Color.warning
                content.image = UIImage(systemName: "exclamationmark.shield.fill")
                content.imageProperties.tintColor = Theme.Color.warning
            }
        case .tailnetToken:
            content.text = "API access token"
            content.secondaryText = TailnetCredentials.hasToken ? "Saved in Keychain" : "Not set"
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "key")
            content.imageProperties.tintColor = .systemIndigo
            cell.accessories = [.disclosureIndicator()]
        case .tailnetScan:
            content.text = "Last discovery"
            if let scan = TailnetCredentials.lastScan {
                content.secondaryText =
                    "\(scan.serverCount) of \(scan.deviceCount) devices · \(Self.relative(scan.date))"
            } else {
                content.secondaryText = "Never"
            }
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "dot.radiowaves.left.and.right")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
        case .notificationPermission:
            content.text = "System permission"
            let (detail, color, symbol) = permissionDetail()
            content.secondaryText = detail
            content.secondaryTextProperties.color = color
            content.imageProperties.tintColor = color
            content.image = UIImage(systemName: symbol)
            if notificationStatus != .authorized { cell.accessories = [.disclosureIndicator()] }
        case .toggle(let toggle):
            content.text = toggle.title
            if let subtitle = toggle.subtitle {
                content.secondaryText = subtitle
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            }
            content.image = UIImage(systemName: toggle.icon)
            content.imageProperties.tintColor = toggle.tint
            cell.accessories = [.customView(configuration: switchAccessory(toggle))]
        case .pushState(let profileID):
            let profile = ConnectionController.shared.profiles.first { $0.id == profileID }
            let state = profile.map { PushRegistrar.state(for: $0.baseURL) } ?? .unknown
            content.text = profile?.name ?? "Server"
            content.secondaryText = pushDetail(state)
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color =
                state == .registered ? Theme.Color.secondaryLabel : Theme.Color.warning
            content.image = UIImage(systemName: "app.badge")
            content.imageProperties.tintColor =
                state == .registered ? Theme.Color.success : Theme.Color.warning
        case .testNotification:
            content.text = "Send a test notification"
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "paperplane")
            content.imageProperties.tintColor = Theme.Color.accent
        case .usage:
            content.text = "Usage and limits"
            content.image = UIImage(systemName: "gauge.with.dots.needle.67percent")
            content.imageProperties.tintColor = Theme.Color.opencode
            cell.accessories = [.disclosureIndicator()]
        case .goMonthlyCap:
            content.text = "opencode go monthly cap"
            content.image = UIImage(systemName: "dollarsign.circle")
            content.imageProperties.tintColor = Theme.Color.opencode
            cell.accessories = [.customView(configuration: monthlyCapAccessory())]
        case .goBillingDay:
            content.text = "Billing day"
            content.image = UIImage(systemName: "calendar")
            content.imageProperties.tintColor = Theme.Color.opencode
            cell.accessories = [.customView(configuration: billingDayAccessory())]
        case .appearance:
            content.text = "Theme"
            content.image = UIImage(systemName: "circle.lefthalf.filled")
            content.imageProperties.tintColor = .systemIndigo
            cell.accessories = [.customView(configuration: appearanceAccessory())]
        case .pro:
            content.text = "Tailscode Pro"
            if ProStore.shared.isPro {
                content.secondaryText = "Supporter — thank you ♥"
                content.image = UIImage(systemName: "heart.fill")
                content.imageProperties.tintColor = Theme.Color.danger
            } else {
                content.secondaryText =
                    "Unlimited servers, concurrent Live Activities, support development"
                content.image = UIImage(systemName: "sparkles")
                content.imageProperties.tintColor = .systemPurple
            }
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .viewLogs:
            content.text = "View logs"
            content.image = UIImage(systemName: "doc.text.magnifyingglass")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .testAll:
            content.text = "Test all connections"
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
            content.imageProperties.tintColor = Theme.Color.accent
        case .copyDiagnostics:
            content.text = "Copy diagnostics"
            content.secondaryText = "Build, tailnet, notifications, servers, usage — as text"
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "doc.on.clipboard")
            content.imageProperties.tintColor = Theme.Color.accent
        case .emailDiagnostics:
            content.text = "Email diagnostics"
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "envelope")
            content.imageProperties.tintColor = Theme.Color.accent
        case .version:
            content.text = "Version"
            content.secondaryText = Self.versionString
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
        case .source:
            content.text = "Source code"
            content.image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .privacy:
            content.text = "Privacy policy"
            content.image = UIImage(systemName: "hand.raised.square")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .support:
            content.text = "Support"
            content.image = UIImage(systemName: "lifepreserver")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        case .licenses:
            content.text = "Acknowledgements"
            content.image = UIImage(systemName: "doc.text")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            cell.accessories = [.disclosureIndicator()]
        }
        cell.contentConfiguration = content
    }

    private func permissionDetail() -> (String, UIColor, String) {
        switch notificationStatus {
        case .some(.authorized), .some(.provisional), .some(.ephemeral):
            return ("Allowed", Theme.Color.secondaryLabel, "bell.badge.fill")
        case .some(.denied):
            return ("Turned off — tap to open iOS Settings", Theme.Color.danger, "bell.slash.fill")
        case .some(.notDetermined):
            return ("Not requested — tap to allow", Theme.Color.warning, "bell.badge")
        case .none:
            return ("Checking…", Theme.Color.secondaryLabel, "bell.badge")
        default:
            return ("Unknown", Theme.Color.secondaryLabel, "bell.badge")
        }
    }

    private func pushDetail(_ state: PushRegistrar.State) -> String {
        switch state {
        case .registered: return "Registered"
        case .unsupported: return "Bridge too old"
        case .failed: return "Failed — tap to retry"
        case .unknown:
            if !AppPreferences.pushAlertsEnabled { return "Turned off" }
            return PushRegistrar.hasToken ? "Not registered — tap to retry" : "Waiting for token"
        }
    }

    private func healthDot(for id: String) -> UICellAccessory {
        let symbol: String
        let color: UIColor
        let label: String
        switch ServerHealthMonitor.entry(for: id)?.reachable {
        case .some(true): (symbol, color, label) = ("circle.fill", Theme.Color.success, "Reachable")
        case .some(false):
            (symbol, color, label) = ("exclamationmark.circle.fill", Theme.Color.danger, "Unreachable")
        case .none: (symbol, color, label) = ("circle.dotted", Theme.Color.separator, "Checking")
        }
        let dot = UIImageView(
            image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)))
        dot.tintColor = color
        dot.isAccessibilityElement = true
        dot.accessibilityLabel = label
        return .customView(configuration: .init(customView: dot, placement: .trailing()))
    }

    private func switchAccessory(_ toggle: Toggle) -> UICellAccessory.CustomViewConfiguration {
        let toggleView = UISwitch()
        toggleView.isOn = toggle.isOn
        toggleView.accessibilityLabel = toggle.title
        toggleView.addAction(
            UIAction { [weak self] action in
                guard let sender = action.sender as? UISwitch else { return }
                toggle.set(sender.isOn)
                Theme.Haptics.tap()
                self?.toggleDidChange(toggle)
            }, for: .valueChanged)
        return .init(customView: toggleView, placement: .trailing())
    }

    /// A toggle that changes what other rows mean repaints them: turning server
    /// pushes off makes every per-bridge row read "Turned off" immediately rather
    /// than after the next visit.
    private func toggleDidChange(_ toggle: Toggle) {
        guard toggle == .serverPush else { return }
        applySnapshot()
    }

    private func appearanceAccessory() -> UICellAccessory.CustomViewConfiguration {
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        Self.style(button, title: AppPreferences.appearance.title)
        button.menu = appearanceMenu()
        return .init(customView: button, placement: .trailing())
    }

    /// The inline trailing menu button shared by every value row.
    private static func style(_ button: UIButton, title: String) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(
            systemName: "chevron.up.chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = Theme.Color.secondaryLabel
        button.configuration = config
    }

    private func appearanceMenu() -> UIMenu {
        UIMenu(
            children: AppPreferences.Appearance.allCases.map { option in
                UIAction(
                    title: option.title, state: AppPreferences.appearance == option ? .on : .off
                ) { [weak self] _ in
                    AppPreferences.appearance = option
                    AppPreferences.applyAppearance()
                    self?.reconfigure([.appearance])
                }
            })
    }

    private static let monthlyCapPresets: [Double] = [40, 60]

    private func monthlyCapAccessory() -> UICellAccessory.CustomViewConfiguration {
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        Self.style(button, title: Self.capTitle(AppPreferences.goMonthlyCap))
        button.menu = monthlyCapMenu()
        return .init(customView: button, placement: .trailing())
    }

    private func monthlyCapMenu() -> UIMenu {
        let current = AppPreferences.goMonthlyCap
        var actions = Self.monthlyCapPresets.map { cap in
            UIAction(title: Self.capTitle(cap), state: current == cap ? .on : .off) {
                [weak self] _ in
                self?.setMonthlyCap(cap)
            }
        }
        actions.append(
            UIAction(
                title: "Custom…", state: Self.monthlyCapPresets.contains(current) ? .off : .on
            ) { [weak self] _ in
                self?.promptForMonthlyCap()
            })
        return UIMenu(children: actions)
    }

    private func setMonthlyCap(_ cap: Double) {
        guard cap != AppPreferences.goMonthlyCap else { return }
        AppPreferences.goMonthlyCap = cap
        Theme.Haptics.tap()
        capsChanged()
        reconfigure([.goMonthlyCap])
    }

    /// Every stored opencode percentage was computed against the old ceiling, so
    /// the snapshot the widgets and Home are rendering is now describing a plan
    /// that doesn't exist. Dropping it is honest; the next scan refills it.
    private func capsChanged() {
        UsageWidgetStore.removeProvider(named: UsageWidgetStore.opencodeProviderName)
        AppLogger.session.info("go caps changed to \(GoCaps.signature); dropped stale estimate")
    }

    private func promptForMonthlyCap() {
        let alert = UIAlertController(
            title: "Monthly cap",
            message: "The dollar ceiling the monthly gauge fills against.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .decimalPad
            field.text = Self.amountText(AppPreferences.goMonthlyCap)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
                let typed = alert?.textFields?.first?.text ?? ""
                guard let cap = Double(typed.replacingOccurrences(of: ",", with: ".")), cap > 0
                else { return }
                self?.setMonthlyCap(cap)
            })
        present(alert, animated: true)
    }

    private func billingDayAccessory() -> UICellAccessory.CustomViewConfiguration {
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        Self.style(button, title: Self.billingDayTitle(AppPreferences.goBillingDay))
        button.menu = billingDayMenu()
        return .init(customView: button, placement: .trailing())
    }

    private func billingDayMenu() -> UIMenu {
        let current = AppPreferences.goBillingDay
        return UIMenu(
            children: ([0] + Array(1...31)).map { day in
                UIAction(title: Self.billingDayTitle(day), state: current == day ? .on : .off) {
                    [weak self] _ in
                    guard day != AppPreferences.goBillingDay else { return }
                    AppPreferences.goBillingDay = day
                    Theme.Haptics.tap()
                    self?.capsChanged()
                    self?.reconfigure([.goBillingDay])
                }
            })
    }

    private static func capTitle(_ cap: Double) -> String { "$\(amountText(cap))" }

    private static func amountText(_ value: Double) -> String { String(format: "%g", value) }

    private static func billingDayTitle(_ day: Int) -> String {
        (1...31).contains(day) ? "Day \(day)" : "Auto"
    }

    /// The Go caps only mean anything to someone running opencode, so the
    /// rows stay out of the way until a server is connected.
    private var showsGoCaps: Bool {
        ConnectionController.shared.profiles.contains { $0.backend == .openCode }
    }

    private var pushCapableProfiles: [ConnectionProfile] {
        var seen = Set<URL>()
        return ConnectionController.shared.profiles.filter {
            $0.backend == .claudeCode && !$0.id.hasPrefix(DemoWorld.profilePrefix)
                && seen.insert($0.baseURL).inserted
        }
    }

    private func allItems() -> [(Section, [Item])] {
        var connectionItems: [Item] = []
        if ServerHealthMonitor.verdict() != .fine { connectionItems.append(.connectionAlert) }
        connectionItems += ConnectionController.shared.profiles.map { Item.profile($0) }
        connectionItems += [.addConnection, .discover]
        if ConnectionController.shared.isDemoMode { connectionItems.append(.leaveDemo) }

        var notificationItems: [Item] = [
            .notificationPermission, .toggle(.notifyTurnComplete), .toggle(.notifyApprovals),
            .toggle(.notifyUsage), .toggle(.liveActivities), .toggle(.serverPush),
        ]
        notificationItems += pushCapableProfiles.map { Item.pushState($0.id) }
        notificationItems.append(.testNotification)

        var usageItems: [Item] = [.usage]
        if showsGoCaps { usageItems += [.goMonthlyCap, .goBillingDay] }

        return [
            (.connections, connectionItems),
            (.tailnet, [.tailnetStatus, .tailnetToken, .tailnetScan]),
            (.notifications, notificationItems),
            (.usage, usageItems),
            (
                .chat,
                [
                    .toggle(.promptEnhancement), .toggle(.autoExpandThinking), .toggle(.haptics),
                    .toggle(.sendOnReturn),
                ]
            ),
            (.appearance, [.appearance]),
            (.pro, [.pro]),
            (.diagnostics, [.viewLogs, .testAll, .copyDiagnostics, .emailDiagnostics]),
            (.about, [.version, .source, .privacy, .support, .licenses]),
        ]
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for (section, items) in allItems() {
            let matching = items.filter { matches(query, $0) }
            guard !matching.isEmpty else { continue }
            snapshot.appendSections([section])
            snapshot.appendItems(matching, toSection: section)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter { existing.contains($0) }
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: false)
        updateEmptyState(itemCount: snapshot.numberOfItems)
    }

    private func updateEmptyState(itemCount: Int) {
        guard itemCount == 0 else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.search()
        config.text = "No settings match \"\(query)\""
        contentUnavailableConfiguration = config
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.itemIdentifiers.contains($0) }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Brings a section into view on an already-open Settings, clearing any
    /// active search first — a deep link arriving while the user has the screen
    /// filtered would otherwise appear to do nothing.
    func reveal(section: Section) {
        if !query.isEmpty {
            navigationItem.searchController?.searchBar.text = ""
            query = ""
            applySnapshot()
        }
        scroll(to: section)
    }

    /// Lands on the section's header rather than its first row: scrolling the row
    /// to the top parks the header underneath the pinned search bar, so a deep
    /// link arrives with no visible indication of which section it chose.
    private func scroll(to section: Section) {
        let snapshot = dataSource.snapshot()
        guard let index = snapshot.sectionIdentifiers.firstIndex(of: section),
            snapshot.numberOfItems(inSection: section) > 0
        else { return }
        let path = IndexPath(item: 0, section: index)
        guard
            let header = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: path)
        else {
            collectionView.scrollToItem(at: path, at: .top, animated: true)
            return
        }
        let inset = collectionView.adjustedContentInset.top
        let limit = collectionView.contentSize.height - collectionView.bounds.height + inset
        let target = min(max(header.frame.minY - inset, -inset), max(limit, -inset))
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }

    private func matches(_ query: String, _ item: Item) -> Bool {
        guard !query.isEmpty else { return true }
        return keywords(for: item).localizedCaseInsensitiveContains(query)
    }

    private func keywords(for item: Item) -> String {
        switch item {
        case .connectionAlert: return "unreachable tailscale offline servers"
        case .profile(let profile):
            return "\(profile.name) \(profile.backend.displayName) \(profile.baseURL.host ?? "") server connection"
        case .addConnection: return "add connection server new"
        case .discover: return "discover tailnet scan servers"
        case .leaveDemo: return "leave demo sample"
        case .tailnetStatus: return "tailscale tailnet vpn status connected address"
        case .tailnetToken: return "tailscale api token key keychain discovery"
        case .tailnetScan: return "last discovery scan devices tailnet"
        case .notificationPermission: return "notifications permission authorization alerts allow"
        case .toggle(let toggle): return "\(toggle.title) \(toggle.subtitle ?? "")"
        case .pushState(let id):
            let name = ConnectionController.shared.profiles.first { $0.id == id }?.name ?? ""
            return "push notifications bridge \(name)"
        case .testNotification: return "test notification send check"
        case .usage: return "usage limits quota gauges plan spend"
        case .goMonthlyCap: return "opencode go monthly cap dollars limit spend"
        case .goBillingDay: return "billing day renewal cycle opencode go"
        case .appearance: return "theme appearance dark light mode"
        case .pro: return "pro purchase upgrade supporter restore tip"
        case .viewLogs: return "logs diagnostics view file debug"
        case .testAll: return "test all connections health reachability"
        case .copyDiagnostics: return "copy diagnostics report bug support"
        case .emailDiagnostics: return "email diagnostics support bug report"
        case .version: return "version build number"
        case .source: return "source code github open source gpl"
        case .privacy: return "privacy policy data"
        case .support: return "support help contact"
        case .licenses: return "acknowledgements licenses third party open source"
        }
    }

    private static var versionString: String {
        let info = { (key: String) in Bundle.main.object(forInfoDictionaryKey: key) as? String }
        let version = info("CFBundleShortVersionString") ?? "?"
        let build = info("CFBundleVersion") ?? "?"
        return "\(version) (\(build))"
    }

    private static var copyright: String { "© 2026 Midgar Oy" }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func removeProfile(_ profile: ConnectionProfile) {
        let isDemo = profile.id.hasPrefix(DemoWorld.profilePrefix)
        let alert = UIAlertController(
            title: isDemo ? "Leave the demo?" : "Remove \(profile.name)?",
            message: isDemo
                ? "This removes both sample servers."
                : "This deletes the saved server and its password from the Keychain.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
            try? ConnectionController.shared.delete(profile.id)
            ServerHealthMonitor.forget(profile.id)
            Theme.Haptics.warning()
        })
        present(alert, animated: true)
    }

    /// The first server is free forever; additional saved servers are the
    /// Pro gate. Returns false (and shows the paywall) when gated.
    private func allowAnotherConnection() -> Bool {
        let realProfiles = ConnectionController.shared.profiles.filter {
            !$0.id.hasPrefix(DemoWorld.profilePrefix)
        }
        guard !ProStore.shared.isPro, !realProfiles.isEmpty else {
            return true
        }
        ProUpgradeViewController.present(from: self)
        return false
    }

    private func handlePermissionTap() {
        switch notificationStatus {
        case .notDetermined:
            Task { [weak self] in
                await NotificationManager.requestAuthorization()
                self?.refreshEnvironment()
            }
        case .denied:
            NotificationManager.openSystemSettings()
        default:
            break
        }
    }

    private func copyDiagnostics() {
        Task { [weak self] in
            let report = await DiagnosticsReport.build()
            UIPasteboard.general.string = report
            Theme.Haptics.success()
            guard let self else { return }
            let alert = UIAlertController(
                title: "Copied", message: "Diagnostics are on the clipboard.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
        }
    }

    private func emailDiagnostics() {
        Task { [weak self] in
            let report = await DiagnosticsReport.build()
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = Self.supportEmail
            components.queryItems = [
                URLQueryItem(name: "subject", value: "Tailscode \(Self.versionString)"),
                URLQueryItem(name: "body", value: "\n\n---\n\(report)"),
            ]
            guard let url = components.url else { return }
            UIApplication.shared.open(url, options: [:]) { opened in
                guard !opened else { return }
                UIPasteboard.general.string = report
                Task { @MainActor in self?.presentMailFallback() }
            }
        }
    }

    private func presentMailFallback() {
        let alert = UIAlertController(
            title: "No mail account",
            message:
                "Diagnostics were copied to the clipboard instead. Send them to \(Self.supportEmail).",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        present(SFSafariViewController(url: url), animated: true)
    }

    @objc private func done() {
        dismiss(animated: true) { [onFinish] in onFinish?() }
    }
}

extension SettingsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        applySnapshot()
    }
}

extension SettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .connectionAlert:
            if ServerHealthMonitor.verdict() == .tailnetDown {
                TailnetStatus.openTailscaleApp()
            } else {
                testAllConnections()
            }
        case .profile(let profile):
            let detail = ServerDetailViewController(profile: profile)
            navigationController?.pushViewController(detail, animated: true)
        case .addConnection:
            guard allowAnotherConnection() else { return }
            let onboarding = OnboardingViewController()
            onboarding.onConnected = { [weak self] in
                guard let self else { return }
                self.navigationController?.popToViewController(self, animated: true)
            }
            navigationController?.pushViewController(onboarding, animated: true)
        case .discover:
            guard allowAnotherConnection() else { return }
            let discovery = DiscoveryViewController()
            navigationController?.present(
                UINavigationController(rootViewController: discovery), animated: true)
        case .leaveDemo:
            ConnectionController.shared.leaveDemoMode()
            Theme.Haptics.warning()
        case .tailnetStatus:
            Theme.Haptics.tap()
            TailnetStatus.openTailscaleApp()
        case .tailnetToken:
            let editor = TailnetTokenViewController()
            editor.onChange = { [weak self] in self?.applySnapshot() }
            navigationController?.pushViewController(editor, animated: true)
        case .notificationPermission:
            handlePermissionTap()
        case .pushState:
            Theme.Haptics.tap()
            PushRegistrar.reregisterIfNeeded()
        case .testNotification:
            Theme.Haptics.tap()
            NotificationManager.sendTest()
        case .usage:
            navigationController?.pushViewController(UsageViewController(), animated: true)
        case .pro:
            Theme.Haptics.tap()
            ProUpgradeViewController.present(from: self)
        case .viewLogs:
            navigationController?.pushViewController(LogViewerViewController(), animated: true)
        case .testAll:
            testAllConnections()
        case .copyDiagnostics:
            copyDiagnostics()
        case .emailDiagnostics:
            emailDiagnostics()
        case .source:
            open(Self.sourceURL)
        case .privacy:
            open(Self.privacyURL)
        case .support:
            open(Self.supportURL)
        case .licenses:
            navigationController?.pushViewController(LicensesViewController(), animated: true)
        case .appearance, .toggle, .version, .goMonthlyCap, .goBillingDay, .tailnetScan:
            break
        }
    }

    private func testAllConnections() {
        Theme.Haptics.tap()
        ServerHealthMonitor.clear()
        Task { await ServerHealthMonitor.checkAll(force: true) }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, case .version = dataSource.itemIdentifier(for: indexPaths[0])
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copy = UIAction(title: "Copy version", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = "Tailscode \(Self.versionString)"
                Theme.Haptics.tap()
            }
            return UIMenu(children: [copy])
        }
    }
}
