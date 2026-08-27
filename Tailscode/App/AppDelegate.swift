import TailscodeCore
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppLogger.lifecycle.info("didFinishLaunching")
        ShortcutSet.configDirectoryOverride = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
        ProStore.shared.start()
        GameCenterCoordinator.shared.start()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        NotificationManager.registerCategories()
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
        if applied > 0 {
            let providers = UsagePushPayload.providers(from: userInfo)
            Task { @MainActor in UsageWarnings.evaluate(providers: providers) }
        }
        completionHandler(applied > 0 ? .newData : .noData)
    }

    /// The menu bar an iPad (and a Mac running the iPad app) shows. Every item rides the same
    /// `tailscode://` routes the rest of the app already answers, delivered to the frontmost
    /// window's coordinator.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .format)
        let chat = UIMenu(
            options: .displayInline,
            children: [
                UIKeyCommand(
                    title: String(localized: "New Chat"), action: #selector(menuNewChat),
                    input: "n", modifierFlags: .command),
                UIKeyCommand(
                    title: String(localized: "Quick Ask"), action: #selector(menuQuickAsk),
                    input: "n", modifierFlags: [.command, .shift]),
            ])
        let places = UIMenu(
            options: .displayInline,
            children: [
                UIKeyCommand(
                    title: String(localized: "Saved Chats"), action: #selector(menuSaved),
                    input: "s", modifierFlags: [.command, .alternate]),
                UIKeyCommand(
                    title: String(localized: "Usage"), action: #selector(menuUsage),
                    input: "u", modifierFlags: [.command, .alternate]),
            ])
        builder.insertChild(chat, atStartOfMenu: .file)
        builder.insertChild(places, atStartOfMenu: .view)
        builder.insertSibling(
            UIMenu(
                options: .displayInline,
                children: [
                    UIKeyCommand(
                        title: String(localized: "Settings…"), action: #selector(menuSettings),
                        input: ",", modifierFlags: .command)
                ]),
            afterMenu: .about)
    }

    @objc private func menuNewChat() { PendingRoute.deliver(URL(string: "tailscode://compose")!) }
    @objc private func menuQuickAsk() { PendingRoute.deliver(URL(string: "tailscode://ask")!) }
    @objc private func menuSaved() { PendingRoute.deliver(URL(string: "tailscode://saved")!) }
    @objc private func menuUsage() { PendingRoute.deliver(URL(string: "tailscode://usage")!) }
    @objc private func menuSettings() {
        PendingRoute.deliver(URL(string: "tailscode://settings")!)
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
