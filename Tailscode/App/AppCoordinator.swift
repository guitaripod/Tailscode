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
        window.tintColor = Theme.Color.accent
        window.overrideUserInterfaceStyle = AppPreferences.appearance.style
        #if DEBUG
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--widget-preview") }) {
                window.rootViewController = UINavigationController(
                    rootViewController: WidgetPreviewViewController(
                        alt: CommandLine.arguments.contains("--widget-preview-alt")))
                window.makeKeyAndVisible()
                return
            }
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--enhance-preview") }) {
                window.rootViewController = EnhancePreviewViewController()
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
            if let sessionID = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SESSION"] {
                handle(URL(string: "tailscode://session/\(sessionID)")!)
            }
            if CommandLine.arguments.contains("--usage") {
                openUsageForDebug()
            }
            if let slug = ProcessInfo.processInfo.environment["TAILSCODE_SETTINGS_SECTION"] {
                openSettingsForDebug(slug: slug)
            }
            if CommandLine.arguments.contains("--tour") { TourDriver.start(in: window) }
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
            guard let nav = window.rootViewController as? UINavigationController else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                nav.pushViewController(UsageViewController(), animated: false)
            }
        }

        private func seedDebugConnectionIfNeeded() {
            let env = ProcessInfo.processInfo.environment
            guard let host = env["TAILSCODE_HOST"], let url = URL(string: host) else { return }
            guard !ConnectionController.shared.hasConnection else {
                AppLogger.connection.info("seed skipped — already connected")
                return
            }
            let backend: AgentType = env["TAILSCODE_BACKEND"] == "claude" ? .claudeCode : .openCode
            seed(id: "debug", url: url, backend: backend, password: env["TAILSCODE_PASSWORD"])

            if let extra = env["TAILSCODE_HOST2"], let url2 = URL(string: extra) {
                let backend2: AgentType = env["TAILSCODE_BACKEND2"] == "claude" ? .claudeCode : .openCode
                seed(id: "debug2", url: url2, backend: backend2, password: env["TAILSCODE_PASSWORD2"])
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

    /// The New Chat icon quick action: focus the Home composer, or park the
    /// intent when it arrives before the main UI exists (cold launch).
    @discardableResult
    func handleShortcut(_ type: String) -> Bool {
        guard type == "com.guitaripod.tailscode.compose" else { return false }
        if let home {
            home.focusComposer()
        } else {
            pendingComposeFocus = true
        }
        return true
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
        let sessionID = url.lastPathComponent
        guard !sessionID.isEmpty else { return }
        guard let home else {
            pendingSessionLink = (url, Date())
            return
        }
        pendingSessionLink = nil
        home.openSession(withID: sessionID)
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

    /// The Top Usage control opens the app and leaves a route flag in the shared App Group
    /// (a custom URL scheme is unreliable from a Control). Consume it on foreground.
    func handleControlRouteIfNeeded() {
        guard let route = UsageWidgetStore.takePendingControlRoute() else { return }
        if route == "usage" { handle(URL(string: "tailscode://usage")!) }
    }

    private var home: HomeViewController? {
        (window.rootViewController as? UINavigationController)?
            .viewControllers.first as? HomeViewController
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
            if Date().timeIntervalSince(pending.parkedAt) < 30 { handle(pending.url) }
        }
        if pendingComposeFocus {
            pendingComposeFocus = false
            home?.focusComposer()
        }
    }

    private func makeOnboarding() -> UIViewController {
        let welcome = WelcomeViewController()
        welcome.onConnected = { [weak self] in self?.route(animated: true) }
        let nav = UINavigationController(rootViewController: welcome)
        nav.navigationBar.prefersLargeTitles = true
        return nav
    }

    private func makeMain() -> UIViewController {
        let home = HomeViewController()
        home.onOpenSettings = { [weak self, weak home] in
            guard let self, let home else { return }
            self.presentSettings(from: home.navigationController ?? home)
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
