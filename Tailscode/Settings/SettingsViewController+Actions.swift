import CodingAgentKitApple
import SafariServices
import TailscodeCore
import UIKit

extension SettingsViewController {
    func removeProfile(_ profile: ConnectionProfile) {
        let isDemo = profile.id.hasPrefix(DemoWorld.profilePrefix)
        let alert = UIAlertController(
            title: isDemo
                ? String(localized: "Leave the demo?")
                : String(localized: "Remove \(profile.name)?"),
            message: isDemo
                ? String(localized: "This removes both sample servers.")
                : String(
                    localized: "This deletes the saved server and its password from the Keychain."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Remove"), style: .destructive) { _ in
            try? ConnectionController.shared.delete(profile.id)
            ServerHealthMonitor.forget(profile.id)
            Theme.Haptics.warning()
        })
        present(alert, animated: true)
    }

    /// The first server is free forever; additional saved servers are the Pro gate, counted over every saved server,
    /// resting ones included. A gated copy meets the Pro sheet, and `proceed` runs once Pro is open, by the week or a
    /// purchase, so adding the server carries on where it stopped.
    func requestAnotherConnection(_ proceed: @escaping () -> Void) {
        let realProfiles = ConnectionController.shared.savedProfiles.filter {
            !$0.id.hasPrefix(DemoWorld.profilePrefix)
        }
        guard !ProAccess.shared.hasProAccess, !realProfiles.isEmpty else {
            proceed()
            return
        }
        ProUpgradeViewController.present(from: self, placement: .limit, onAccess: proceed)
    }

    /// A resting server's choices: keep it connected in place of one that is, get Pro to keep every server connected, or
    /// remove it.
    func presentRestingChoices(for profile: ConnectionProfile, at indexPath: IndexPath) {
        let connected = ConnectionController.shared.profiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }
        let sheet = UIAlertController(title: profile.name, message: ProWeek.restingDetail, preferredStyle: .actionSheet)
        for other in connected {
            let title = connected.count == 1 ? ProWeek.useInsteadTitle : ProWeek.useInsteadOf(other.name)
            sheet.addAction(
                UIAlertAction(title: title, style: .default) { _ in
                    Theme.Haptics.success()
                    ConnectionController.shared.keepConnected(profile.id, replacing: other.id)
                })
        }
        sheet.addAction(
            UIAlertAction(title: String(localized: "Get Tailscode Pro"), style: .default) { [weak self] _ in
                guard let self else { return }
                ProUpgradeViewController.present(from: self, placement: .limit)
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "Remove"), style: .destructive) { [weak self] _ in
                self?.removeProfile(profile)
            })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let popover = sheet.popoverPresentationController {
            let cell = collectionView.cellForItem(at: indexPath)
            popover.sourceView = cell ?? view
            popover.sourceRect = cell?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    /// Which notice to send to this phone, so each kind can be seen on the Lock Screen and pulled
    /// down into its long look, buttons and reply field included.
    func presentSamplePicker() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for sample in NoticeSample.allCases {
            sheet.addAction(
                UIAlertAction(title: sample.menuTitle, style: .default) { _ in
                    NotificationManager.sendTest(sample)
                })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    func handlePermissionTap() {
        switch notificationStatus {
        case .notDetermined:
            Task { [weak self] in
                await NotificationManager.requestAuthorization()
                self?.refreshEnvironment()
            }
        case .denied:
            NotificationManager.openSystemSettings()
        default:
            break
        }
    }

    func copyDiagnostics() {
        Task { [weak self] in
            let report = await DiagnosticsReport.build()
            UIPasteboard.general.string = report
            Theme.Haptics.success()
            guard let self else { return }
            let alert = UIAlertController(
                title: String(localized: "Copied"),
                message: String(localized: "Diagnostics are on the clipboard."),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            self.present(alert, animated: true)
        }
    }

    func emailDiagnostics() {
        Task { [weak self] in
            let report = await DiagnosticsReport.build()
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = Self.supportEmail
            components.queryItems = [
                URLQueryItem(name: "subject", value: "Tailscode \(Self.versionString)"),
                URLQueryItem(name: "body", value: "\n\n---\n\(report)"),
            ]
            guard let url = components.url else { return }
            UIApplication.shared.open(url, options: [:]) { opened in
                guard !opened else { return }
                UIPasteboard.general.string = report
                Task { @MainActor in self?.presentMailFallback() }
            }
        }
    }

    private func presentMailFallback() {
        let alert = UIAlertController(
            title: String(localized: "No mail account"),
            message: String(
                localized:
                    "Diagnostics were copied to the clipboard instead. Send them to \(Self.supportEmail)."
            ),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        present(SFSafariViewController(url: url), animated: true)
    }

    /// Hands the store listing to the share sheet, anchored on the row that asked for it so the
    /// iPad's popover has somewhere to point.
    func shareApp(from indexPath: IndexPath) {
        let sheet = UIActivityViewController(activityItems: AppStoreLinks.shareItems, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            let anchor: UIView = collectionView.cellForItem(at: indexPath) ?? collectionView
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        present(sheet, animated: true)
    }

    @objc func done() {
        dismiss(animated: true) { [onFinish] in onFinish?() }
    }
}
