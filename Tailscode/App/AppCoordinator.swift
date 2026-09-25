import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class AppCoordinator: NSObject {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(connectionsDidChange),
            name: ConnectionController.didChange, object: nil)
    }

    func start() {
        SessionSeenStore.bootstrapIfNeeded()
        DraftStore.warm()
        UpdateMonitor.start()
        AppPreferences.adoptThemeDefaults()
        UsageWidgetStore.dropEstimates()
        #if DEBUG
            if let id = ProcessInfo.processInfo.environment["TAILSCODE_THEME"] {
                ThemeSelection.setThemeID(id)
            }
            if let face = ProcessInfo.processInfo.environment["TAILSCODE_APPEARANCE"],
                let appearance = ThemeAppearance(rawValue: face)
            {
                ThemeSelection.setAppearance(appearance)
            }
        #endif
        Theme.Chrome.adopt(window)
        Theme.Chrome.apply()
        #if DEBUG
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--widget-preview") }) {
                window.rootViewController = UINavigationController(
                    rootViewController: WidgetPreviewViewController(
                        mode: .from(arguments: CommandLine.arguments)))
                window.makeKeyAndVisible()
                return
            }
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--enhance-preview") }) {
                window.rootViewController = EnhancePreviewViewController()
                window.makeKeyAndVisible()
                return
            }
            if CommandLine.arguments.contains("--interrupted-preview") {
                window.rootViewController = InterruptedTurnPreviewViewController()
                window.makeKeyAndVisible()
                return
            }
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--turn-cards-preview") }) {
                window.rootViewController = TurnCardsPreviewViewController()
                window.makeKeyAndVisible()
                return
            }
        #endif
        if CommandLine.arguments.contains("--demo"), !ConnectionController.shared.isDemoMode {
            ConnectionController.shared.enterDemoMode()
        }
        #if DEBUG
            seedDebugConnectionIfNeeded()
        #endif
        route(animated: false)
        window.makeKeyAndVisible()
        #if DEBUG
            sizeWindowForVerificationIfAsked()
        #endif
        UpdateMonitor.checkIfDue()
        if let parked = PendingRoute.take() { deliver(parked) }
        #if DEBUG
            if let sessionID = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SESSION"] {
                deliver(URL(string: "tailscode://session/\(sessionID)")!)
            }
            if CommandLine.arguments.contains("--usage") {
                openUsageForDebug()
            }
            if CommandLine.arguments.contains("--analytics") {
                openAnalyticsForDebug()
            }
            if CommandLine.arguments.contains("--video") {
                openVideoForDebug(staging: nil)
            }
            if let state = ProcessInfo.processInfo.environment["TAILSCODE_VIDEO_STATE"] {
                openVideoForDebug(staging: state)
            }
            if let slug = ProcessInfo.processInfo.environment["TAILSCODE_SETTINGS_SECTION"] {
                openSettingsForDebug(slug: slug)
            }
            if CommandLine.arguments.contains("--tour") { TourDriver.start(in: window) }
            if CommandLine.arguments.contains("--slashwalk") {
                TourDriver.startSlashWalk(in: window)
            }
            if CommandLine.arguments.contains("--modelwalk") {
                TourDriver.startModelWalk(in: window)
            }
            if CommandLine.arguments.contains("--chatswalk") {
                TourDriver.startChatsWalk(in: window)
            }
            if CommandLine.arguments.contains("--designwalk") {
                TourDriver.startDesignWalk(in: window)
            }
            if CommandLine.arguments.contains("--cardwalk") {
                TourDriver.startCardWalk(in: window)
            }
            if CommandLine.arguments.contains("--revertwalk") {
                TourDriver.startRevertWalk(in: window)
            }
        #endif
    }

    #if DEBUG
        /// Opens Settings scrolled to a section on launch, so each part of the
        /// screen can be screenshotted without driving touches.
        private func openSettingsForDebug(slug: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.openSettings(section: SettingsViewController.Section(rawValue: slug))
            }
        }

        private func openUsageForDebug() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.home?.navigationController?.pushViewController(
                    UsageViewController(), animated: false)
            }
        }

        /// `TAILSCODE_WINDOW=1376x1032` lays the window out at that size, turned a quarter when it
        /// is wider than the screen, because a simulator in windowed mode refuses a programmatic
        /// rotation and no simctl command resizes a window — this is how the wide arrangements are
        /// photographed on a device that boots upright.
        private func sizeWindowForVerificationIfAsked() {
            guard let spec = ProcessInfo.processInfo.environment["TAILSCODE_WINDOW"] else { return }
            let sides = spec.split(separator: "x").compactMap { Double($0) }
            guard sides.count == 2 else { return }
            let screen = window.windowScene?.screen.bounds ?? window.bounds
            window.bounds = CGRect(x: 0, y: 0, width: sides[0], height: sides[1])
            window.center = CGPoint(x: screen.midX, y: screen.midY)
            if sides[0] > screen.width { window.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        }

        /// Opens the video surface with the board put into one named state, so every face it has
        /// — no renderer, a machine that did not answer, a render queued, running, saved, failed —
        /// can be photographed on a simulator with nothing on the other end. Naming `home` as the
        /// landing stages the render and stays put, which is how the mark Home wears while a
        /// render is out gets photographed.
        private func openVideoForDebug(staging state: String?) {
            if let seed = ProcessInfo.processInfo.environment["TAILSCODE_FORGE_SEED"] {
                ForgeRunner.shared.seedRenderers(seed)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if let state { ForgeRunner.shared.stage(state) }
                guard ProcessInfo.processInfo.environment["TAILSCODE_VIDEO_SCROLL"] != "home"
                else { return }
                self?.home?.presentVideo()
            }
        }

        private func openAnalyticsForDebug() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.home?.navigationController?.pushViewController(
                    AnalyticsViewController(analytics: nil), animated: false)
            }
        }

        private func seedDebugConnectionIfNeeded() {
            let env = ProcessInfo.processInfo.environment
            guard let host = env["TAILSCODE_HOST"], let url = URL(string: host) else { return }
            guard !ConnectionController.shared.hasConnection else {
                AppLogger.connection.info("seed skipped — already connected")
                return
            }
            seed(
                id: "debug", url: url, backend: Self.debugBackend(env["TAILSCODE_BACKEND"]),
                password: env["TAILSCODE_PASSWORD"])

            if let extra = env["TAILSCODE_HOST2"], let url2 = URL(string: extra) {
                seed(
                    id: "debug2", url: url2, backend: Self.debugBackend(env["TAILSCODE_BACKEND2"]),
                    password: env["TAILSCODE_PASSWORD2"])
            }
        }

        private static func debugBackend(_ value: String?) -> AgentType {
            switch value {
            case "claude": return .claudeCode
            case "omp": return .omp
            default: return .openCode
            }
        }

        private func seed(id: String, url: URL, backend: AgentType, password: String?) {
            let name = url.host ?? id
            let profile = ConnectionProfile(id: id, name: name, backend: backend, baseURL: url)
            ConnectionController.shared.setOverridePassword(password, for: id)
            do {
                try ConnectionController.shared.save(profile, password: password, makeActive: id == "debug")
                AppLogger.connection.info("seed saved profile for \(name)")
            } catch {
                ConnectionController.shared.addDebugProfile(profile)
                if id == "debug" { ConnectionController.shared.setActive(id) }
                AppLogger.connection.error("seed keychain failed (\(error)); using in-memory profile")
            }
        }

    #endif

    private var pendingSessionLink: (url: URL, parkedAt: Date)?
    private var pendingComposeFocus = false
    private var pendingShortcut: ShortcutTarget?

    /// The quick actions the Home screen offers on a long press. Every target
    /// lands on the same destination as its in-app tap; one that arrives before
    /// the main UI exists (a cold launch, or before any server is set up) is
    /// parked and delivered on the next route to Home, so a press is never
    /// dropped while the app is still standing up.
    @discardableResult
    func handleShortcut(_ item: UIApplicationShortcutItem) -> Bool {
        let target: ShortcutTarget
        switch item.type {
        case HomeQuickActions.newChat: target = .compose
        case HomeQuickActions.saved: target = .saved
        case HomeQuickActions.usage: target = .usage
        case HomeQuickActions.quickAsk: target = .quickAsk
        case HomeQuickActions.resume:
            guard let sessionID = item.userInfo?["sessionID"] as? String else { return false }
            target = .resume(sessionID: sessionID)
        default: return false
        }
        perform(target)
        return true
    }

    private enum ShortcutTarget {
        case compose
        case saved
        case usage
        case quickAsk
        case resume(sessionID: String)
    }

    private func perform(_ target: ShortcutTarget) {
        switch target {
        case .compose:
            if let home { home.focusComposer() } else { pendingComposeFocus = true }
        case .saved:
            if let home { home.pushSaved() } else { pendingShortcut = .saved }
        case .usage:
            if let home { home.pushUsage() } else { pendingShortcut = .usage }
        case .quickAsk:
            if let home { home.presentQuickAsk() } else { pendingShortcut = .quickAsk }
        case .resume(let sessionID):
            if let home { home.openSession(withID: sessionID) } else {
                pendingShortcut = .resume(sessionID: sessionID)
            }
        }
    }

    /// The root only ever changes across one boundary: having a server or not.
    /// Editing, renaming, or adding a second connection used to cross-dissolve a
    /// brand-new root and eject the user from Settings; now the screens listen
    /// for the change themselves and this only steps in when onboarding has to
    /// appear or disappear.
    @objc private func connectionsDidChange() {
        guard ConnectionController.shared.hasConnection != showingMain else { return }
        guard window.rootViewController?.presentedViewController == nil else {
            needsRootSync = true
            return
        }
        route(animated: true)
    }

    private var showingMain = false
    private var needsRootSync = false

    /// Deferred until Settings closes: swapping the root out from under a modal
    /// tears the modal down mid-interaction, and removing your last server is
    /// usually followed by adding another one.
    private func syncRootIfNeeded() {
        guard needsRootSync else { return }
        needsRootSync = false
        guard ConnectionController.shared.hasConnection != showingMain else { return }
        route(animated: true)
    }

    /// Routes `tailscode://session/<id>` (Live Activity tap) to that chat.
    /// Links that arrive before the session list exists are parked and
    /// delivered on the next route to the main UI; a link older than 30s is
    /// dropped rather than hijacking navigation long after the tap.
    func handle(_ url: URL) {
        guard url.scheme == "tailscode" else { return }
        if url.host() == "settings" {
            openSettings(section: SettingsViewController.Section(rawValue: url.lastPathComponent))
            return
        }
        if url.host() == "connect" {
            handleConnectLink(url)
            return
        }
        if url.host() == "compose" {
            perform(.compose)
            return
        }
        if url.host() == "saved" {
            perform(.saved)
            return
        }
        if url.host() == "ask" {
            perform(.quickAsk)
            return
        }
        if url.host() == "video" {
            guard let home else {
                pendingSessionLink = (url, Date())
                return
            }
            pendingSessionLink = nil
            home.presentVideo()
            return
        }
        if url.host() == "usage" {
            guard let home else {
                pendingSessionLink = (url, Date())
                return
            }
            pendingSessionLink = nil
            home.pushUsage()
            return
        }
        guard url.host() == "session" else { return }
        let sessionID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decoded = sessionID.removingPercentEncoding ?? sessionID
        guard !decoded.isEmpty else { return }
        guard let home else {
            pendingSessionLink = (url, Date())
            return
        }
        pendingSessionLink = nil
        home.openSession(withID: decoded)
    }

    /// Fills the setup screen in from a link the server itself can print, so the
    /// address makes the trip from computer to phone without being typed twice.
    private func handleConnectLink(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty else { return }
        let port = items.first { $0.name == "port" }?.value
        let address = port.map { "\(host):\($0)" } ?? host
        guard
            let nav = window.rootViewController as? UINavigationController,
            let welcome = nav.viewControllers.first as? WelcomeViewController
        else {
            AppLogger.lifecycle.info("connect link ignored — a server is already set up")
            return
        }
        nav.dismiss(animated: true)
        welcome.openSetup(prefilling: address)
    }

    /// A Control opens the app and leaves a route flag in the shared App Group
    /// (a custom URL scheme is unreliable from a Control). Consume it on foreground.
    /// The quick ask route goes through the same parking as a long-press, so a cold
    /// launch from Control Center still lands on the composer once Home exists.
    func handleControlRouteIfNeeded() {
        switch UsageWidgetStore.takePendingControlRoute() {
        case "usage": handle(URL(string: "tailscode://usage")!)
        case "ask": perform(.quickAsk)
        default: return
        }
    }

    /// The one Home this window has, held rather than found: on an iPad it moves between the
    /// conversation column and the one-stack arrangement as the window changes width, so no path
    /// through the view hierarchy reaches it every time.
    private var home: HomeViewController? { showingMain ? mainHome : nil }
    private weak var mainHome: HomeViewController?

    /// What iPadOS keeps for this window when it puts it away: the conversation it was showing,
    /// so a window the system brings back opens on that chat rather than on Home. Each window of
    /// an iPad is its own place, and one showing a conversation is expected to be found showing it
    /// again; the phone launches to Home by design and keeps nothing.
    func restorationActivity() -> NSUserActivity? {
        guard showingMain,
            let workspace = window.rootViewController as? WorkspaceSplitViewController,
            let id = workspace.openConversationID,
            let url = SceneRouting.sessionURL(id)
        else { return nil }
        return SceneRouting.activity(for: url)
    }

    /// Opens Settings at a given section, so anything that finds a broken setting
    /// can point at the row that fixes it rather than describing where it lives.
    func openSettings(section: SettingsViewController.Section?) {
        guard let home else { return }
        let presenter = home.navigationController ?? home
        if let nav = presenter.presentedViewController as? UINavigationController,
            let settings = nav.viewControllers.first as? SettingsViewController
        {
            nav.popToRootViewController(animated: true)
            if let section { settings.reveal(section: section) }
            return
        }
        guard presenter.presentedViewController == nil else { return }
        presentSettings(from: presenter, section: section)
    }

    private func route(animated: Bool) {
        showingMain = ConnectionController.shared.hasConnection
        let root = showingMain ? makeMain() : makeOnboarding()
        if animated {
            UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
                self.window.rootViewController = root
            }
        } else {
            window.rootViewController = root
        }
        if let pending = pendingSessionLink {
            pendingSessionLink = nil
            if Date().timeIntervalSince(pending.parkedAt) < 30 {
                deliver(pending.url)
            }
        }
        if pendingComposeFocus {
            pendingComposeFocus = false
            home?.focusComposer()
        }
        if let pendingShortcut {
            self.pendingShortcut = nil
            perform(pendingShortcut)
        }
    }

    /// A link released by a root swap waits for the swap to finish. `route` is the one moment the
    /// window's root is being replaced — on a cold launch it has not even been made key yet — and
    /// navigating from inside it pushes onto a navigation controller whose view is not on screen,
    /// which is how a notification tap ends in an inconsistent stack rather than a chat.
    private func deliver(_ url: URL) {
        DispatchQueue.main.async { [weak self] in self?.handle(url) }
    }

    private func makeOnboarding() -> UIViewController {
        let welcome = WelcomeViewController()
        welcome.onConnected = { [weak self] in self?.route(animated: true) }
        let nav = UINavigationController(rootViewController: welcome)
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }

    /// The phone's app is one stack with Home at its root. The iPad's is the workspace, whose
    /// columns fold back into that same stack whenever the window is too narrow for them.
    private func makeMain() -> UIViewController {
        let home = HomeViewController()
        mainHome = home
        home.onOpenSettings = { [weak self, weak home] in
            guard let self, let home else { return }
            self.presentSettings(from: home.navigationController ?? home)
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            return WorkspaceSplitViewController(
                home: home, startsCollapsed: window.traitCollection.horizontalSizeClass == .compact)
        }
        let nav = UINavigationController(rootViewController: home)
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }

    private func presentSettings(
        from presenter: UIViewController, section: SettingsViewController.Section? = nil
    ) {
        let settings = SettingsViewController(initialSection: section)
        settings.onFinish = { [weak self] in self?.syncRootIfNeeded() }
        let nav = UINavigationController(rootViewController: settings)
        nav.presentationController?.delegate = self
        presenter.present(nav, animated: true)
    }
}

extension AppCoordinator: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        syncRootIfNeeded()
    }
}
