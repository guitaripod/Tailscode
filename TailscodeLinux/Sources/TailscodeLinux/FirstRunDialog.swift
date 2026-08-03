import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// First run is a checklist the app verifies, not a form: it states each requirement and proves
/// what it can — this machine's tailnet presence, polled live, and which agent answers the typed
/// address via the full `probeCandidates()` sweep — before asking for anything. A failed probe
/// names its cause; a password is asked for only once a server says it wants one. Shown only
/// when no server is configured yet.
final class FirstRunDialog: @unchecked Sendable {
    static func presentIfNeeded(
        parent: UnsafeMutablePointer<GtkWidget>?, onSaved: @escaping @Sendable () -> Void
    ) {
        let parentBits = parent.map { UInt(bitPattern: $0) } ?? 0
        Task {
            await ServerDirectory.shared.reload()
            guard await ServerDirectory.shared.profiles().isEmpty else { return }
            Gtk.onMain {
                let parent = UnsafeMutableRawPointer(bitPattern: parentBits).map {
                    raw -> UnsafeMutablePointer<GtkWidget> in ptr(raw)
                }
                FirstRunDialog(onSaved: onSaved).present(parent: parent)
            }
        }
    }

    private let onSaved: @Sendable () -> Void
    private var window: UnsafeMutablePointer<GtkWidget>?
    private let tailnetPill = Gtk.label("", css: "row-detail", selectable: false)
    private let agentPill = Gtk.label("", css: "row-detail", selectable: false)
    private let addressEntry = gtk_entry_new()!
    private let passwordEntry = gtk_password_entry_new()!
    private let readingLabel = Gtk.label("", css: "row-detail", selectable: false)
    private let diagnosisLabel = Gtk.label("", css: "row-detail", wrap: true, selectable: false)
    private let connectButton = gtk_button_new_with_label("")!
    private var useOpenCode = false
    private var passwordShown = false
    private var tailnetAddress: String?
    private var closed = false
    private var probeGeneration = 0
    private var verified: (url: URL, agent: AgentType, version: String?)?

    private init(onSaved: @escaping @Sendable () -> Void) {
        self.onSaved = onSaved
    }

    private func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Welcome"), parent: parent, width: 620)
        self.window = window

        gtk_box_append(
            ptr(content),
            Gtk.label(
                Localized.text(
                    "Tailscode drives coding agents on your other machines. Two things have to be true first — both are checked for you."),
                css: "row-detail", wrap: true, selectable: false))

        appendStep(
            to: content, number: "1", title: Localized.text("Tailscale on this machine"),
            pill: tailnetPill)
        setPill(tailnetPill, text: Localized.text("Checking…"), css: "dim")

        appendStep(
            to: content, number: "2",
            title: Localized.text("Run an agent on the machine with your code"),
            pill: agentPill)
        appendCommand(
            to: content, label: "claude-bridge", command: ServerManager.installCommand)
        appendCommand(
            to: content, label: "opencode",
            command: "opencode serve --hostname 0.0.0.0 --port 4096")

        appendStep(to: content, number: "3", title: Localized.text("Connect this machine"), pill: nil)
        gtk_entry_set_placeholder_text(
            ptr(addressEntry),
            Localized.text("Tailnet address — 100.x.y.z, name.tailnet.ts.net, host:port"))
        gtk_box_append(ptr(content), addressEntry)

        let kindRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let claudeButton = gtk_toggle_button_new_with_label("claude-bridge · 4098")!
        let opencodeButton = gtk_toggle_button_new_with_label("opencode · 4096")!
        gtk_toggle_button_set_active(ptr(claudeButton), 1)
        gtk_toggle_button_set_group(ptr(opencodeButton), ptr(claudeButton))
        let claudeBits = UInt(bitPattern: claudeButton)
        Gtk.connect(UnsafeMutableRawPointer(claudeButton), "toggled") { [self] in
            guard let raw = UnsafeMutableRawPointer(bitPattern: claudeBits) else { return }
            let button: UnsafeMutablePointer<GtkToggleButton> = ptr(raw)
            useOpenCode = gtk_toggle_button_get_active(button) == 0
            Gtk.onMain { [self] in scheduleProbe(afterMilliseconds: 100) }
        }
        gtk_box_append(ptr(kindRow), claudeButton)
        gtk_box_append(ptr(kindRow), opencodeButton)
        gtk_box_append(ptr(content), kindRow)

        gtk_box_append(ptr(content), readingLabel)
        gtk_widget_set_visible(passwordEntry, 0)
        gtk_box_append(ptr(content), passwordEntry)
        gtk_box_append(ptr(content), diagnosisLabel)

        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        gtk_box_append(
            ptr(actions),
            Gtk.button(Localized.text("Later")) { [self] in
                Gtk.onMain { [self] in
                    if let window = self.window { Dialogs.close(window) }
                }
            })
        gtk_button_set_label(ptr(connectButton), Localized.text("Connect"))
        Gtk.addClass(connectButton, "suggested-action")
        Gtk.connect(UnsafeMutableRawPointer(connectButton), "clicked") { [self] in
            Gtk.onMain { [self] in probe(userInitiated: true) }
        }
        gtk_box_append(ptr(actions), connectButton)
        gtk_box_append(ptr(content), actions)

        Gtk.connect(UnsafeMutableRawPointer(addressEntry), "changed") { [self] in
            Gtk.onMain { [self] in
                verified = nil
                updateReading()
                scheduleProbe(afterMilliseconds: 900)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [self] in
            Gtk.onMain { [self] in closed = true }
        }

        pollTailnet()
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(addressEntry)
    }

    private func appendStep(
        to content: UnsafeMutablePointer<GtkWidget>, number: String, title: String,
        pill: UnsafeMutablePointer<GtkWidget>?
    ) {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 8)
        gtk_box_append(ptr(row), Gtk.label("\(number) ·", css: "dim", selectable: false))
        gtk_box_append(ptr(row), Gtk.label(title, css: "row-title", selectable: false))
        if let pill {
            let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_hexpand(spacer, 1)
            gtk_box_append(ptr(row), spacer)
            gtk_box_append(ptr(row), pill)
        }
        gtk_box_append(ptr(content), row)
    }

    private func appendCommand(
        to content: UnsafeMutablePointer<GtkWidget>, label: String, command: String
    ) {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, leading: 22)
        let text = Gtk.label(command, css: "tool-line", selectable: true)
        gtk_label_set_ellipsize(op(text), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(text, 1)
        gtk_box_append(ptr(row), Gtk.label(label, css: "row-detail", selectable: false))
        gtk_box_append(ptr(row), text)
        gtk_box_append(
            ptr(row),
            Gtk.button(Localized.text("Copy"), css: ["flat"]) {
                Gtk.copyToClipboard(command)
            })
        gtk_box_append(ptr(content), row)
    }

    private func setPill(_ label: UnsafeMutablePointer<GtkWidget>, text: String, css: String) {
        gtk_label_set_text(op(label), text)
        for name in ["dim", "glyph-running", "glyph-error", "glyph-pending"] {
            gtk_widget_remove_css_class(label, name)
        }
        Gtk.addClass(label, css)
    }

    /// This machine's tailnet presence, re-proved every few seconds while the window is open —
    /// someone starting Tailscale mid-setup watches the step go green by itself.
    private func pollTailnet() {
        Task.detached { [self] in
            while !closed {
                let status = TailnetStatusLinux.read()
                let address = status.address
                Gtk.onMain { [self] in
                    guard !closed else { return }
                    tailnetAddress = address
                    if let address {
                        setPill(tailnetPill, text: address, css: "glyph-running")
                    } else {
                        setPill(
                            tailnetPill,
                            text: Localized.text("Not connected — run `tailscale up`"),
                            css: "glyph-error")
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func updateReading() {
        let raw = Dialogs.entryText(addressEntry)
        guard !raw.isEmpty else {
            gtk_label_set_text(op(readingLabel), "")
            return
        }
        let backend: AgentType = useOpenCode ? .openCode : .claudeCode
        switch HostAddress.read(raw, defaultPort: HostAddress.port(for: backend)) {
        case .address(let address):
            gtk_label_set_text(op(readingLabel), "→ \(address.url.absoluteString)")
        case .bindAll:
            gtk_label_set_text(
                op(readingLabel),
                Localized.text("0.0.0.0 is what a server binds to, never where it lives."))
        case .unsupportedScheme(let scheme):
            gtk_label_set_text(op(readingLabel), Localized.text("%@:// cannot work here.", scheme))
        case .invalid:
            gtk_label_set_text(op(readingLabel), Localized.text("Doesn't read as an address yet."))
        case .empty:
            gtk_label_set_text(op(readingLabel), "")
        }
    }

    private func scheduleProbe(afterMilliseconds: UInt32) {
        probeGeneration += 1
        let generation = probeGeneration
        Gtk.after(afterMilliseconds) { [self] in
            guard !closed, generation == probeGeneration else { return }
            probe(userInitiated: false)
        }
    }

    private func probe(userInitiated: Bool) {
        let raw = Dialogs.entryText(addressEntry)
        let backend: AgentType = useOpenCode ? .openCode : .claudeCode
        guard case .address(let address) = HostAddress.read(
            raw, defaultPort: HostAddress.port(for: backend))
        else {
            if userInitiated { updateReading() }
            return
        }
        guard let passwordRaw = gtk_editable_get_text(op(passwordEntry)) else { return }
        let password = String(cString: passwordRaw)
        gtk_label_set_text(
            op(diagnosisLabel), Localized.text("Probing %@…", address.displayHost))
        probeGeneration += 1
        let generation = probeGeneration
        let tailnetUp = tailnetAddress != nil
        Task { [self] in
            let verdict = await ProbeSweep.best(
                address: address, password: password.isEmpty ? nil : password,
                preferring: backend,
                policy: userInitiated ? ProbeSweep.interactivePolicy : ProbeSweep.typingPolicy,
                retryUnreachable: userInitiated)
            var reachability: PortReachability.Verdict?
            if case .unreachable = verdict.outcome, let host = verdict.url.host,
                let port = verdict.url.port
            {
                reachability = await PortReachability.check(host: host, port: UInt16(port))
            }
            let settled = reachability
            Gtk.onMain { [self] in
                guard !closed, generation == probeGeneration else { return }
                consume(
                    verdict, address: address, password: password, tailnetUp: tailnetUp,
                    reachability: settled, userInitiated: userInitiated)
            }
        }
    }

    private func consume(
        _ verdict: ProbeSweep.Verdict, address: HostAddress, password: String,
        tailnetUp: Bool, reachability: PortReachability.Verdict?, userInitiated: Bool
    ) {
        switch verdict.outcome {
        case .ok(let agent, let version):
            verified = (verdict.url, agent, version)
            let name = agent == .openCode ? "opencode" : "claude-bridge"
            setPill(agentPill, text: Localized.text("Answering"), css: "glyph-running")
            gtk_label_set_text(
                op(diagnosisLabel),
                Localized.text("%@ %@ answered at %@.", name, version ?? "", verdict.url.absoluteString))
            gtk_button_set_label(
                ptr(connectButton), Localized.text("Connect to %@", address.displayHost))
            if userInitiated { save(password: password) }
        case .authFailed:
            verified = nil
            if !passwordShown {
                passwordShown = true
                gtk_widget_set_visible(passwordEntry, 1)
                gtk_widget_grab_focus(passwordEntry)
            }
            gtk_label_set_text(
                op(diagnosisLabel),
                password.isEmpty
                    ? Localized.text("%@ answered and wants a password.", verdict.url.absoluteString)
                    : Localized.text(
                        "%@ refused that password. Check it on the server.",
                        verdict.url.absoluteString))
        case .notAnAgentServer:
            verified = nil
            gtk_label_set_text(
                op(diagnosisLabel),
                Localized.text(
                    "%@ answers, but not like an agent server — is something else on this port?",
                    verdict.url.absoluteString))
        case .unreachable:
            verified = nil
            guard tailnetUp else {
                gtk_label_set_text(
                    op(diagnosisLabel),
                    Localized.text(
                        "This machine is not on the tailnet — step 1 has to be true first."))
                return
            }
            switch reachability {
            case .refused:
                gtk_label_set_text(
                    op(diagnosisLabel),
                    Localized.text(
                        "The machine is up but nothing listens on %@ — start the agent from step 2.",
                        "\(verdict.url.port ?? 0)"))
            case .nameNotResolved:
                gtk_label_set_text(
                    op(diagnosisLabel),
                    Localized.text(
                        "That name does not resolve — is MagicDNS on, or use the 100.x address."))
            case .listening:
                gtk_label_set_text(
                    op(diagnosisLabel),
                    Localized.text(
                        "The port answers but not like an agent — try the other agent's port."))
            case .timedOut, .none:
                gtk_label_set_text(
                    op(diagnosisLabel),
                    Localized.text(
                        "No answer — is the other machine awake and on the tailnet?"))
            }
        }
    }

    /// Saves the profile as what actually answered: the detected agent and the URL that spoke,
    /// which quietly corrects a guessed port or a wrong toggle.
    private func save(password: String) {
        guard let verified else { return }
        let profile = ConnectionProfile(
            id: UUID().uuidString,
            name: verified.url.host ?? verified.url.absoluteString,
            backend: verified.agent,
            baseURL: verified.url,
            username: verified.agent == .claudeCode ? "claude" : "opencode")
        Task { [self] in
            do {
                try await ServerDirectory.shared.save(
                    profile, password: password.isEmpty ? nil : password)
                onSaved()
                Gtk.onMain { [self] in
                    if let window { Dialogs.close(window) }
                }
            } catch {
                Gtk.onMain { [self] in
                    gtk_label_set_text(
                        op(diagnosisLabel),
                        Localized.text("Could not save: %@", String(describing: error)))
                }
            }
        }
    }
}
