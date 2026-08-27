import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// An Ollama Cloud account's API key, optional and held in the same Keychain the connection
/// profiles do — one service, one account name, the ones the phone and the desktop already
/// agreed on — so the machine that bills Ollama Cloud is the machine that reads the windows.
enum OllamaCredentials {
    private static let apiKey = "ollamaCloud.apiKey"
    private static let keychain = KeychainSecretStore()

    static var token: String? {
        let stored = (try? keychain.value(for: apiKey)) ?? nil
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static var hasToken: Bool { token != nil }

    @MainActor
    static func setToken(_ value: String) throws {
        try keychain.setValue(value, for: apiKey)
        OllamaCloud.forgetLastFetch()
        NotificationCenter.default.post(name: OllamaUsage.didChange, object: nil)
    }

    @MainActor
    static func clearToken() {
        try? keychain.removeValue(for: apiKey)
        OllamaCloud.forgetLastFetch()
        NotificationCenter.default.post(name: OllamaUsage.didChange, object: nil)
    }
}

/// Reads the Ollama Cloud account's session and weekly windows straight from ollama.com. No key
/// returns nil — no card rather than an error, so the surface stays exactly what it was.
/// Best-effort by design: every caller may lose the race to a dead network and keeps whatever it
/// already had, and a throttle keeps the sidebar's poll and the panel's refresh from hammering
/// the endpoint.
@MainActor
enum OllamaUsage {
    static let providerName = OllamaCloud.providerName
    /// Posted when the key is set or removed, so a surface drawn from the last reading drops or
    /// gains the account at once rather than at the next poll.
    static let didChange = Notification.Name("tailscode.mac.ollama.didChange")

    private static var lastReading: OllamaCloud.Reading?

    static var cached: OllamaCloud.Reading? { lastReading }

    /// The key is read off the main actor because a Keychain that has no session to answer in —
    /// the build loop reaches this Mac over ssh — can take as long as it likes, and a poll that
    /// is nobody's idea of urgent must never be what stops the window redrawing.
    @discardableResult
    static func refresh() async -> OllamaCloud.Reading? {
        let key = await Task.detached(operation: { OllamaCredentials.token }).value
        let reading = await OllamaCloud.refresh(key: key)
        if let reading { lastReading = reading }
        return reading ?? lastReading
    }

    /// The servers' reports with this machine's own reading folded in. The windows are nobody's
    /// server's to report — they are read here, from the key this Mac holds — so they join the
    /// account where the account is drawn, and ``QuotaRollup`` folds them beside the plans like
    /// any other provider.
    static func folded(into reports: [(String, UsageQuota)]) -> [(String, UsageQuota)] {
        guard let lastReading else { return reports }
        return reports + [("", OllamaCloud.snapshot(for: lastReading))]
    }
}

/// The one editor for the optional Ollama Cloud API key, reached from Settings and from the
/// usage card's own empty state. Purely additive: without a key the usage surfaces stay exactly
/// as they were, and with one the plan's windows join the meters. Saving an empty field is how
/// a key is removed, so the state and the gesture that ends it never disagree.
@MainActor
enum OllamaKeySheet {
    private static let keysURL = URL(string: "https://ollama.com/settings/keys")!

    static func present(on window: NSWindow?, onChange: @escaping @MainActor () -> Void) {
        let hadKey = OllamaCredentials.hasToken
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Localized.text("Ollama Cloud API key")
        alert.informativeText = [
            Localized.text(
                "Ollama models served by ollama.com are metered by your plan — a session window and a weekly one. Paste the account's API key here and the plan's windows join the usage meters. Models on your own ollama server are unlimited and never wear this."),
            Localized.text(
                "Stored only in this Mac's Keychain. Read once per refresh from ollama.com — the key never touches your servers."),
        ].joined(separator: "\n\n")

        let field = NSSecureTextField(string: OllamaCredentials.token ?? "")
        field.placeholderString = "sk-..."
        field.font = MacTheme.Ramp.font(.toolOutput)
        let link = RowKit.linkButton(
            Localized.text("Open ollama.com/settings/keys to get a key")
        ) {
            NSWorkspace.shared.open(keysURL)
        }
        let accessory = NSStackView(views: [field, link])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = MacTheme.Spacing.xs
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        alert.addButton(withTitle: Localized.text("Save"))
        if hadKey { alert.addButton(withTitle: Localized.text("Remove key")) }
        alert.addButton(withTitle: Localized.text("Cancel"))

        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                save(field.stringValue, on: window, onChange: onChange)
            case .alertSecondButtonReturn where hadKey:
                OllamaCredentials.clearToken()
                onChange()
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

    private static func save(
        _ typed: String, on window: NSWindow?, onChange: @escaping @MainActor () -> Void
    ) {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            OllamaCredentials.clearToken()
            onChange()
            return
        }
        do {
            try OllamaCredentials.setToken(key)
            onChange()
        } catch {
            refuse(error, on: window)
        }
    }

    /// A Keychain that refuses the write is the one failure this box can have, and it is said out
    /// loud — a key that looks saved and is not would show up minutes later as a balance that
    /// never arrives. The second sheet waits a turn because the first one is still leaving.
    private static func refuse(_ error: any Error, on window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Localized.text("The Keychain refused the key")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: Localized.text("Close"))
        guard let window else {
            alert.runModal()
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}