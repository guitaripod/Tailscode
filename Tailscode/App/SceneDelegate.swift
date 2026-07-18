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
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        coordinator?.handle(url)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        coordinator?.handleControlRouteIfNeeded()
        PushRegistrar.reregisterIfNeeded()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        UsageBackgroundRefresh.schedule()
    }

    func routeDeepLink(_ url: URL) {
        coordinator?.handle(url)
    }
}
