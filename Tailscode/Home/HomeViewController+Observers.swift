import MidgarCore
import TailscodeCore
import UIKit

extension HomeViewController {
    func bind() {
        viewModel.onChange = { [weak self] in
            guard let self else { return }
            self.updateComposeButton()
            self.updateComposer()
            self.applySnapshot()
            SessionActivity.shared.wakeHeldQueues(entries: self.viewModel.entries) {
                self.viewModel.backend(forProfileID: $0)
            }
            SessionActivity.shared.wakeLiveCards(entries: self.viewModel.entries) {
                self.viewModel.backend(forProfileID: $0)
            }
        }
        viewModel.onError = { [weak self] message in
            self?.refreshControl.endRefreshing()
            MidgarLog.error("home load: \(message)", category: .session)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: SessionActivity.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(savedDidChange),
            name: SavedChatStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: SessionSeenStore.didSync, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: ActivityInbox.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(archiveDidChange),
            name: ArchivedChatStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardDidChange),
            name: QuotaBoardStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            forName: ModelCatalogStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.boardDidChange() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillResign(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(connectionsDidChange),
            name: ConnectionController.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatesDidChange),
            name: UpdateMonitor.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(supporterDidChange),
            name: SupporterInvitation.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(supporterDidChange),
            name: ProAccess.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateVideoMark),
            name: ForgeRunner.didChange, object: nil)
        for name: Notification.Name in [
            ImageStudio.didChange, ImageGenStore.didChange, ForgeStore.didChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateImageMark), name: name, object: nil)
        }
        for name: Notification.Name in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(flushState), name: name, object: nil)
        }
    }

    @objc private func activityDidChange() { applySnapshot() }

    @objc private func archiveDidChange() { applySnapshot() }

    @objc private func boardDidChange() { applySnapshot() }

    /// Settings edited the servers. Rebuilding the backends here — rather than
    /// recreating the whole screen — keeps scroll position, the composer draft,
    /// and any in-flight chat intact through something as small as a rename.
    @objc private func connectionsDidChange() {
        viewModel.refreshSources()
        resolvedComposeTarget = nil
        updateLeftBarItems()
        updateComposeButton()
        updateComposer()
        applySnapshot()
        Task { await load(.user) }
    }

    /// This board's own window going active or inactive, not the app's. The app supports more
    /// than one window on iPad, so `UIApplication.didBecomeActive`/`willResignActive` fire once
    /// for the whole process and say nothing about *this* scene — a second Tailscode window
    /// taking focus never quiets this one's clock, and a window that regains focus without the
    /// app itself ever having left the foreground never restarts it. `SceneDelegate` already
    /// answers the equivalent per-scene callbacks for everything else; this filters the
    /// notification form of the same signal down to the scene this view actually lives in.
    private func ownsScene(_ note: Notification) -> Bool {
        guard let scene = note.object as? UIScene else { return true }
        return scene === viewIfLoaded?.window?.windowScene
    }

    @objc private func sceneDidActivate(_ note: Notification) {
        guard ownsScene(note) else { return }
        Task { await load(.user) }
        startLiveRefresh()
    }

    @objc private func sceneWillResign(_ note: Notification) {
        guard ownsScene(note) else { return }
        stopLiveRefresh()
        flushState()
    }

    /// Whether this screen's own window is the one actually in front, read at the scene's own
    /// granularity rather than the app's — the check `startClockTick`/`startLiveRefresh` gate on.
    var isSceneForeground: Bool {
        viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    /// Everything this screen writes on a trailing edge, taken now — the debounce window is not
    /// something a process about to be suspended can wait out.
    @objc private func flushState() {
        DraftStore.flush()
        SessionListCache.flushPendingSave()
    }

    @objc func openSettings() {
        view.endEditing(true)
        onOpenSettings?()
    }
    @objc func refresh() { Task { await load(.user) } }

    @objc private func savedDidChange() {
        savedChats = SavedChatStore.all()
        applySnapshot()
    }
}

extension HomeViewController {
    /// The store's price for the unlock, fetched once the card is due so the button can name it.
    private static var fetchedProPrice: String?

    var proPrice: String? {
        if let price = Self.fetchedProPrice { return price }
        Task { @MainActor [weak self] in
            guard let product = await ProAccess.shared.products().pro else { return }
            Self.fetchedProPrice = product.displayPrice
            self?.applySnapshot()
        }
        return nil
    }

    /// The card follows the demo itself, so it goes the moment a real server is saved or the demo
    /// is left, and the screenshot pipeline's switch for the badge hides it the same way.
    var showsDemoNudge: Bool {
        DemoNudge.isShown(demoActive: ConnectionController.shared.isDemoMode) && !Self.demoBadgeHidden
    }

    func dismissDemoNudge() {
        Theme.Haptics.selection()
        DemoNudge.dismiss()
        applySnapshot()
    }

    @objc private func supporterDidChange() {
        if ProAccess.shared.isPro { SupporterInvitation.settle() }
        applySnapshot()
    }

    func openSupporterOffer() {
        Theme.Haptics.tap()
        ProUpgradeViewController.present(from: self)
    }

    func declineSupporterOffer() {
        Theme.Haptics.selection()
        SupporterInvitation.dismiss()
    }
}
