import TailscodeCore
import UIKit

extension ServerDetailViewController {
    @objc func previewHostsChanged() { reconfigure([.previewHost]) }

    private var previewAccess: PreviewAccess? {
        profile.baseURL.host.map { PreviewAccessStore.access(host: $0) ?? PreviewAccess(host: $0) }
    }

    private var previewPassword: String? {
        previewAccess.flatMap { (try? previewSecrets.value(for: $0.secretKey)) ?? nil }
    }

    /// Asks the machine once whether a preview host answers on it, off the main thread. A server
    /// with none shows nothing at all, never an error, because most servers will never have one.
    func checkPreviewHost() {
        guard !isDemo, let access = previewAccess else { return }
        let password = previewPassword
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let found = await PreviewProbe.probe(access, password: password)
            guard !Task.isCancelled else { return }
            self?.settlePreview(found)
        }
    }

    private func settlePreview(_ found: PreviewReach) {
        previewReach = found
        AppLogger.connection.info("preview host on \(profile.baseURL.host ?? "?"): \(String(describing: found))")
        applySnapshot()
        reconfigure([.previewHost])
    }

    var isShowingPreviewHost: Bool {
        previewReach.isAnswering || previewReach.asksForPassword
    }

    var isPreviewHostChosen: Bool {
        guard let host = previewAccess?.host else { return false }
        return PreviewAccessStore.access(host: host) != nil && previewReach.isAnswering
    }

    /// Remembers this machine's preview host for the chats that run on it. A host that asks for a
    /// password is asked for it here, once, and the password is kept with the delegate's.
    func choosePreviewHost() {
        guard let access = previewAccess else { return }
        Theme.Haptics.tap()
        if previewReach.asksForPassword, previewPassword == nil {
            askPreviewPassword(for: access)
            return
        }
        adoptPreviewHost(access, password: previewPassword, typed: nil)
    }

    private func askPreviewPassword(for access: PreviewAccess) {
        let alert = UIAlertController(
            title: Localized.text("Preview host"), message: previewReach.line, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = Localized.text("Password")
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: Localized.text("Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: Localized.text("Use for previews"), style: .default) { [weak self, weak alert] _ in
                let typed = alert?.textFields?.first?.text ?? ""
                guard !typed.isEmpty else { return }
                self?.adoptPreviewHost(access, password: typed, typed: typed)
            })
        present(alert, animated: true)
    }

    private func adoptPreviewHost(_ access: PreviewAccess, password: String?, typed: String?) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let found = await PreviewProbe.probe(access, password: password)
            guard !Task.isCancelled, let self else { return }
            if found.isAnswering {
                PreviewAccessStore.remember(access)
                if let typed { try? self.previewSecrets.setValue(typed, for: access.secretKey) }
                Theme.Haptics.success()
            } else {
                Theme.Haptics.warning()
            }
            self.settlePreview(found)
        }
    }
}
