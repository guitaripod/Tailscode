import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The servers this machine knows, editable in place. Adding one probes it before saving — a typo
/// fails here, named, rather than becoming a row that never loads — and the failure names its
/// cause: the address didn't parse, the port didn't answer, the password was refused.
///
/// Keeping each server current is also this screen's job: every claude-bridge row carries a
/// Software line that reads `/update`, offers the update with the commits it would bring, and
/// follows it through the server's own restart. A bridge too old to have the route says so and
/// hands over the one-line install command instead.
final class ServerManager: @unchecked Sendable {
    static let installCommand = BridgeInstall.installCommand
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
                    "\(ServerLabel.agent(profile.backend)) · \(ServerLabel.address(profile))",
                    css: "row-detail", selectable: false))
            if profile.backend == .claudeCode {
                let software = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
                Gtk.margins(software, top: 4)
                gtk_box_append(ptr(lines), software)
                checkSoftware(profile, into: UInt(bitPattern: software))
            }
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
        var password = String(cString: passwordRaw)
        if password.isEmpty, let pasted = BridgeInstall.password(in: raw) {
            password = pasted
            gtk_editable_set_text(op(passwordEntry), pasted)
        }
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
        Task { [weak self] in
            let verdict = await ProbeSweep.best(
                address: address, password: password.isEmpty ? nil : password,
                preferring: backend)
            switch verdict.outcome {
            case .ok(let agent, let version):
                let profile = ConnectionProfile(
                    id: UUID().uuidString,
                    name: label.isEmpty ? address.displayHost : label,
                    backend: agent,
                    baseURL: verdict.url,
                    username: agent == .claudeCode ? "claude" : "opencode")
                do {
                    try await ServerDirectory.shared.save(
                        profile, password: password.isEmpty ? nil : password)
                    self?.onChanged()
                    Gtk.onMain { [weak self] in
                        self?.setStatus(
                            Localized.text(
                                "Saved %@ — %@", profile.name, version ?? "connected"))
                        self?.renderList()
                        gtk_editable_set_text(op(self!.addressEntry), "")
                    }
                } catch {
                    let text = Localized.text("Could not save: %@", String(describing: error))
                    Gtk.onMain { [weak self] in self?.setStatus(text) }
                }
            case .authFailed:
                let text = password.isEmpty
                    ? Localized.text(
                        "%@ answered and wants a password.", verdict.url.absoluteString)
                    : Localized.text(
                        "%@ answered but refused the password. Check it on the server.",
                        verdict.url.absoluteString)
                Gtk.onMain { [weak self] in self?.setStatus(text) }
            case .notAnAgentServer, .unreachable:
                let cause = await Self.diagnose(address: address, backend: backend)
                Gtk.onMain { [weak self] in self?.setStatus(cause) }
            }
        }
    }

    /// An unanswered `/update` has two very different causes, and only one deserves the install
    /// command: a bridge old enough to lack the route still answers `/health`, while a machine
    /// that answers neither is unreachable — telling someone to reinstall a server that is merely
    /// asleep would be worse than saying nothing.
    private func checkSoftware(_ profile: ConnectionProfile, into bits: UInt) {
        setSoftwareText(bits, Localized.text("Checking for updates…"))
        Task { [weak self] in
            guard
                let backend = await ServerDirectory.shared.backend(for: profile)
                    as? any SelfUpdatingBackend
            else { return }
            if let update = try? await backend.updateStatus(checkingRemote: true) {
                Gtk.onMain { [weak self] in
                    self?.renderSoftware(update, profile: profile, into: bits)
                }
            } else if (try? await backend.health()) != nil {
                Gtk.onMain { [weak self] in
                    self?.renderSoftware(nil, profile: profile, into: bits)
                }
            } else {
                Gtk.onMain { [weak self] in
                    self?.setSoftwareText(
                        bits,
                        Localized.text("Could not check for updates — the server is unreachable."))
                }
            }
        }
    }

    private func renderSoftware(_ update: ServerUpdate?, profile: ConnectionProfile, into bits: UInt) {
        guard let box = Self.widget(from: bits) else { return }
        Gtk.removeChildren(of: box)
        guard let update else {
            gtk_box_append(
                ptr(box),
                Gtk.label(
                    Localized.text(
                        "This bridge is too old to report its software. Update it by hand:"),
                    css: "row-detail", wrap: true, selectable: false))
            gtk_box_append(
                ptr(box),
                softwareButton(Localized.text("Copy the install command"), css: ["flat"]) {
                    Gtk.copyToClipboard(Self.installCommand)
                })
            return
        }
        if update.phase == .failed {
            let detail = update.reason ?? update.log.map { String($0.suffix(300)) } ?? ""
            gtk_box_append(
                ptr(box),
                Gtk.label(
                    Localized.text("The last update failed. %@", detail), css: "glyph-error",
                    wrap: true))
        }
        guard update.updateAvailable else {
            gtk_box_append(
                ptr(box),
                Gtk.label(
                    Localized.text("%@ · up to date", update.version), css: "row-detail",
                    selectable: false))
            return
        }
        let target = update.latestVersion
            ?? update.latestCommit.map { String($0.prefix(7)) }
            ?? Localized.text("latest")
        var headline = "\(update.version) → \(target)"
        if let behind = update.behind, behind > 0 {
            headline += " · " + Localized.text("%@ commits behind", "\(behind)")
        }
        gtk_box_append(ptr(box), Gtk.label(headline, css: "row-title", selectable: false))
        for change in update.changes.prefix(5) {
            gtk_box_append(
                ptr(box), Gtk.label("· \(change)", css: "row-detail", wrap: true, selectable: false))
        }
        if update.canUpdate {
            gtk_box_append(
                ptr(box),
                softwareButton(Localized.text("Update the server"), css: ["suggested-action"]) {
                    [weak self] in
                    Gtk.onMain { [weak self] in self?.runUpdate(profile, into: bits) }
                })
        } else if let reason = update.reason {
            gtk_box_append(ptr(box), Gtk.label(reason, css: "row-detail", wrap: true, selectable: false))
        }
    }

    /// The update is followed to the end, not to the first heartbeat: the old process keeps
    /// answering `/health` through the whole fetch and build, so the loop watches the update's own
    /// phase and treats a refused connection as the restart doing its job. Only a settled phase —
    /// or ten minutes of silence — ends it.
    private func runUpdate(_ profile: ConnectionProfile, into bits: UInt) {
        setSoftwareText(bits, Localized.text("Updating — asking the server to fetch and build…"))
        Task { [weak self] in
            guard
                let backend = await ServerDirectory.shared.backend(for: profile)
                    as? any SelfUpdatingBackend
            else { return }
            _ = try? await backend.startUpdate()
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                guard let update = try? await backend.updateStatus(checkingRemote: false) else {
                    Gtk.onMain { [weak self] in
                        self?.setSoftwareText(
                            bits,
                            Localized.text("Updating — the server is restarting…"))
                    }
                    continue
                }
                if update.isRunning {
                    let phase =
                        update.phase == .building
                        ? Localized.text("Updating — building…")
                        : update.phase == .restarting
                            ? Localized.text("Updating — restarting…")
                            : Localized.text("Updating — fetching…")
                    Gtk.onMain { [weak self] in self?.setSoftwareText(bits, phase) }
                    continue
                }
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.renderSoftware(update, profile: profile, into: bits)
                    self.setStatus(
                        Localized.text("%@ is back — %@", profile.name, update.version))
                }
                return
            }
            Gtk.onMain { [weak self] in
                self?.setSoftwareText(
                    bits,
                    Localized.text(
                        "The update did not settle within ten minutes — check the server over ssh."))
            }
        }
    }

    private func setSoftwareText(_ bits: UInt, _ text: String) {
        guard let box = Self.widget(from: bits) else { return }
        Gtk.removeChildren(of: box)
        gtk_box_append(ptr(box), Gtk.label(text, css: "row-detail", wrap: true, selectable: false))
    }

    private func softwareButton(
        _ title: String, css: [String], onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(title, css: css, onClick: onClick)
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        return button
    }

    private static func widget(from bits: UInt) -> UnsafeMutablePointer<GtkWidget>? {
        UnsafeMutableRawPointer(bitPattern: bits).map { ptr($0) }
    }

    /// A failed probe names its cause rather than surfacing a raw error: the port not answering,
    /// the host not resolving, or something on the port that is not an agent.
    private static func diagnose(address: HostAddress, backend: AgentType) async -> String {
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
