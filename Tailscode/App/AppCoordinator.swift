import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class AppCoordinator {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func start() {
        window.tintColor = Theme.Color.accent
        window.overrideUserInterfaceStyle = AppPreferences.appearance.style
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
        #endif
    }

    #if DEBUG
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

    /// Routes `tailscode://session/<id>` (Live Activity tap) to that chat.
    /// Links that arrive before the session list exists are parked and
    /// delivered on the next route to the main UI; a link older than 30s is
    /// dropped rather than hijacking navigation long after the tap.
    func handle(_ url: URL) {
        guard url.scheme == "tailscode", url.host() == "session" else { return }
        let sessionID = url.lastPathComponent
        guard !sessionID.isEmpty else { return }
        guard let home else {
            pendingSessionLink = (url, Date())
            return
        }
        pendingSessionLink = nil
        home.openSession(withID: sessionID)
    }

    private var home: HomeViewController? {
        (window.rootViewController as? UINavigationController)?
            .viewControllers.first as? HomeViewController
    }

    private func route(animated: Bool) {
        let root = ConnectionController.shared.hasConnection ? makeMain() : makeOnboarding()
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
    }

    private func makeOnboarding() -> UIViewController {
        let onboarding = OnboardingViewController()
        onboarding.onConnected = { [weak self] in self?.route(animated: true) }
        return UINavigationController(rootViewController: onboarding)
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

    private func presentSettings(from presenter: UIViewController) {
        let settings = SettingsViewController()
        settings.onConnectionChanged = { [weak self] in
            presenter.dismiss(animated: true) { self?.route(animated: true) }
        }
        let nav = UINavigationController(rootViewController: settings)
        presenter.present(nav, animated: true)
    }
}
