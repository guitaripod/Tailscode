import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// A probe against a machine that is down must fail in seconds, not sit on the URL loader's
/// two-minute connectivity grace: the racing deadline turns "still probing…" into a named
/// diagnosis while the person is still looking at the form.
enum ServerProbe {
    static func health(
        of backend: any CodingAgentBackend, within seconds: Int = 10
    ) async throws -> ServerHealth {
        try await withThrowingTaskGroup(of: ServerHealth.self) { group in
            group.addTask { try await backend.health() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AgentError.connection("the server did not answer within \(seconds)s")
            }
            guard let first = try await group.next() else {
                throw AgentError.connection("no probe outcome")
            }
            group.cancelAll()
            return first
        }
    }
}

/// The servers this Mac knows, editable in place. Adding one probes it before saving — a typo
/// fails here, named, rather than becoming a row that never loads — and the failure names its
/// cause: the address didn't parse, the port didn't answer, the password was refused.
///
/// Keeping each server current is also this window's job: every claude-bridge row carries a
/// Software line that reads `/update`, offers the update with the commits it would bring, and
/// follows it through the server's own restart. A bridge too old to have the route says so and
/// hands over the one-line install command instead. Each claude profile also answers for its
/// account: signed in as whom, or signed out with the one button that fixes it.
@MainActor
final class ServersWindow: NSWindowController {
    static let installCommand = BridgeInstall.installCommand

    private let onChanged: @MainActor () -> Void
    private let listColumn = FillingStack()
    private let listHeader = MacDialogs.sectionHeader(Localized.text("CONFIGURED"))
    private let addHeader = MacDialogs.sectionHeader(Localized.text("ADD A SERVER"))
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let addressField = NSTextField()
    private let nameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let claudeRadio = NSButton(radioButtonWithTitle: "claude-bridge · 4098", target: nil, action: nil)
    private let opencodeRadio = NSButton(radioButtonWithTitle: "opencode · 4096", target: nil, action: nil)

    init(onChanged: @escaping @MainActor () -> Void) {
        self.onChanged = onChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Localized.text("Servers")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    /// Nothing outside the main window is reached by its restyle pass, and every colour and size
    /// here was resolved once at construction — so without this the servers list would sit beside
    /// the window that opened it wearing the palette and the type scale of a minute ago.
    @objc private func repaint() {
        applyTheme()
        renderList()
    }

    private func applyTheme() {
        addressField.font = MacTheme.Ramp.font(.code)
        for header in [listHeader, addHeader] {
            header.font = MacTheme.Ramp.font(.sectionLabel)
            header.textColor = MacTheme.Color.secondaryLabel
        }
        statusLabel.font = MacTheme.Ramp.font(.panelFootnote)
        statusLabel.textColor = MacTheme.Color.secondaryLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        renderList()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeContent() -> NSView {
        listColumn.spacing = MacTheme.Spacing.m

        addressField.placeholderString = Localized.text(
            "Tailnet address — 100.x.y.z, name.tailnet.ts.net, host:port")
        nameField.placeholderString = Localized.text("Label (optional)")
        passwordField.placeholderString = Localized.text("Password")
        claudeRadio.target = self
        claudeRadio.action = #selector(agentPicked)
        opencodeRadio.target = self
        opencodeRadio.action = #selector(agentPicked)
        claudeRadio.state = .on
        let kindRow = NSStackView(views: [claudeRadio, opencodeRadio, Self.spacer()])
        kindRow.orientation = .horizontal
        kindRow.spacing = MacTheme.Spacing.s

        applyTheme()

        let close = NSButton(title: Localized.text("Close"), target: self, action: #selector(closeWindow))
        let probe = NSButton(
            title: Localized.text("Probe and save"), target: self, action: #selector(probeAndSave))
        probe.keyEquivalent = "\r"
        let actions = NSStackView(views: [Self.spacer(), close, probe])
        actions.orientation = .horizontal
        actions.spacing = MacTheme.Spacing.s

        let column = FillingStack(views: [
            listHeader, listColumn, addHeader,
            addressField, nameField, passwordField, kindRow, statusLabel, actions,
        ])
        column.spacing = MacTheme.Spacing.m
        column.setCustomSpacing(MacTheme.Spacing.xl, after: listColumn)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return MacDialogs.scrollColumn(holding: column)
    }

    @objc private func agentPicked(_ sender: NSButton) {
        claudeRadio.state = sender === claudeRadio ? .on : .off
        opencodeRadio.state = sender === opencodeRadio ? .on : .off
    }

    @objc private func closeWindow() {
        window?.close()
    }

    private func renderList() {
        listColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else {
            listColumn.addArrangedSubview(
                MacDialogs.detailLabel(Localized.text("No servers yet.")))
            return
        }
        for profile in profiles {
            listColumn.addArrangedSubview(makeRow(profile))
        }
    }

    private func makeRow(_ profile: ConnectionProfile) -> NSView {
        let title = NSTextField(labelWithString: profile.name)
        title.font = MacTheme.Ramp.font(.cardTitle)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = MacDialogs.detailLabel(
            "\(ServerLabel.agent(profile.backend)) · \(ServerLabel.address(profile))")

        let lines = NSStackView(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2

        if profile.backend == .claudeCode {
            let software = NSStackView()
            software.orientation = .vertical
            software.alignment = .leading
            software.spacing = 3
            lines.addArrangedSubview(software)

            let auto = AutoUpdateRow()
            auto.onSet = { [weak self, weak auto] enabled in
                guard let auto else { return }
                self?.setAutoUpdate(profile, enabled, auto: auto, into: software)
            }
            lines.addArrangedSubview(auto)
            checkSoftware(profile, auto: auto, into: software)

            let account = NSStackView()
            account.orientation = .vertical
            account.alignment = .leading
            account.spacing = 3
            lines.addArrangedSubview(account)
            checkAccount(profile, into: account)
        }

        let remove = NSButton(title: Localized.text("Remove"), target: self, action: #selector(removeTapped))
        remove.bezelStyle = .inline
        remove.identifier = NSUserInterfaceItemIdentifier(profile.id)
        remove.setContentHuggingPriority(.required, for: .horizontal)

        var trailing: [NSView] = [lines, Self.spacer()]
        if ServerRestart.isOffered(profile.backend) {
            let restart = NSButton(
                title: ServerRestart.title, target: self, action: #selector(restartTapped))
            restart.bezelStyle = .inline
            restart.identifier = NSUserInterfaceItemIdentifier(profile.id)
            restart.setContentHuggingPriority(.required, for: .horizontal)
            trailing.append(restart)
        }
        trailing.append(remove)

        let row = NSStackView(views: trailing)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = MacTheme.Spacing.s
        return row
    }

    /// The press states its cost first, then hands the ask over and stops: the connection it went
    /// over dies with the process it restarted, so the reconnect every screen already watches is
    /// what says the machine is back. A machine set up by hand refuses the restart, and the refusal
    /// is the offer: the setup that makes it restartable is one press, not a terminal instruction.
    @objc private func restartTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let profile = ServerDirectory.shared.profiles.first(where: { $0.id == id })
        else { return }
        MacDialogs.confirm(
            on: window,
            title: ServerRestart.confirmTitle(profile.name),
            body: ServerRestart.confirmBody(workingTurns: 0),
            confirmLabel: ServerRestart.action
        ) {
            Task { [weak self] in
                guard
                    let backend = ServerDirectory.shared.backend(for: profile),
                    let restartable = backend as? any RestartableBackend
                else { return }
                do {
                    try await restartable.restart()
                    self.setStatus(ServerRestart.underway)
                } catch {
                    self?.offerSetup(name: profile.name, backend: backend)
                }
            }
        }
    }

    private func offerSetup(name: String, backend: any CodingAgentBackend) {
        guard let settable = backend as? any ServeManagerBackend else {
            MacDialogs.confirm(
                on: window,
                title: ServerRestart.refusedTitle,
                body: ServerRestart.refused(name),
                confirmLabel: Localized.text("OK"),
                destructive: false
            ) {}
            return
        }
        MacDialogs.confirm(
            on: window,
            title: ServerRestart.setupTitle,
            body: ServerRestart.setupDetail,
            confirmLabel: ServerRestart.setupAction,
            destructive: false
        ) {
            Task {
                do {
                    try await settable.installServeManager()
                    MacDialogs.confirm(
                        on: self.window,
                        title: ServerRestart.setupUnderway,
                        body: Localized.text("%@ is restarting with its new setup.", name),
                        confirmLabel: Localized.text("OK"),
                        destructive: false
                    ) {}
                } catch {
                    MacDialogs.confirm(
                        on: self.window,
                        title: ServerRestart.setupFailedTitle,
                        body: ServerRestart.setupFailedDetail,
                        confirmLabel: Localized.text("OK"),
                        destructive: false
                    ) {}
                }
            }
        }
    }

    @objc private func removeTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let profile = ServerDirectory.shared.profiles.first(where: { $0.id == id })
        else { return }
        MacDialogs.confirm(
            on: window,
            title: Localized.text("Remove %@?", profile.name),
            body: Localized.text(
                "The saved address and password go away. Conversations stay on the server."),
            confirmLabel: Localized.text("Remove")
        ) { [weak self] in
            ServerDirectory.shared.delete(id: id)
            self?.onChanged()
            self?.renderList()
        }
    }

    @objc private func probeAndSave() {
        let raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var password = passwordField.stringValue
        if password.isEmpty, let pasted = BridgeInstall.password(in: raw) {
            password = pasted
            passwordField.stringValue = pasted
        }
        let backend: AgentType = opencodeRadio.state == .on ? .openCode : .claudeCode

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
            guard let self else { return }
            switch verdict.outcome {
            case .ok(let agent, let version):
                let profile = ConnectionProfile(
                    id: UUID().uuidString,
                    name: label.isEmpty ? address.displayHost : label,
                    backend: agent,
                    baseURL: verdict.url,
                    username: agent == .claudeCode ? "claude" : "opencode")
                do {
                    try ServerDirectory.shared.save(
                        profile, password: password.isEmpty ? nil : password)
                    self.onChanged()
                    self.setStatus(
                        Localized.text(
                            "Saved %@ — %@", profile.name, version ?? Localized.text("connected")))
                    self.renderList()
                    self.addressField.stringValue = ""
                    self.nameField.stringValue = ""
                    self.passwordField.stringValue = ""
                } catch {
                    self.setStatus(
                        Localized.text(
                            "Could not save: %@",
                            (error as? AgentError)?.errorDescription
                                ?? error.localizedDescription))
                }
            case .authFailed:
                self.setStatus(
                    password.isEmpty
                        ? Localized.text(
                            "%@ answered and wants a password.", verdict.url.absoluteString)
                        : Localized.text(
                            "%@ answered but refused the password. Check it on the server.",
                            verdict.url.absoluteString))
            case .notAnAgentServer, .unreachable:
                let cause = await Self.diagnose(address: address, backend: backend)
                self.setStatus(cause)
            }
        }
    }

    /// What this machine says about its own software, asked and classified in the one place that
    /// does it — an unanswered `/update` has two very different causes, and only one of them
    /// deserves the install command: a bridge old enough to lack the route still answers `/health`,
    /// while a machine that answers neither is unreachable, and telling somebody to reinstall a
    /// server that is merely asleep would be worse than saying nothing.
    private func checkSoftware(
        _ profile: ConnectionProfile, auto: AutoUpdateRow, into box: NSStackView
    ) {
        setSoftwareText(box, Localized.text("Checking for updates…"))
        Task { [weak self] in
            let reading = await MacUpdateWatch.shared.check(profile, checkingRemote: true)
            self?.renderSoftware(reading, profile: profile, auto: auto, into: box)
        }
    }

    /// One reading, in Core's own words. A second ladder of hand-written cases here is exactly how
    /// this window and the Update Center came to hold two opinions about what a missing field
    /// meant, so there is one renderer and both surfaces call it.
    ///
    /// The invitation is switched over rather than sorted by a property, because the two presses
    /// this window follows through itself — fetch and build, and load a build already there — are
    /// two different jobs on the machine and only one of them is worth minutes of building. Every
    /// other invitation ends in the shared one, and a case added to Core stops compiling here until
    /// somebody says which of the two it is.
    private func renderSoftware(
        _ reading: UpdateReading, profile: ConnectionProfile, auto: AutoUpdateRow,
        into box: NSStackView
    ) {
        box.arrangedSubviews.forEach { $0.removeFromSuperview() }
        box.addArrangedSubview(
            RowKit.label(
                reading.headline, font: MacTheme.Ramp.font(.cardTitle), color: reading.tone.color))
        for line in UpdateReadingViews.lines(for: reading) {
            box.addArrangedSubview(line)
        }
        auto.write(reading.automation)
        guard let invitation = reading.invitation else { return }
        if let promise = UpdateReadingViews.promise(invitation) {
            box.addArrangedSubview(promise)
        }
        box.addArrangedSubview(
            makeInlineButton(invitation.label) { [weak self] in
                guard let self else { return }
                switch invitation {
                case .installHere:
                    self.runUpdate(profile, auto: auto, into: box)
                case .restartHere:
                    self.runRestart(profile, auto: auto, into: box)
                case .openStore, .copyCommand, .openPage, .recheck:
                    guard let said = UpdateReadingViews.perform(invitation, on: reading) else {
                        return
                    }
                    self.setStatus(said)
                }
            })
    }

    /// The update is followed to the end, not to the first heartbeat — the shared watch owns that
    /// loop, and this window only draws each step it reports.
    private func runUpdate(
        _ profile: ConnectionProfile, auto: AutoUpdateRow, into box: NSStackView
    ) {
        setSoftwareText(box, Localized.text("Updating — asking the server to fetch and build…"))
        follow(profile, auto: auto, into: box) { step in
            await MacUpdateWatch.shared.install(.server(profileID: profile.id), onStep: step)
        }
    }

    /// The build is already on that machine, so there is nothing to fetch and nothing to make: the
    /// press hands the process to whatever starts it again. It is followed exactly the way an
    /// update is, because the stretch that matters — the machine answering nothing while it comes
    /// back — is the same stretch.
    private func runRestart(
        _ profile: ConnectionProfile, auto: AutoUpdateRow, into box: NSStackView
    ) {
        setSoftwareText(
            box, Localized.text("Asking the server to load the build it already has…"))
        follow(profile, auto: auto, into: box) { step in
            await MacUpdateWatch.shared.restart(.server(profileID: profile.id), onStep: step)
        }
    }

    private func follow(
        _ profile: ConnectionProfile, auto: AutoUpdateRow, into box: NSStackView,
        job: @escaping @MainActor (@escaping @MainActor (UpdateReading) -> Void) async -> Void
    ) {
        Task { [weak self] in
            await job { reading in
                self?.renderSoftware(reading, profile: profile, auto: auto, into: box)
            }
            guard let self,
                let settled = UpdateLedger.remembered(.server(profileID: profile.id))
            else { return }
            self.setStatus(
                Localized.text("%@ — %@", profile.name, settled.installed.line))
        }
    }

    /// The policy is the machine's, so the press is a request and the switch takes its position
    /// from the answer. What comes back is published through the same path a check is, which is why
    /// the ledger — and the Update Center reading from it — agree before this row is redrawn; a
    /// refusal changes nothing except the line at the foot of this window.
    private func setAutoUpdate(
        _ profile: ConnectionProfile, _ enabled: Bool, auto: AutoUpdateRow, into box: NSStackView
    ) {
        auto.setAsking(true)
        Task { [weak self] in
            var refusal: String?
            do {
                _ = try await MacUpdateWatch.shared.setAutoUpdate(
                    .server(profileID: profile.id), enabled)
            } catch {
                refusal = (error as? AgentError)?.errorDescription ?? error.localizedDescription
            }
            guard let self else { return }
            auto.setAsking(false)
            if let settled = UpdateLedger.remembered(.server(profileID: profile.id)) {
                self.renderSoftware(settled, profile: profile, auto: auto, into: box)
            }
            guard let refusal else { return }
            self.setStatus(
                Localized.text("%@ would not take that setting — %@", profile.name, refusal))
        }
    }

    /// Which account this server's Claude answers as — or the warning that it answers as nobody,
    /// with the one button that fixes it from here.
    private func checkAccount(_ profile: ConnectionProfile, into box: NSStackView) {
        guard
            let backend = ServerDirectory.shared.backend(for: profile)
                as? any AuthenticatingBackend
        else { return }
        setSoftwareText(box, Localized.text("Checking the Claude account…"))
        Task { [weak self] in
            do {
                let auth = try await backend.authStatus()
                self?.renderAccount(auth, profile: profile, backend: backend, into: box)
            } catch {
                self?.setSoftwareText(
                    box,
                    Localized.text("Could not read the Claude account on %@.", profile.name))
            }
        }
    }

    private func renderAccount(
        _ auth: ServerAuth, profile: ConnectionProfile, backend: any AuthenticatingBackend,
        into box: NSStackView
    ) {
        box.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !auth.loggedIn else {
            var line = Localized.text(
                "Claude account: %@", auth.accountLabel ?? Localized.text("signed in"))
            if let subscription = auth.subscription, !subscription.isEmpty {
                line += " · \(subscription)"
            }
            box.addArrangedSubview(MacDialogs.detailLabel(line))
            return
        }
        let warning = NSTextField(
            wrappingLabelWithString: Localized.text(
                "⚠ Claude is signed out — every turn will refuse until it signs in."))
        warning.font = MacTheme.Ramp.font(.panelFootnote)
        warning.textColor = MacTheme.Color.warning
        box.addArrangedSubview(warning)
        box.addArrangedSubview(
            makeInlineButton(Localized.text("Sign in")) { [weak self] in
                guard let self, let window = self.window else { return }
                SignInSheet.present(
                    on: window, serverName: profile.name, backend: backend
                ) { [weak self] in
                    guard let self else { return }
                    self.checkAccount(profile, into: box)
                }
            })
    }

    private func setSoftwareText(_ box: NSStackView, _ text: String) {
        box.arrangedSubviews.forEach { $0.removeFromSuperview() }
        box.addArrangedSubview(MacDialogs.detailLabel(text, wraps: true))
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
            return Localized.text("%@ did not answer — check Tailscale on both machines.", host)
        case .nameNotResolved:
            return Localized.text(
                "“%@” does not resolve — is MagicDNS on, or use the 100.x address.", host)
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func makeInlineButton(
        _ title: String, onClick: @escaping @MainActor () -> Void
    ) -> NSButton {
        let button = ClosureButton(title: title, onClick: onClick)
        button.bezelStyle = .inline
        return button
    }

    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }
}

/// A button whose action is a closure, for rows built per profile where a selector would need a
/// lookup table on the side.
@MainActor
private final class ClosureButton: NSButton {
    private let onClick: @MainActor () -> Void

    init(title: String, onClick: @escaping @MainActor () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        isBordered = true
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        onClick()
    }
}
