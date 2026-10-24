import MidgarCore
import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

extension ServerDetailViewController {
    /// The press: ask the machine to open its own Privacy & Security pane, log what happened, and
    /// start the poll that notices the switch without a refresh gesture.
    func requestPermission(_ kind: MachinePermissions.Grant.Kind) {
        guard let backend = backend as? any PermissionReportingBackend else { return }
        permissionRequesting = kind
        reconfigure([.permissions])
        Theme.Haptics.tap()
        MidgarLog.info("requesting \(kind.rawValue) on \(profile.name)", category: .connection)
        Task { [weak self] in
            guard let self else { return }
            do {
                if let updated = try await backend.requestMachinePermission(kind) {
                    self.permissions = updated
                }
                self.permissionRequesting = nil
                self.reconfigure([.permissions])
                self.startPermissionPollingIfNeeded()
            } catch {
                self.permissionRequesting = nil
                self.reconfigure([.permissions])
                MidgarLog.error(
                    "permission request failed on \(self.profile.name): \(error)", category: .connection)
                self.presentToast(MachinePermissionReading.requestFailed)
            }
        }
    }

    func startPermissionPollingIfNeeded() {
        guard let permissions, MachinePermissionReading.isWaiting(permissions),
            permissionPollTask == nil
        else { return }
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MachinePermissionReading.pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.pollPermissions()
            }
        }
    }

    func stopPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
    }

    private func pollPermissions() async {
        guard let backend = backend as? any PermissionReportingBackend else {
            stopPermissionPolling()
            return
        }
        guard let updated = try? await backend.machinePermissions() else { return }
        let wasWaiting = permissions.map { MachinePermissionReading.isWaiting($0) } ?? false
        permissions = updated
        reconfigure([.permissions])
        if wasWaiting, updated.isComplete {
            Theme.Haptics.success()
            MidgarLog.info("permission granted on \(profile.name)", category: .connection)
        }
        if !MachinePermissionReading.isWaiting(updated) { stopPermissionPolling() }
    }

    private func presentToast(_ message: String) {
        ToastView(message: message).flash(in: view, above: view.safeAreaLayoutGuide.bottomAnchor)
    }

    private func presentEditor() {
        let editor = ServerEditViewController(profile: profile)
        editor.onSaved = { [weak self] updated in
            guard let self else { return }
            self.profile = updated
            self.title = updated.name
            self.applySnapshot()
            Task { await self.refresh() }
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    func makeDefault() {
        ConnectionController.shared.setActive(profile.id)
        Theme.Haptics.success()
        applySnapshot()
    }

    /// The press states its cost first, then hands the ask over and stops. Nothing waits on a
    /// reply: the connection the ask went over dies with the process it restarted, so the ordinary
    /// reconnect — which every screen already watches — is what says the machine is back.
    private func confirmRestart() {
        let alert = UIAlertController(
            title: ServerRestart.confirmTitle(profile.name),
            message: ServerRestart.confirmBody(
                workingTurns: SessionActivity.shared.workingCount(onProfile: profile.id)),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: ServerRestart.action, style: .destructive) { [weak self] _ in
                self?.restartServer()
            })
        present(alert, animated: true)
    }

    private func restartServer() {
        Theme.Haptics.tap()
        Task { [weak self] in
            guard let self else { return }
            guard
                let backend = (self.backend
                    ?? ConnectionController.shared.makeBackend(for: self.profile)),
                let restartable = backend as? any RestartableBackend
            else { return }
            do {
                try await restartable.restart()
                self.statusText = ServerRestart.underway
                self.applySnapshot()
            } catch {
                self.offerSetup(backend: backend)
            }
        }
    }

    /// A machine set up by hand refuses the restart, and the refusal is the offer: the setup that
    /// makes it restartable is one press, not a terminal instruction.
    private func offerSetup(backend: any CodingAgentBackend) {
        guard let settable = backend as? any ServeManagerBackend else {
            statusText = ServerRestart.refused(profile.name)
            applySnapshot()
            return
        }
        let alert = UIAlertController(
            title: ServerRestart.setupTitle,
            message: ServerRestart.setupDetail,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: ServerRestart.setupAction, style: .default) { [weak self] _ in
                self?.installSetup(settable)
            })
        present(alert, animated: true)
    }

    private func installSetup(_ settable: any ServeManagerBackend) {
        statusText = ServerRestart.setupUnderway
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await settable.installServeManager()
                self.statusText = ServerRestart.underway
            } catch {
                self.statusText = ServerRestart.setupFailedDetail
            }
            self.applySnapshot()
        }
    }

    private func confirmRemove() {
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
            UIAlertAction(title: String(localized: "Remove"), style: .destructive) {
                [weak self] _ in
            guard let self else { return }
            try? ConnectionController.shared.delete(profile.id)
            ServerHealthMonitor.forget(profile.id)
            Theme.Haptics.warning()
            navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
}

extension ServerDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .test:
            Theme.Haptics.tap()
            Task { await refresh() }
        case .restart:
            confirmRestart()
        case .makeDefault:
            makeDefault()
        case .edit:
            presentEditor()
        case .delegate:
            DelegateGate.open(from: self, profile: profile)
        case .capability(let id):
            guard let target = capabilities.target(for: id) else { break }
            Theme.Haptics.tap()
            if target.capability == SetupCapability.media {
                MediaSetupGate.present(endpoint: target.forgeEndpoint, focus: nil, from: self)
                break
            }
            SetupGate.present(target, from: self, reportLines: { [weak self] in self?.capabilityReport(for: target) ?? [] })
        case .previewHost:
            guard !isPreviewHostChosen else { break }
            choosePreviewHost()
        case .remove:
            confirmRemove()
        case .pushState:
            PushRegistrar.reregisterIfNeeded()
            Theme.Haptics.tap()
        case .updateCenter:
            Theme.Haptics.tap()
            UpdateCenterViewController.present(from: self)
        case .account(let signedIn):
            guard !signedIn else { break }
            presentSignIn()
        default:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1,
            case .value(_, let value) = dataSource.itemIdentifier(for: indexPaths[0])
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")
                ) {
                    _ in
                    UIPasteboard.general.string = value
                    Theme.Haptics.tap()
                }
            ])
        }
    }
}
