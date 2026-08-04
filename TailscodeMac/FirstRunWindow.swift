import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// First run is a checklist the app verifies, not a form: it states each requirement and proves
/// what it can — this Mac's tailnet presence, polled live, and which agent answers the typed
/// address via the full `probeCandidates()` sweep — before asking for anything. A failed probe
/// names its cause; a password is asked for only once a server says it wants one. Shown only
/// when no server is configured yet.
@MainActor
final class FirstRunWindow: NSObject, NSTextFieldDelegate {
    private static var open: FirstRunWindow?

    static func presentIfNeeded(onSaved: @escaping () -> Void) {
        ServerDirectory.shared.reload()
        guard ServerDirectory.shared.profiles.isEmpty else { return }
        let checklist = FirstRunWindow(onSaved: onSaved)
        open = checklist
        checklist.present()
    }

    private let onSaved: () -> Void
    private var window: FloatingWindow?
    private let tailnetPill = MacDialogs.detailLabel("")
    private let agentPill = MacDialogs.detailLabel("")
    private let addressField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let readingLabel = MacDialogs.detailLabel("")
    private let diagnosisLabel = MacDialogs.detailLabel("", wraps: true)
    private let connectButton = RowKit.ActionButton(title: "") {}
    private var claudeRadio: NSButton!
    private var opencodeRadio: NSButton!
    private var closed = false
    private var probeGeneration = 0
    private var verified: (url: URL, agent: AgentType, version: String?)?

    private init(onSaved: @escaping () -> Void) {
        self.onSaved = onSaved
        super.init()
    }

    private func present() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = MacTheme.Spacing.s
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false

        column.addArrangedSubview(
            MacDialogs.detailLabel(
                Localized.text(
                    "Tailscode drives coding agents on your other machines. Two things have to be true first — both are checked for you."),
                wraps: true))

        column.addArrangedSubview(
            stepRow(number: "1", title: Localized.text("Tailscale on this Mac"), pill: tailnetPill))
        setPill(tailnetPill, text: Localized.text("Checking…"), color: MacTheme.Color.secondaryLabel)

        column.addArrangedSubview(
            stepRow(
                number: "2",
                title: Localized.text("Run an agent on the machine with your code"),
                pill: agentPill))
        column.addArrangedSubview(
            commandRow(label: "claude-bridge", command: ServersWindow.installCommand))
        column.addArrangedSubview(
            commandRow(
                label: "opencode", command: "opencode serve --hostname 0.0.0.0 --port 4096"))

        column.addArrangedSubview(
            stepRow(number: "3", title: Localized.text("Connect this Mac"), pill: nil))
        addressField.placeholderString = Localized.text(
            "Tailnet address — 100.x.y.z, name.tailnet.ts.net, host:port")
        addressField.delegate = self
        addressField.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(addressField)
        addressField.widthAnchor.constraint(equalToConstant: 560).isActive = true

        claudeRadio = NSButton(
            radioButtonWithTitle: "claude-bridge · 4098", target: self,
            action: #selector(kindChanged))
        opencodeRadio = NSButton(
            radioButtonWithTitle: "opencode · 4096", target: self, action: #selector(kindChanged))
        claudeRadio.state = .on
        let kindRow = NSStackView(views: [claudeRadio, opencodeRadio])
        kindRow.orientation = .horizontal
        kindRow.spacing = MacTheme.Spacing.m
        column.addArrangedSubview(kindRow)

        column.addArrangedSubview(readingLabel)
        passwordField.placeholderString = Localized.text("Password")
        passwordField.isHidden = true
        passwordField.delegate = self
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(passwordField)
        passwordField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        column.addArrangedSubview(diagnosisLabel)

        connectButton.title = Localized.text("Connect")
        connectButton.keyEquivalent = "\r"
        let demo = RowKit.ActionButton(title: Localized.text("Try the demo")) { [weak self] in
            self?.enterDemo()
        }
        let later = RowKit.ActionButton(title: Localized.text("Later")) { [weak self] in
            self?.window?.close()
        }
        let actions = NSStackView(views: [RowKit.spacer(), demo, later, connectButton])
        actions.orientation = .horizontal
        actions.spacing = MacTheme.Spacing.s
        actions.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(actions)
        actions.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -20)
            .isActive = true

        let window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Localized.text("Welcome")
        window.contentView = column
        window.center()
        self.window = window
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification,
            object: window)
        replaceConnectAction()
        pollTailnet()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(addressField)
    }

    /// `ActionButton` takes its closure at init and `self` does not exist yet there, so the
    /// button is rewired to the real probe once construction is done.
    private func replaceConnectAction() {
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
    }

    @objc private func connectTapped() {
        probe(userInitiated: true)
    }

    @objc private func kindChanged() {
        verified = nil
        updateReading()
        scheduleProbe(afterMilliseconds: 100)
    }

    @objc private func windowClosed() {
        closed = true
        Self.open = nil
    }

    private func enterDemo() {
        ServerDirectory.shared.enterDemoMode()
        onSaved()
        window?.close()
    }

    func controlTextDidChange(_ notification: Notification) {
        verified = nil
        updateReading()
        scheduleProbe(afterMilliseconds: 900)
    }

    private func stepRow(number: String, title: String, pill: NSTextField?) -> NSView {
        var views: [NSView] = [
            RowKit.label(
                "\(number) ·", font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel),
            RowKit.label(title, font: MacTheme.Font.body(), color: MacTheme.Color.label),
        ]
        if let pill {
            views.append(RowKit.spacer())
            views.append(pill)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func commandRow(label: String, command: String) -> NSView {
        let text = RowKit.label(
            command, font: MacTheme.Font.mono(), color: MacTheme.Color.secondaryLabel)
        text.lineBreakMode = .byTruncatingTail
        let copy = RowKit.ActionButton(title: Localized.text("Copy")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        copy.bezelStyle = .accessoryBar
        let row = NSStackView(views: [
            RowKit.label(
                label, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel),
            text, copy,
        ])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        row.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func setPill(_ label: NSTextField, text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
    }

    /// This Mac's tailnet presence, re-proved every few seconds while the window is open —
    /// someone starting Tailscale mid-setup watches the step go green by itself.
    private func pollTailnet() {
        Task { [weak self] in
            while let self, !self.closed {
                let address = TailnetStatusMac.localAddress()
                if let address {
                    self.setPill(self.tailnetPill, text: address, color: .systemGreen)
                } else {
                    self.setPill(
                        self.tailnetPill,
                        text: Localized.text("Not connected — open Tailscale"),
                        color: .systemOrange)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var preferredBackend: AgentType {
        opencodeRadio.state == .on ? .openCode : .claudeCode
    }

    private func updateReading() {
        let raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            readingLabel.stringValue = ""
            return
        }
        switch HostAddress.read(raw, defaultPort: HostAddress.port(for: preferredBackend)) {
        case .address(let address):
            readingLabel.stringValue = "→ \(address.url.absoluteString)"
        case .bindAll:
            readingLabel.stringValue = Localized.text(
                "0.0.0.0 is what a server binds to, never where it lives.")
        case .unsupportedScheme(let scheme):
            readingLabel.stringValue = Localized.text("%@:// cannot work here.", scheme)
        case .invalid:
            readingLabel.stringValue = Localized.text("Doesn't read as an address yet.")
        case .empty:
            readingLabel.stringValue = ""
        }
    }

    private func scheduleProbe(afterMilliseconds: Int) {
        probeGeneration += 1
        let generation = probeGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(afterMilliseconds))
            guard let self, !self.closed, generation == self.probeGeneration else { return }
            self.probe(userInitiated: false)
        }
    }

    private func probe(userInitiated: Bool) {
        let raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = preferredBackend
        guard
            case .address(let address) = HostAddress.read(
                raw, defaultPort: HostAddress.port(for: backend))
        else {
            if userInitiated { updateReading() }
            return
        }
        let password = passwordField.stringValue
        diagnosisLabel.stringValue = Localized.text("Probing %@…", address.displayHost)
        probeGeneration += 1
        let generation = probeGeneration
        let tailnetUp = TailnetStatusMac.localAddress() != nil
        Task { [weak self] in
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
            guard let self, !self.closed, generation == self.probeGeneration else { return }
            self.consume(
                verdict, address: address, password: password, tailnetUp: tailnetUp,
                reachability: reachability, userInitiated: userInitiated)
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
            setPill(agentPill, text: Localized.text("Answering"), color: .systemGreen)
            diagnosisLabel.stringValue = Localized.text(
                "%@ %@ answered at %@.", name, version ?? "", verdict.url.absoluteString)
            connectButton.title = Localized.text("Connect to %@", address.displayHost)
            if userInitiated { save(password: password) }
        case .authFailed:
            verified = nil
            if passwordField.isHidden {
                passwordField.isHidden = false
                window?.makeFirstResponder(passwordField)
            }
            diagnosisLabel.stringValue =
                password.isEmpty
                ? Localized.text("%@ answered and wants a password.", verdict.url.absoluteString)
                : Localized.text(
                    "%@ refused that password. Check it on the server.",
                    verdict.url.absoluteString)
        case .notAnAgentServer:
            verified = nil
            diagnosisLabel.stringValue = Localized.text(
                "%@ answers, but not like an agent server — is something else on this port?",
                verdict.url.absoluteString)
        case .unreachable:
            verified = nil
            guard tailnetUp else {
                diagnosisLabel.stringValue = Localized.text(
                    "This Mac is not on the tailnet — step 1 has to be true first.")
                return
            }
            switch reachability {
            case .refused:
                diagnosisLabel.stringValue = Localized.text(
                    "The machine is up but nothing listens on %@ — start the agent from step 2.",
                    "\(verdict.url.port ?? 0)")
            case .nameNotResolved:
                diagnosisLabel.stringValue = Localized.text(
                    "That name does not resolve — is MagicDNS on, or use the 100.x address.")
            case .listening:
                diagnosisLabel.stringValue = Localized.text(
                    "The port answers but not like an agent — try the other agent's port.")
            case .timedOut, .none:
                diagnosisLabel.stringValue = Localized.text(
                    "No answer — is the other machine awake and on the tailnet?")
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
        do {
            try ServerDirectory.shared.save(profile, password: password.isEmpty ? nil : password)
            onSaved()
            window?.close()
        } catch {
            diagnosisLabel.stringValue = Localized.text(
                "Could not save: %@", String(describing: error))
        }
    }
}
