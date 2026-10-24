import MidgarCore
import TailscodeCore
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        TailscodeLogging.configure()
        MidgarLog.info("didFinishLaunching", category: .lifecycle)
        ReviewPromptPolicy.migrateIfNeeded()
        FieldMetrics.shared.start()
        MainStallMonitor.shared.start()
        MemoryRelief.install()
        ShortcutSet.configDirectoryOverride = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
        TailscodeMidgar.shared.start()
        ProAccess.shared.start()
        GameCenterCoordinator.shared.startWhenIdle()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        NotificationManager.registerCategories()
        NotificationManager.syncBadge()
        #if DEBUG
            NoticeDebug.runIfRequested()
            ChatRebuildBench.runIfRequested()
        #endif
        NotificationCenter.default.addObserver(
            forName: ActivityInbox.didChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { NotificationManager.syncBadge() }
        }
        AppActivityController.shared.adoptStanding()
        TurnWaitCenter.shared.start()
        UsageBackgroundRefresh.register()
        UsageBackgroundRefresh.schedule()
        application.registerForRemoteNotifications()
        return true
    }

    /// The system relaunched or resumed this process to deliver what a background `URLSession`
    /// finished while it wasn't running — one or more armed turn waits, in practice. The
    /// completion handler is `TurnWaitCenter`'s own to call, once every wait this wake delivered
    /// has become a notification, a settled Live Activity and a diagnostics line.
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == TurnWaitCenter.sessionIdentifier else {
            completionHandler()
            return
        }
        MidgarLog.info("handleEventsForBackgroundURLSession: \(identifier)", category: .lifecycle)
        TurnWaitCenter.shared.awaitBackgroundEvents(completion: completionHandler)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        MidgarLog.info("push: received APNs device token", category: .connection)
        PushRegistrar.register(tokenHex: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        MidgarLog.error(
            "push: remote-notification registration failed: \(error.localizedDescription)", category: .connection)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let applied = UsagePushPayload.apply(userInfo: userInfo)
        MidgarLog.info(
            "push: silent notification applied \(applied) usage snapshot(s)", category: .connection)
        if applied > 0 {
            let providers = UsagePushPayload.providers(from: userInfo)
            Task { @MainActor in
                UsageWarnings.evaluate(providers: providers)
                let names = Set(providers.map(\.providerName))
                RangeRecorder.observe(
                    quotas: UsageWidgetStore.cachedQuotas().filter { names.contains($0.providerName) })
            }
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
