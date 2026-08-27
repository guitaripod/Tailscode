import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var coordinator: AppCoordinator?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let coordinator = AppCoordinator(window: window)
        self.window = window
        self.coordinator = coordinator
        coordinator.start()
        if let url = connectionOptions.urlContexts.first?.url {
            coordinator.handle(url)
        }
        if let shortcut = connectionOptions.shortcutItem {
            coordinator.handleShortcut(shortcut)
        }
        if let activity = connectionOptions.userActivities.first,
            let url = SceneRouting.url(from: activity)
        {
            coordinator.handle(url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let url = SceneRouting.url(from: userActivity) else { return }
        coordinator?.handle(url)
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(coordinator?.handleShortcut(shortcutItem) ?? false)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        coordinator?.handle(url)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        coordinator?.handleControlRouteIfNeeded()
        PushRegistrar.reregisterIfNeeded()
        UpdateMonitor.checkIfDue()
        HapticEngine.shared.prepare()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        UsageBackgroundRefresh.schedule()
        HapticEngine.shared.relinquish()
    }

    /// Answers whether the link was actually taken: a scene that exists before its coordinator
    /// does must say so, or the tap that made it is silently dropped.
    @discardableResult
    func routeDeepLink(_ url: URL) -> Bool {
        guard let coordinator else { return false }
        coordinator.handle(url)
        return true
    }
}
