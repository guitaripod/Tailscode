import TailscodeCore
import TailscodeMetal
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var coordinator: AppCoordinator?
    private var isWatch = false

    /// Whether this scene is the app's own window and not a wall of its own.
    var hostsApp: Bool { coordinator != nil }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        LockedBoot.open(forAWindow: true)
        let window = TouchReportingWindow(windowScene: windowScene)
        if WatchScene.wants(connectionOptions, session: session) {
            installWatch(in: window)
            return
        }
        #if DEBUG
            if let preview = AwayPreview.viewControllerIfRequested()
                ?? NoticeCardPreview.viewControllerIfRequested()
            {
                window.rootViewController = preview
                window.makeKeyAndVisible()
                self.window = window
                return
            }
        #endif
        let coordinator = AppCoordinator(window: window)
        self.window = window
        self.coordinator = coordinator
        coordinator.start()
        Task { @MainActor in BrainPictures.prewarm() }
        WallRenderer.prewarm()
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
        } else if connectionOptions.urlContexts.isEmpty, connectionOptions.shortcutItem == nil,
            let restored = session.stateRestorationActivity,
            let url = SceneRouting.url(from: restored)
        {
            coordinator.handle(url)
        }
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        isWatch ? WatchScene.activity() : coordinator?.restorationActivity()
    }

    private func installWatch(in window: UIWindow) {
        Theme.Chrome.adopt(window)
        Theme.Chrome.apply()
        window.rootViewController = WatchViewController(standalone: true)
        window.makeKeyAndVisible()
        self.window = window
        isWatch = true
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

    @available(iOS 26.0, *)
    func windowScene(
        _ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry
    ) {
        guard !windowScene.effectiveGeometry.isInteractivelyResizing else { return }
        NotificationCenter.default.post(name: HandReach.didChange, object: windowScene)
    }

    /// Before iPadOS 26 a window moved across the screen is told through this one, which iPadOS 26
    /// replaced with the geometry update above and stopped calling.
    @available(iOS, introduced: 13.0, deprecated: 26.0)
    func windowScene(
        _ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: any UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        NotificationCenter.default.post(name: HandReach.didChange, object: windowScene)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        coordinator?.handle(url)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppActivityController.shared.setInFront(true)
        DeskHold.shared.cameForward()
        ProAccess.shared.refreshProWeek()
        Task { await AppActivityController.shared.catchUp() }
        NotificationManager.syncBadge()
        coordinator?.handleControlRouteIfNeeded()
        PushRegistrar.reregisterIfNeeded()
        UpdateMonitor.checkIfDue()
        HapticEngine.shared.prepare()
        ReviewPromptCoordinator.shared.appDidBecomeActive()
    }

    /// The last point at which a task handed to `TurnWaitCenter`'s background session starts like
    /// a foreground request rather than a merely discretionary one — after this, arming has to
    /// wait for whatever the system feels like giving it.
    func sceneWillResignActive(_ scene: UIScene) {
        AppActivityController.shared.setInFront(false)
        TurnWaitCenter.shared.armForBackground()
        DeskHold.shared.wentBack()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        NotificationManager.syncBadge()
        UsageBackgroundRefresh.schedule()
        HapticEngine.shared.relinquish()
    }

    /// Answers whether the route was actually taken: a scene that exists before its coordinator
    /// does must say so, or the tap or the question that made it is silently dropped.
    @discardableResult
    func route(_ route: PendingRoute.Route) -> Bool {
        guard let coordinator else { return false }
        coordinator.take(route)
        return true
    }
}
