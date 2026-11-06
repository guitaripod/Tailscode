import CodingAgentKitApple
import MidgarUI
import UIKit

extension SettingsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        guard text != query else { return }
        query = text
        applySnapshot()
    }
}

extension SettingsViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        lastScrollAt = CACurrentMediaTime()
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath)
        -> Bool
    {
        isSelectable(at: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath)
        -> Bool
    {
        isSelectable(at: indexPath)
    }

    /// A row that only states something does not light under a finger. A search result always does,
    /// because every result opens the page it lives on.
    private func isSelectable(at indexPath: IndexPath) -> Bool {
        if case .results(let page)? = section(at: indexPath), page != .root { return true }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .midgar, .toggle, .tailnetScan, .version, nil: return false
        case .notificationPermission:
            return notificationStatus == .notDetermined || notificationStatus == .denied
        case .backgroundRefresh: return backgroundRefreshDetail().actionable
        case .pushState(let id):
            guard let profile = facts.profiles.first(where: { $0.id == id }) else { return false }
            return PushRegistrar.state(for: profile.baseURL) != .registered
        default: return true
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        if case .results(let page)? = section(at: indexPath), page != .root {
            Theme.Haptics.tap()
            open(page, highlighting: item, animated: true)
            return
        }
        switch item {
        case .page(let page):
            Theme.Haptics.tap()
            open(page, animated: true)
        case .connectionAlert:
            if ServerHealthMonitor.verdict() == .tailnetDown {
                TailnetStatus.openTailscaleApp()
            } else {
                testAllConnections()
            }
        case .profile(let profile) where facts.resting.contains(profile.id):
            presentRestingChoices(for: profile, at: indexPath)
        case .profile(let profile):
            let detail = ServerDetailViewController(profile: profile)
            navigationController?.pushViewController(detail, animated: true)
        case .addConnection:
            requestAnotherConnection { [weak self] in
                guard let self else { return }
                let setup = ServerSetupViewController(mode: .addServer)
                setup.onConnected = { [weak self] in
                    guard let self else { return }
                    self.navigationController?.popToViewController(self, animated: true)
                }
                self.navigationController?.pushViewController(setup, animated: true)
            }
        case .discover:
            requestAnotherConnection { [weak self] in
                let discovery = DiscoveryViewController()
                self?.navigationController?.present(
                    UINavigationController(rootViewController: discovery), animated: true)
            }
        case .leaveDemo:
            ConnectionController.shared.leaveDemoMode()
            Theme.Haptics.warning()
        case .tailnetStatus:
            Theme.Haptics.tap()
            TailnetStatus.openTailscaleApp()
        case .tailnetToken:
            let editor = TailnetTokenViewController()
            editor.onChange = { [weak self] in self?.applySnapshot() }
            navigationController?.pushViewController(editor, animated: true)
        case .notificationPermission:
            handlePermissionTap()
        case .backgroundRefresh:
            guard backgroundRefreshDetail().actionable else { return }
            Theme.Haptics.tap()
            NotificationManager.openSystemSettings()
        case .pushState:
            Theme.Haptics.tap()
            PushRegistrar.reregisterIfNeeded()
        case .testNotification:
            Theme.Haptics.tap()
            presentSamplePicker()
        case .software, .softwareUpdate:
            Theme.Haptics.tap()
            UpdateCenterViewController.present(from: self)
        case .usage:
            navigationController?.pushViewController(UsageViewController(), animated: true)
        case .deepseekKey:
            Theme.Haptics.tap()
            let editor = DeepSeekKeyViewController()
            editor.onChange = { [weak self] in
                self?.applySnapshot()
                Task { await DeepSeekBalance.refresh() }
            }
            navigationController?.pushViewController(editor, animated: true)
        case .ollamaKey:
            Theme.Haptics.tap()
            let editor = OllamaKeyViewController()
            editor.onChange = { [weak self] in
                self?.applySnapshot()
                Task { await OllamaUsage.refresh() }
            }
            navigationController?.pushViewController(editor, animated: true)
        case .pro:
            Theme.Haptics.tap()
            ProUpgradeViewController.present(from: self, placement: .settings)
        case .viewLogs:
            navigationController?.pushViewController(LogViewerViewController(), animated: true)
        case .testAll:
            testAllConnections()
        case .copyDiagnostics:
            copyDiagnostics()
        case .emailDiagnostics:
            emailDiagnostics()
        case .source:
            open(Self.sourceURL)
        case .privacy:
            open(Self.privacyURL)
        case .support:
            open(Self.supportURL)
        case .rate:
            Theme.Haptics.tap()
            UIApplication.shared.open(AppStoreLinks.writeReview)
        case .share:
            Theme.Haptics.tap()
            shareApp(from: indexPath)
        case .licenses:
            navigationController?.pushViewController(LicensesViewController(), animated: true)
        case .keyboardShortcuts:
            ShortcutCheatsheetViewController.present(from: self)
        case .streamRenderer:
            Theme.Haptics.tap()
            navigationController?.pushViewController(
                StreamRendererViewController(), animated: true)
        case .haptics:
            Theme.Haptics.tap()
            navigationController?.pushViewController(HapticsViewController(), animated: true)
        case .appearance:
            Theme.Haptics.tap()
            let picker = ThemePickerViewController()
            navigationController?.pushViewController(picker, animated: true)
        case .noticeFinish:
            chooseNoticeFinish()
        case .noticeMinimum:
            chooseNoticeMinimum()
        case .unmuteAll:
            confirmUnmuteAll(from: indexPath)
        case .chatDensity:
            chooseDensity()
        case .activityStyle:
            chooseActivityStyle()
        case .midgar, .toggle, .version, .tailnetScan:
            break
        }
    }

    private func testAllConnections() {
        Theme.Haptics.tap()
        ServerHealthMonitor.clear()
        Task { await ServerHealthMonitor.checkAll(force: true) }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, case .version = dataSource.itemIdentifier(for: indexPaths[0])
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copy = UIAction(
                title: String(localized: "Copy version"), image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = MidgarVersionInfo().copyText
                Theme.Haptics.tap()
            }
            return UIMenu(children: [copy])
        }
    }
}
