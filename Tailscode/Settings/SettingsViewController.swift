import CodingAgentKitApple
import TailscodeCore
import UIKit

@MainActor
final class SettingsViewController: UIViewController {
    static let privacyURL = "https://midgarcorp.cc/tailscode/privacy"
    static let supportURL = "https://midgarcorp.cc/tailscode/support"
    static let sourceURL = "https://github.com/guitaripod/Tailscode"
    static let supportEmail = "marcus@midgarcorp.cc"

    /// Called once Settings is off screen. Removing the last server has to change
    /// the app's root, and doing that while this screen is still up would tear it
    /// down mid-interaction.
    var onFinish: (() -> Void)?

    let page: Page
    private var highlight: Item?
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    var query = ""
    var notificationStatus: UNAuthorizationStatus?
    var tailnetAddress: String?
    var facts = SettingsFacts.read()
    var hasDeferredSnapshot = false
    var lastScrollAt: CFTimeInterval = 0

    /// A page of Settings, the first one unless told otherwise, optionally pointing at the row a
    /// search led to.
    init(page: Page = .root, highlight: Item? = nil) {
        self.page = page
        self.highlight = highlight
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = page.title
        view.backgroundColor = Theme.Color.groupedBackground
        if page == .root {
            navigationItem.largeTitleDisplayMode = .always
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done, target: self, action: #selector(done))
            configureSearch()
        } else {
            navigationItem.largeTitleDisplayMode = .never
        }
        configure()
        applySnapshot()
        observe()
        repaintTilesOnTraitChange()
        refreshEnvironment()
        Task { await ServerHealthMonitor.checkAll() }
        UpdateMonitor.checkIfDue()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        facts = SettingsFacts.read()
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
        guard let highlight else { return }
        self.highlight = nil
        flash(highlight)
    }

    #if DEBUG
        /// Opens a server's detail screen on launch so it can be screenshotted
        /// without driving touches. The value is a name prefix; empty takes the
        /// first saved server.
        private func pushServerDetailForDebugIfNeeded() {
            guard page == .root, navigationController?.viewControllers.count == 1 else { return }
            let environment = ProcessInfo.processInfo.environment
            if let wanted = environment["TAILSCODE_OPEN_SERVER"],
                wanted.hasPrefix(UpdateFixtures.profilePrefix),
                let url = URL(string: "http://100.64.0.99:4098")
            {
                navigationController?.pushViewController(
                    ServerDetailViewController(
                        profile: ConnectionProfile(
                            id: wanted, name: String(wanted.dropFirst(UpdateFixtures.profilePrefix.count)),
                            backend: .claudeCode, baseURL: url, username: "claude")),
                    animated: false)
                return
            }
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
            case "haptics":
                navigationController?.pushViewController(HapticsViewController(), animated: false)
            case "updates":
                navigationController?.pushViewController(
                    UpdateCenterViewController(), animated: false)
            case let screen?:
                if let page = Page(rawValue: screen) { open(page, animated: false) }
            default:
                break
            }
        }
    #endif

    private func observe() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(proStateChanged), name: ProAccess.didChange, object: nil)
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
        center.addObserver(
            self, selector: #selector(themeChanged), name: ThemeSelection.didChange, object: nil)
        center.addObserver(
            self, selector: #selector(updatesChanged), name: UpdateMonitor.didChange, object: nil)
    }

    /// The software row and the per-server marks are the same fact seen at two widths, so one
    /// answer landing repaints both.
    @objc private func updatesChanged() { scheduleSnapshot() }

    @objc private func themeChanged() {
        reconfigure([.appearance])
    }

    /// The tiles are drawn in the theme's own colours and at the text size, so a window that
    /// changes either repaints every row; light and dark need nothing, each tile carrying both.
    private func repaintTilesOnTraitChange() {
        registerForTraitChanges([ThemeIdentityTrait.self, UITraitPreferredContentSizeCategory.self]) {
            (controller: SettingsViewController, _: UITraitCollection) in
            controller.applySnapshot()
        }
    }

    /// The two facts that live outside the app — the system notification
    /// permission and whether the tailnet is up — and so can change while
    /// Settings is open.
    func refreshEnvironment() {
        tailnetAddress = TailnetStatus.localAddress()
        Task { [weak self] in
            let status = await NotificationManager.authorizationStatus()
            guard let self else { return }
            self.notificationStatus = status
            self.reconfigure([
                .notificationPermission, .backgroundRefresh, .tailnetStatus, .page(.tailnet),
            ])
        }
    }

    @objc private func appDidBecomeActive() {
        refreshEnvironment()
        Task { await ServerHealthMonitor.checkAll() }
    }

    @objc private func proStateChanged() { reconfigure([.pro]) }

    @objc private func healthChanged() { scheduleSnapshot() }

    @objc private func pushStatesChanged() { scheduleSnapshot() }

    @objc private func connectionsChanged() { scheduleSnapshot() }
}
