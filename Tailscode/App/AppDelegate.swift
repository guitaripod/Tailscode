import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppLogger.lifecycle.info("didFinishLaunching")
        ProStore.shared.start()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        endOrphanedActivitiesIfForeground(application)
        UsageBackgroundRefresh.register()
        UsageBackgroundRefresh.schedule()
        application.registerForRemoteNotifications()
        return true
    }

    /// Reaping only makes sense when the user actually launched the app: this
    /// same delegate registers a background refresh task and remote
    /// notifications, so the system relaunches us headless — and a background
    /// launch that reaps would end the Lock Screen activity of a turn that is
    /// still running, which is precisely the activity the user is relying on.
    private func endOrphanedActivitiesIfForeground(_ application: UIApplication) {
        guard application.applicationState != .background else { return }
        AppActivityController.shared.endOrphanedActivities()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppLogger.connection.info("push: received APNs device token")
        PushRegistrar.register(tokenHex: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        AppLogger.connection.error(
            "push: remote-notification registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let applied = UsagePushPayload.apply(userInfo: userInfo)
        AppLogger.connection.info("push: silent notification applied \(applied) usage snapshot(s)")
        completionHandler(applied > 0 ? .newData : .noData)
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
