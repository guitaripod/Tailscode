import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UserNotifications

extension PreferencesWindow {
    #if !TAILSCODE_MAS
        /// The two video accounts, drawn and redrawn in place. Signing in or out rewrites everything a
        /// row says while the window stands open, and the content is only made again at the next
        /// presentation — so the section empties and refills itself in place instead. The width
        /// constraint `scrolled(_:)` applies runs exactly once, over the column's own children, and
        /// never sees a row made later: each one is given the same constraint as it is made.
        func renderWatchAccounts() {
            for view in watchAccounts.arrangedSubviews { view.removeFromSuperview() }
            for row in WatchAccounts.rows() {
                let button = NSButton(
                    title: row.actionTitle, target: self, action: #selector(watchAccountPressed))
                button.identifier = NSUserInterfaceItemIdentifier(row.id)
                let view = buttonRow(title: row.title, subtitle: row.detail, button: button)
                watchAccounts.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: watchAccounts.widthAnchor).isActive = true
                guard let note = row.note else { continue }
                let caption = MacDialogs.detailLabel(note, wraps: true)
                watchAccounts.addArrangedSubview(caption)
                caption.widthAnchor.constraint(equalTo: watchAccounts.widthAnchor).isActive = true
            }
        }
    #endif

    /// The optional DeepSeek key, stated as the fact it is: set, or not. The row is drawn again in
    /// place after the editor closes, because whether a key exists is exactly what the editor
    /// changes and the content is otherwise only made at the next presentation.
    func renderDeepSeek() {
        for view in deepseekRow.arrangedSubviews { view.removeFromSuperview() }
        let button = NSButton(
            title: Localized.text("Edit"), target: self, action: #selector(editDeepSeekKey))
        let view = buttonRow(
            title: Localized.text("DeepSeek API key"),
            subtitle: DeepSeekCredentials.hasToken
                ? Localized.text("Saved in this Mac's Keychain")
                : Localized.text("Not set"),
            button: button)
        deepseekRow.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: deepseekRow.widthAnchor).isActive = true
    }

    @objc private func editDeepSeekKey() {
        DeepSeekKeySheet.present(on: window) { [weak self] in
            self?.renderDeepSeek()
        }
    }

    /// The optional Ollama Cloud key, stated as the fact it is: set, or not. The row is drawn
    /// again in place after the editor closes, because whether a key exists is exactly what the
    /// editor changes and the content is otherwise only made at the next presentation.
    func renderOllama() {
        for view in ollamaRow.arrangedSubviews { view.removeFromSuperview() }
        let button = NSButton(
            title: Localized.text("Edit"), target: self, action: #selector(editOllamaKey))
        let view = buttonRow(
            title: Localized.text("Ollama Cloud API key"),
            subtitle: OllamaCredentials.hasToken
                ? Localized.text("Saved in this Mac's Keychain")
                : Localized.text("Not set"),
            button: button)
        ollamaRow.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: ollamaRow.widthAnchor).isActive = true
    }

    @objc private func editOllamaKey() {
        OllamaKeySheet.present(on: window) { [weak self] in
            self?.renderOllama()
        }
    }

    #if !TAILSCODE_MAS
        /// The row is read again at the moment it is pressed rather than captured when it was drawn:
        /// an account can land or expire while the window sits open, and the button must mean what the
        /// row says now.
        @objc private func watchAccountPressed(_ sender: NSButton) {
            guard let id = sender.identifier?.rawValue,
                let row = WatchAccounts.rows().first(where: { $0.id == id })
            else { return }
            switch row.action {
            case .signIn(let source):
                guard let window else { return }
                WatchSignInSheet.present(on: window, source: source) { [weak self] in
                    self?.renderWatchAccounts()
                }
            case .signOut(let source):
                MediaAccounts.signOut(source)
                renderWatchAccounts()
            case .configure:
                explainWatchAccount(row)
            }
        }

        /// The one step of this feature that happens somewhere else. Google will only run its device
        /// flow for an application registered to somebody, so the alert states why, links the console,
        /// and takes the client id and secret right there — a requirement explained but not actionable
        /// is a dead end wearing a button.
        private func explainWatchAccount(_ row: WatchAccountRow) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = YouTubeSetup.heading
            alert.informativeText =
                ([YouTubeSetup.why] + YouTubeSetup.steps.enumerated().map { "\($0.offset + 1). \($0.element)" })
                .joined(separator: "\n\n")

            let current = MediaClientConfig.youtube
            let identity = NSTextField(string: current?.id ?? "")
            identity.placeholderString = YouTubeSetup.idPrompt
            identity.font = MacTheme.Ramp.font(.toolOutput)
            let secret = NSSecureTextField(string: current?.secret ?? "")
            secret.placeholderString = YouTubeSetup.secretPrompt
            secret.font = MacTheme.Ramp.font(.toolOutput)
            let fields = NSStackView(views: [identity, secret])
            fields.orientation = .vertical
            fields.alignment = .leading
            fields.spacing = MacTheme.Spacing.xs
            fields.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
            identity.widthAnchor.constraint(equalToConstant: 320).isActive = true
            secret.widthAnchor.constraint(equalToConstant: 320).isActive = true
            alert.accessoryView = fields
            alert.window.initialFirstResponder = identity

            alert.addButton(withTitle: Localized.text("Save"))
            alert.addButton(withTitle: Localized.text("Open the console"))
            alert.addButton(withTitle: Localized.text("Close"))
            let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:
                    let typedID = identity.stringValue
                    let typedSecret = secret.stringValue
                    guard YouTubeSetup.looksValid(id: typedID, secret: typedSecret) else {
                        self?.rejectWatchClient()
                        return
                    }
                    MediaClientConfig.setYouTube(id: typedID, secret: typedSecret)
                    self?.renderWatchAccounts()
                case .alertSecondButtonReturn:
                    if let url = URL(string: YouTubeSetup.consoleURL) {
                        NSWorkspace.shared.open(url)
                    }
                default:
                    return
                }
            }
            guard let window else {
                finish(alert.runModal())
                return
            }
            alert.beginSheetModal(for: window, completionHandler: finish)
        }

        /// A pasted mistake is caught here rather than at the end of a sign-in that would fail for a
        /// reason nobody could connect back to this box.
        private func rejectWatchClient() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = YouTubeSetup.rejection
            alert.addButton(withTitle: Localized.text("Close"))
            guard let window else {
                alert.runModal()
                return
            }
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    #endif
}
