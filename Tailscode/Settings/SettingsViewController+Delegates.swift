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
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath)
        -> Bool
    {
        dataSource.itemIdentifier(for: indexPath) != .midgar
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath)
        -> Bool
    {
        dataSource.itemIdentifier(for: indexPath) != .midgar
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .connectionAlert:
            if ServerHealthMonitor.verdict() == .tailnetDown {
                TailnetStatus.openTailscaleApp()
            } else {
                testAllConnections()
            }
        case .profile(let profile):
            let detail = ServerDetailViewController(profile: profile)
            navigationController?.pushViewController(detail, animated: true)
        case .addConnection:
            guard allowAnotherConnection() else { return }
            let setup = ServerSetupViewController(mode: .addServer)
            setup.onConnected = { [weak self] in
                guard let self else { return }
                self.navigationController?.popToViewController(self, animated: true)
            }
            navigationController?.pushViewController(setup, animated: true)
        case .discover:
            guard allowAnotherConnection() else { return }
            let discovery = DiscoveryViewController()
            navigationController?.present(
                UINavigationController(rootViewController: discovery), animated: true)
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
        case .software:
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
            ProUpgradeViewController.present(from: self)
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
        case .chatDensity:
            chooseDensity(from: indexPath)
        case .activityStyle:
            chooseActivityStyle(from: indexPath)
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
