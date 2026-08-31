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
    private let tailnetRemedy = TailnetRemedyView(inset: 22)
    private var tailscale: TailscaleReading?
    private let agentPill = MacDialogs.detailLabel("")
    private let addressField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let readingLabel = MacDialogs.detailLabel("")
    private let diagnosisLabel = MacDialogs.detailLabel("", wraps: true)
    private let connectButton = RowKit.ActionButton(title: "") {}
    private var claudeRadio: NSButton!
    private var opencodeRadio: NSButton!
    private var ompRadio: NSButton!
    private var closed = false
    private var probeGeneration = 0
    /// Minted once and baked into every install command below, then adopted into the password
    /// field the moment a command is copied — the server the command starts will demand it, so
    /// handing over the bare installer and asking the user to go find what it generated is worse.
    private let mintedPassword = BridgeInstall.makePassword()
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

        let intro = MacDialogs.detailLabel(
            Localized.text(
                "Tailscode drives coding agents on your other machines. Two things have to be true first — both are checked for you."),
            wraps: true)
        column.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true

        column.addArrangedSubview(
            stepRow(number: "1", title: Localized.text("Tailscale on this Mac"), pill: tailnetPill))
        setPill(tailnetPill, text: Localized.text("Checking…"), color: MacTheme.Color.secondaryLabel)
        tailnetRemedy.isHidden = true
        column.addArrangedSubview(tailnetRemedy)
        tailnetRemedy.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40)
            .isActive = true

        column.addArrangedSubview(
            stepRow(
                number: "2",
                title: Localized.text("Run an agent on the machine with your code"),
                pill: agentPill))
        column.addArrangedSubview(
            commandRow(
                label: "claude-bridge",
                command: BridgeInstall.command(for: .claudeCode, password: mintedPassword)))
        column.addArrangedSubview(
            commandRow(
                label: "opencode",
                command: BridgeInstall.command(for: .openCode, password: mintedPassword)))
        column.addArrangedSubview(
            commandRow(
                label: "omp-bridge",
                command: BridgeInstall.command(for: .omp, password: mintedPassword)))

        column.addArrangedSubview(
            stepRow(number: "3", title: Localized.text("Connect this Mac"), pill: nil))
        addressField.placeholderString = Localized.text(
            "Tailnet address — 100.x.y.z, name.tailnet.ts.net, host:port")
        addressField.font = MacTheme.Ramp.font(.code)
        addressField.delegate = self
        addressField.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(addressField)
        addressField.widthAnchor.constraint(equalToConstant: 560).isActive = true

        claudeRadio = NSButton(
            radioButtonWithTitle: "claude-bridge · 4098", target: self,
            action: #selector(kindChanged))
        opencodeRadio = NSButton(
            radioButtonWithTitle: "opencode · 4096", target: self, action: #selector(kindChanged))
        ompRadio = NSButton(
            radioButtonWithTitle: "oh-my-pi · 4099", target: self,
            action: #selector(kindChanged))
        claudeRadio.state = .on
        let kindRow = NSStackView(views: [claudeRadio, opencodeRadio, ompRadio])
        kindRow.orientation = .horizontal
        kindRow.spacing = MacTheme.Spacing.m
        column.addArrangedSubview(kindRow)

        column.addArrangedSubview(readingLabel)
        passwordField.placeholderString = Localized.text("Password")
        passwordField.font = MacTheme.Ramp.font(.code)
        passwordField.isHidden = true
        passwordField.delegate = self
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(passwordField)
        passwordField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        column.addArrangedSubview(diagnosisLabel)
        diagnosisLabel.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40)
            .isActive = true

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
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Localized.text("Welcome")
        window.minSize = NSSize(width: 620, height: 320)
        window.contentView = MacDialogs.scrollColumn(holding: column)
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
        clearVerification()
        updateReading()
        scheduleProbe(afterMilliseconds: 100)
    }

    /// Step 2's pill and the button both name a machine that answered, so neither may outlive the
    /// question they answered: changing the address or the agent unsays them until the next probe
    /// speaks, rather than leaving a green tick over a host nobody has reached.
    private func clearVerification() {
        verified = nil
        setPill(agentPill, text: "", color: MacTheme.Color.secondaryLabel)
        connectButton.title = Localized.text("Connect")
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
        clearVerification()
        updateReading()
        scheduleProbe(afterMilliseconds: 900)
    }

    private func stepRow(number: String, title: String, pill: NSTextField?) -> NSView {
        var views: [NSView] = [
            RowKit.label(
                "\(number) ·", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel),
            RowKit.label(title, font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.label),
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
            command, font: MacTheme.Ramp.font(.code), color: MacTheme.Color.secondaryLabel)
        text.lineBreakMode = .byTruncatingTail
        let copy = RowKit.ActionButton(title: Localized.text("Copy")) { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            self?.adoptMintedPassword()
        }
        copy.bezelStyle = .accessoryBar
        let row = NSStackView(views: [
            RowKit.label(
                label, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel),
            text, copy,
        ])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        row.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// The copied command carries the minted password, so the field this window probes with has
    /// to carry the same one — filled only while it is empty, because a password somebody typed
    /// is theirs.
    private func adoptMintedPassword() {
        guard passwordField.stringValue.isEmpty else { return }
        passwordField.stringValue = mintedPassword
        passwordField.isHidden = false
    }

    private func setPill(_ label: NSTextField, text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
    }

    /// This Mac's tailnet presence, re-proved every few seconds while the window is open —
    /// someone starting Tailscale mid-setup watches the step go green by itself. The CLI is asked
    /// off the main actor, because a step that polls must never be a step that stutters.
    private func pollTailnet() {
        Task { [weak self] in
            while let self, !self.closed {
                let status = await Task.detached(priority: .utility) { TailnetStatusMac.read() }
                    .value
                guard !self.closed else { return }
                self.show(status.reading)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Step 1 as one of five states, each with the one thing that fixes it. "Not connected — open
    /// Tailscale" stood for all of them, and it is the right advice for exactly one — and it is
    /// advice, which a checklist is not supposed to give.
    private func show(_ reading: TailscaleReading) {
        tailscale = reading
        setPill(tailnetPill, text: reading.title, color: reading.tone.color)
        tailnetRemedy.write(reading)
    }

    private var preferredBackend: AgentType {
        opencodeRadio.state == .on
            ? .openCode : (ompRadio.state == .on ? .omp : .claudeCode)
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
        let tailnet = tailscale
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
                verdict, address: address, password: password, tailnet: tailnet,
                reachability: reachability, userInitiated: userInitiated)
        }
    }

    private func consume(
        _ verdict: ProbeSweep.Verdict, address: HostAddress, password: String,
        tailnet: TailscaleReading?, reachability: PortReachability.Verdict?, userInitiated: Bool
    ) {
        switch verdict.outcome {
        case .ok(let agent, let version):
            verified = (verdict.url, agent, version)
            let name: String
            switch agent {
            case .openCode: name = "opencode"
            case .claudeCode: name = "claude-bridge"
            case .omp: name = "omp-bridge"
            }
            setPill(agentPill, text: Localized.text("Answering"), color: MacTheme.Color.success)
            diagnosisLabel.stringValue = Localized.text(
                "%@ %@ answered at %@.", name, version ?? "", verdict.url.absoluteString)
            connectButton.title = Localized.text("Connect to %@", address.displayHost)
            if userInitiated { save(password: password) }
        case .authFailed(.tailnetOnly):
            clearVerification()
            setPill(agentPill, text: Localized.text("Answering"), color: MacTheme.Color.success)
            diagnosisLabel.stringValue = ServerAccessReading.tailnetOnlyDetail
        case .authFailed:
            clearVerification()
            setPill(agentPill, text: Localized.text("Answering"), color: MacTheme.Color.success)
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
            clearVerification()
            setPill(agentPill, text: Localized.text("Not an agent"), color: MacTheme.Color.warning)
            diagnosisLabel.stringValue = Localized.text(
                "%@ answers, but not like an agent server — is something else on this port?",
                verdict.url.absoluteString)
        case .unreachable:
            clearVerification()
            setPill(agentPill, text: Localized.text("No answer"), color: MacTheme.Color.warning)
            if let tailnet, !tailnet.isUp, tailnet != .sandboxed {
                diagnosisLabel.stringValue = Localized.text(
                    "This Mac is not on the tailnet — %@. Step 1 has to be true first.",
                    tailnet.title)
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
            username: ProbeSweep.username(for: verified.agent))
        do {
            try ServerDirectory.shared.save(profile, password: password.isEmpty ? nil : password)
            onSaved()
            window?.close()
        } catch {
            diagnosisLabel.stringValue = Localized.text(
                "Could not save: %@",
                (error as? AgentError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
