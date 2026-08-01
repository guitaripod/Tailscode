import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The servers this machine knows, editable in place. Adding one probes it before saving — a typo
/// fails here, named, rather than becoming a row that never loads — and the failure names its
/// cause: the address didn't parse, the port didn't answer, the password was refused.
final class ServerManager: @unchecked Sendable {
    private var window: UnsafeMutablePointer<GtkWidget>?
    private let listBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private let statusLabel = Gtk.label("", css: "row-detail", wrap: true, selectable: false)
    private let nameEntry = gtk_entry_new()!
    private let addressEntry = gtk_entry_new()!
    private let passwordEntry = gtk_password_entry_new()!
    private var useOpenCode = false
    private let onChanged: @Sendable () -> Void

    init(onChanged: @escaping @Sendable () -> Void) {
        self.onChanged = onChanged
    }

    func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Servers"), parent: parent, width: 560)
        self.window = window

        gtk_box_append(
            ptr(content),
            Gtk.label(Localized.text("CONFIGURED"), css: "section-header", selectable: false))
        gtk_box_append(ptr(content), listBox)

        gtk_box_append(
            ptr(content),
            Gtk.label(Localized.text("ADD A SERVER"), css: "section-header", selectable: false))
        gtk_entry_set_placeholder_text(
            ptr(addressEntry),
            Localized.text("Tailnet address — 100.x.y.z, name.tailnet.ts.net, host:port"))
        gtk_box_append(ptr(content), addressEntry)
        gtk_entry_set_placeholder_text(ptr(nameEntry), Localized.text("Label (optional)"))
        gtk_box_append(ptr(content), nameEntry)
        gtk_box_append(ptr(content), passwordEntry)

        let kindRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let claudeButton = gtk_toggle_button_new_with_label("claude-bridge · 4098")!
        let opencodeButton = gtk_toggle_button_new_with_label("opencode · 4096")!
        gtk_toggle_button_set_active(ptr(claudeButton), 1)
        gtk_toggle_button_set_group(ptr(opencodeButton), ptr(claudeButton))
        let claudeBits = UInt(bitPattern: claudeButton)
        Gtk.connect(UnsafeMutableRawPointer(claudeButton), "toggled") { [weak self] in
            guard let self, let raw = UnsafeMutableRawPointer(bitPattern: claudeBits) else {
                return
            }
            let button: UnsafeMutablePointer<GtkToggleButton> = ptr(raw)
            self.useOpenCode = gtk_toggle_button_get_active(button) == 0
        }
        gtk_box_append(ptr(kindRow), claudeButton)
        gtk_box_append(ptr(kindRow), opencodeButton)
        gtk_box_append(ptr(content), kindRow)

        gtk_box_append(ptr(content), statusLabel)
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        gtk_box_append(
            ptr(actions),
            Gtk.button(Localized.text("Close")) { [weak self] in
                if let window = self?.window { gtk_window_destroy(ptr(window)) }
            })
        gtk_box_append(
            ptr(actions),
            Gtk.button(Localized.text("Probe and save"), css: ["suggested-action"]) { [weak self] in
                self?.probeAndSave()
            })
        gtk_box_append(ptr(content), actions)

        renderList()
        gtk_window_present(ptr(window))
    }

    private func renderList() {
        Gtk.removeChildren(of: listBox)
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            Gtk.onMain { [weak self] in self?.renderProfiles(profiles) }
        }
    }

    private func renderProfiles(_ profiles: [ConnectionProfile]) {
        Gtk.removeChildren(of: listBox)
        guard !profiles.isEmpty else {
            gtk_box_append(
                ptr(listBox),
                Gtk.label(Localized.text("No servers yet."), css: "dim", selectable: false))
            return
        }
        for profile in profiles {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_box_append(ptr(lines), Gtk.label(profile.name, css: "row-title", selectable: false))
            gtk_box_append(
                ptr(lines),
                Gtk.label(
                    "\(profile.backend == .openCode ? "opencode" : "claude") · \(profile.baseURL.absoluteString)",
                    css: "row-detail", selectable: false))
            gtk_widget_set_hexpand(lines, 1)
            gtk_box_append(ptr(row), lines)
            let id = profile.id
            let name = profile.name
            gtk_box_append(
                ptr(row),
                Gtk.button(Localized.text("Remove"), css: ["destructive-action", "flat"]) {
                    [weak self] in
                    guard let self else { return }
                    Dialogs.confirm(
                        title: Localized.text("Remove %@?", name),
                        body: Localized.text(
                            "The saved address and password go away. Conversations stay on the server."),
                        confirmLabel: Localized.text("Remove"), parent: self.listBox
                    ) { [weak self] in
                        Task { [weak self] in
                            await ServerDirectory.shared.delete(id: id)
                            self?.onChanged()
                            Gtk.onMain { [weak self] in self?.renderList() }
                        }
                    }
                })
            gtk_box_append(ptr(listBox), row)
        }
    }

    private func probeAndSave() {
        let raw = Dialogs.entryText(addressEntry)
        let label = Dialogs.entryText(nameEntry)
        guard let passwordRaw = gtk_editable_get_text(op(passwordEntry)) else { return }
        let password = String(cString: passwordRaw)
        let backend: AgentType = useOpenCode ? .openCode : .claudeCode

        guard !raw.isEmpty else {
            setStatus(Localized.text("Type the server's tailnet address first."))
            return
        }
        guard
            case .address(let address) = HostAddress.read(
                raw, defaultPort: HostAddress.port(for: backend))
        else {
            setStatus(Localized.text("“%@” does not read as an address.", raw))
            return
        }

        setStatus(Localized.text("Probing %@…", address.url.absoluteString))
        let profile = ConnectionProfile(
            id: UUID().uuidString,
            name: label.isEmpty ? address.displayHost : label,
            backend: backend,
            baseURL: address.url,
            username: backend == .claudeCode ? "claude" : "opencode")

        Task { [weak self] in
            let candidate = profile.makeBackend(password: password.isEmpty ? nil : password)
            do {
                let health = try await candidate.health()
                try await ServerDirectory.shared.save(
                    profile, password: password.isEmpty ? nil : password)
                self?.onChanged()
                Gtk.onMain { [weak self] in
                    self?.setStatus(
                        Localized.text(
                            "Saved %@ — %@", profile.name, health.version ?? "connected"))
                    self?.renderList()
                    gtk_editable_set_text(op(self!.addressEntry), "")
                }
            } catch {
                let cause = await Self.diagnose(
                    address: address, backend: backend, error: error)
                Gtk.onMain { [weak self] in self?.setStatus(cause) }
            }
        }
    }

    /// A failed probe names its cause rather than surfacing a raw error: the port not answering,
    /// the host not resolving, or the server answering and refusing the password.
    private static func diagnose(
        address: HostAddress, backend: AgentType, error: Error
    ) async -> String {
        let described = String(describing: error)
        if described.contains("401") || described.lowercased().contains("unauthorized") {
            return Localized.text(
                "%@ answered but refused the password. Check it on the server.",
                address.displayHost)
        }
        guard let host = address.url.host, let port = address.url.port else {
            return Localized.text("Could not reach %@.", address.url.absoluteString)
        }
        switch await PortReachability.check(host: host, port: UInt16(port)) {
        case .listening:
            return Localized.text(
                "%@:%@ answers, but not like a %@ server — is the other agent on this port?",
                host, "\(port)", backend == .openCode ? "opencode" : "claude-bridge")
        case .refused:
            return Localized.text(
                "%@ is up but nothing listens on %@ — is the server running?", host, "\(port)")
        case .timedOut:
            return Localized.text(
                "%@ did not answer — check Tailscale on both machines.", host)
        case .nameNotResolved:
            return Localized.text(
                "“%@” does not resolve — is MagicDNS on, or use the 100.x address.", host)
        }
    }

    private func setStatus(_ text: String) {
        gtk_label_set_text(op(statusLabel), text)
    }
}
