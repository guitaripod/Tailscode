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
        #if DEBUG
            if CommandLine.arguments.contains("--demo") {
                showDemo()
                window.makeKeyAndVisible()
                return
            }
            seedDebugConnectionIfNeeded()
        #endif
        route(animated: false)
        window.makeKeyAndVisible()
    }

    #if DEBUG
        private func seedDebugConnectionIfNeeded() {
            let env = ProcessInfo.processInfo.environment
            guard let host = env["TAILSCODE_HOST"], let url = URL(string: host) else { return }
            guard !ConnectionController.shared.hasConnection else {
                AppLogger.connection.info("seed skipped — already connected")
                return
            }
            let backend: AgentType = env["TAILSCODE_BACKEND"] == "claude" ? .claudeCode : .openCode
            let profile = ConnectionProfile(
                id: "debug", name: url.host ?? "Debug", backend: backend, baseURL: url)
            ConnectionController.shared.setOverridePassword(env["TAILSCODE_PASSWORD"], for: profile.id)
            do {
                try ConnectionController.shared.save(profile, password: env["TAILSCODE_PASSWORD"])
                AppLogger.connection.info("seed saved profile for \(url.host ?? "?")")
            } catch {
                ConnectionController.shared.setActive(profile.id)
                AppLogger.connection.error("seed keychain failed (\(error)); using override")
            }
        }

        private func showDemo() {
            let viewModel = ChatViewModel(backend: DemoBackend.make(), session: DemoBackend.session)
            let chat = ChatViewController(viewModel: viewModel)
            let nav = UINavigationController(rootViewController: chat)
            window.rootViewController = nav
        }
    #endif

    private func route(animated: Bool) {
        let root = ConnectionController.shared.hasConnection ? makeMain() : makeOnboarding()
        if animated {
            UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
                self.window.rootViewController = root
            }
        } else {
            window.rootViewController = root
        }
    }

    private func makeOnboarding() -> UIViewController {
        let onboarding = OnboardingViewController()
        onboarding.onConnected = { [weak self] in self?.route(animated: true) }
        return UINavigationController(rootViewController: onboarding)
    }

    private func makeMain() -> UIViewController {
        let list = SessionListViewController()
        list.onOpenSettings = { [weak self, weak list] in
            guard let self, let list else { return }
            self.presentSettings(from: list)
        }
        let nav = UINavigationController(rootViewController: list)
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
