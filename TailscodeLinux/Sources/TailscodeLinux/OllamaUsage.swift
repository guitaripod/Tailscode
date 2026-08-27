import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import TailscodeCore

/// An Ollama Cloud account's API key, optional and held in the platform's secret store — the
/// same 0600 file that holds server passwords. With a key the account's session and weekly
/// windows join the usage surfaces; without one nothing changes.
enum OllamaCredentials {
    private static let apiKey = "ollamaCloud.apiKey"
    private static let store = FileSecretStore()

    static var token: String? {
        let stored = (try? store.value(for: apiKey)) ?? nil
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static var hasToken: Bool { token != nil }

    static func setToken(_ value: String) throws {
        try store.setValue(value, for: apiKey)
        OllamaCloud.forgetLastFetch()
        NotificationCenter.default.post(name: OllamaUsage.didChange, object: nil)
    }

    static func clearToken() {
        try? store.removeValue(for: apiKey)
        OllamaCloud.forgetLastFetch()
        NotificationCenter.default.post(name: OllamaUsage.didChange, object: nil)
    }
}

/// Reads the Ollama Cloud account's session and weekly windows straight from ollama.com. No key
/// returns nil — no card rather than an error, so the surface stays exactly what it was.
/// Best-effort by design: every caller may lose the race to a dead network and keeps whatever it
/// already had, and a throttle keeps the poll and the panel from hammering the endpoint.
enum OllamaUsage {
    static let providerName = OllamaCloud.providerName
    /// Posted when the key is set or removed, so a surface drawn from the last reading drops or
    /// gains the account at once rather than at the next poll.
    static let didChange = Notification.Name("tailscode.linux.ollama.didChange")

    /// The servers' reports with this machine's own reading folded in. The windows are nobody's
    /// server's to report — they are read here, from the key this machine holds — so they join
    /// the account where the account is drawn, and ``QuotaRollup`` folds them beside the plans
    /// like any other provider.
    static func folded(into quotas: [(String, UsageQuota)]) async -> [(String, UsageQuota)] {
        guard let reading = await refresh() else { return quotas }
        return quotas + [("", OllamaCloud.snapshot(for: reading))]
    }

    @discardableResult
    static func refresh() async -> OllamaCloud.Reading? {
        await OllamaCloud.refresh(key: OllamaCredentials.token)
    }
}

/// The one editor for the optional Ollama Cloud API key. Purely additive: without a key the
/// usage surfaces stay exactly as they were, and with one the plan's windows join the meters
/// and the chooser's ollama-cloud rows learn their own wall. Saving an empty field is how a key
/// is removed, so the state and the gesture that ends it never disagree.
enum OllamaKeyDialog {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?,
        onChanged: @escaping @Sendable () -> Void
    ) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Ollama Cloud API key"), parent: parent, width: 420)
        gtk_box_append(
            ptr(content),
            Gtk.label(
                Localized.text(
                    "Ollama models served by ollama.com are metered by your plan — a session window and a weekly one. Paste the account's API key here and the plan's windows join the usage meters. Models on your own ollama server are unlimited and never wear this."),
                css: "row-detail", wrap: true, selectable: false))

        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(entry), "sk-...")
        gtk_entry_set_visibility(ptr(entry), 0)
        gtk_editable_set_text(op(entry), OllamaCredentials.token ?? "")
        gtk_box_append(ptr(content), entry)

        gtk_box_append(
            ptr(content),
            Gtk.label(
                Localized.text(
                    "Stored only in the app's secret store, on this machine. Read once per refresh from ollama.com — the key never touches your servers."),
                css: "row-detail", wrap: true, selectable: false))

        let entryBits = UInt(bitPattern: entry)
        let windowBits = UInt(bitPattern: window)
        let finish: @Sendable () -> Void = {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
            onChanged()
        }
        let save: @Sendable () -> Void = {
            guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
            let text = Dialogs.entryText(ptr(raw))
            if text.isEmpty {
                OllamaCredentials.clearToken()
            } else {
                try? OllamaCredentials.setToken(text)
            }
            finish()
        }
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate", save)

        let remove = Gtk.button(Localized.text("Remove key"), css: ["destructive-action"]) {
            OllamaCredentials.clearToken()
            finish()
        }
        gtk_widget_set_visible(remove, OllamaCredentials.hasToken ? 1 : 0)

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        gtk_box_append(ptr(buttons), remove)
        gtk_box_append(
            ptr(buttons),
            Gtk.button(Localized.text("Save"), css: ["suggested-action"], onClick: save))
        gtk_box_append(ptr(content), buttons)
        gtk_window_present(ptr(window))
    }
}