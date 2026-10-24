import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class ServerDetailViewController: UIViewController {
    var profile: ConnectionProfile

    enum Section: Int, CaseIterable { case info, status, capabilities, software, permissions, defaults, delegate, preview, actions }
    enum Item: Hashable {
        case value(label: String, value: String)
        case status(String)
        case turnWaitAvailability
        case pushState
        case account(signedIn: Bool)
        case test
        case software
        case updateCenter
        case permissions
        case capability(String)
        case makeDefault
        case isDefault
        case defaultModel
        case delegate
        case previewHost
        case restart
        case edit
        case remove
    }

    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    var statusText = String(localized: "Checking…")
    var sessionCount: Int?
    var serverVersion: String?
    var serverAccess: ServerAccess?
    var modelCount: Int?
    var backend: (any CodingAgentBackend)?
    var modelChoice = ModelChoice()
    var auth: ServerAuth?
    var permissions: MachinePermissions?
    var permissionRequesting: MachinePermissions.Grant.Kind?
    var permissionPollTask: Task<Void, Never>?
    var turnWaitAvailability: TurnWaitAvailability = .unknown
    var previewReach: PreviewReach = .unknown
    var previewTask: Task<Void, Never>?
    lazy var capabilities: SetupCapabilitiesSection = {
        let section = SetupCapabilitiesSection(profileURL: profile.baseURL, profileID: profile.id)
        section.onChange = { [weak self] in self?.capabilitiesChanged() }
        return section
    }()
    let previewSecrets: any SecretStore = KeychainSecretStore()

    /// The reading this screen's software card renders, from the one ledger every surface renders
    /// from. Never this screen's own words and never its own asking: a press goes to
    /// `UpdateMonitor`, whose driver follows the job wherever it was started.
    var reading: UpdateReading?

    var isDemo: Bool { profile.id.hasPrefix(DemoWorld.profilePrefix) }

    var component: UpdateComponent { .server(profileID: profile.id) }

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
            self, selector: #selector(ledgerChanged), name: UpdateMonitor.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: DelegateDesk.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: ProAccess.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(previewHostsChanged), name: PreviewAccessStore.didChange, object: nil)
        Task { await refresh() }
        checkPreviewHost()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        capabilities.start()
        startPermissionPollingIfNeeded()
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_SCROLL_PREVIEW"] != nil {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, let indexPath = self.dataSource.indexPath(for: .previewHost)
                    else { return }
                    self.collectionView.scrollToItem(
                        at: indexPath, at: .centeredVertically, animated: false)
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_SCROLL_PERMISSIONS"] != nil {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, let indexPath = self.dataSource.indexPath(for: .permissions)
                    else { return }
                    self.collectionView.scrollToItem(
                        at: indexPath, at: .centeredVertically, animated: false)
                }
            }
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        capabilities.stop()
        stopPermissionPolling()
    }

    @objc private func deskChanged() { reconfigure([.delegate]) }

    private func capabilitiesChanged() {
        applySnapshot()
        reconfigure(capabilities.rows.map { .capability($0.capability) })
    }
}
