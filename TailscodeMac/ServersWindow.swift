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
/// Every address here is a tailnet address, so this Mac's own tailnet stands above the form as one
/// of five readings — up, signed out, not running, not installed, or unable to see — each with the
/// one press that changes it, re-taken while the window is open.
///
/// Keeping each server current is also this window's job: every claude-bridge row carries a
/// Software line that reads `/update`, offers the update with the commits it would bring, and
/// follows it through the server's own restart. A bridge too old to have the route says so and
/// hands over the one-line install command instead. Each claude profile also answers for its
/// account: signed in as whom, or signed out with the one button that fixes it.
@MainActor
final class ServersWindow: NSWindowController {
    private let onChanged: @MainActor () -> Void
    /// What to open when somebody reaches past the free copy's one server.
    var onNeedsPro: (@MainActor () -> Void)?
    /// What to open when somebody reaches past one server's own card to the whole picture.
    var onOpenUpdateCenter: (@MainActor () -> Void)?
    private let listColumn = FillingStack()
    /// Every claude-bridge row's embedded software card, by profile id — rewritten in place from
    /// the ledger rather than rebuilt, so a job landing a reading every couple of seconds does not
    /// throw away whatever section a person had open.
    private var softwareCards: [String: UpdateCardView] = [:]
    private let listHeader = MacDialogs.sectionHeader(Localized.text("CONFIGURED"))
    private let tailnetHeader = MacDialogs.sectionHeader(Localized.text("THIS MAC"))
    private let tailnetCaption = NSTextField(labelWithString: Localized.text("Tailscale"))
    private let tailnetPill = MacDialogs.detailLabel("")
    private let tailnetRemedy = TailnetRemedyView()
    private var tailnet: TailscaleReading?
    private var watchingTailnet = false
    private let addHeader = MacDialogs.sectionHeader(Localized.text("ADD A SERVER"))
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let passwordHint = NSTextField(wrappingLabelWithString: ServerPasswordRule.summary)
    private let addressField = NSTextField()
    private let nameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let claudeRadio = NSButton(radioButtonWithTitle: "claude-bridge · 4098", target: nil, action: nil)
    private let opencodeRadio = NSButton(radioButtonWithTitle: "opencode · 4096", target: nil, action: nil)
    private let ompRadio = NSButton(radioButtonWithTitle: "oh-my-pi · 4099", target: nil, action: nil)

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatesChanged), name: MacUpdateWatch.didChange, object: nil)
    }

    /// An answer landed for some machine — possibly one of these, possibly from a sweep started
    /// elsewhere, and during an install every couple of seconds. Every open card rewrites itself in
    /// place rather than the row being rebuilt around it.
    @objc private func updatesChanged() {
        for (id, card) in softwareCards {
            guard let profile = ServerDirectory.shared.profiles.first(where: { $0.id == id }) else {
                continue
            }
            applySoftware(profile, into: card)
        }
    }

    /// Nothing outside the main window is reached by its restyle pass, and every colour and size
    /// here was resolved once at construction — so without this the servers list would sit beside
    /// the window that opened it wearing the palette and the type scale of a minute ago.
    @objc private func repaint() {
        applyTheme()
        renderList()
        if let tailnet { showTailnet(tailnet) }
    }

    private func applyTheme() {
        addressField.font = MacTheme.Ramp.font(.code)
        for header in [listHeader, tailnetHeader, addHeader] {
            header.font = MacTheme.Ramp.font(.sectionLabel)
            header.textColor = MacTheme.Color.secondaryLabel
        }
        tailnetCaption.font = MacTheme.Ramp.font(.panelLabel)
        tailnetCaption.textColor = MacTheme.Color.label
        tailnetPill.font = MacTheme.Ramp.font(.panelFootnote)
        statusLabel.font = MacTheme.Ramp.font(.panelFootnote)
        statusLabel.textColor = MacTheme.Color.secondaryLabel
        passwordHint.font = MacTheme.Ramp.font(.panelFootnote)
        passwordHint.textColor = MacTheme.Color.secondaryLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        renderList()
        window?.makeKeyAndOrderFront(nil)
        pollTailnet()
        Task {
            for profile in ServerDirectory.shared.profiles where profile.backend == .claudeCode {
                await MacUpdateWatch.shared.check(.server(profileID: profile.id))
            }
        }
    }

    /// Every address in this window is a tailnet address, so this Mac's own tailnet is the first
    /// thing that has to be true — and it is one of five states rather than an address or nothing.
    /// The reading is re-taken while the window is on screen, so somebody who signs Tailscale in
    /// from here watches the line change without pressing anything.
    private func pollTailnet() {
        guard !watchingTailnet else { return }
        watchingTailnet = true
        Task { [weak self] in
            while let owner = self, owner.window?.isVisible == true {
                let status = await Task.detached(priority: .utility) { TailnetStatusMac.read() }
                    .value
                guard let owner = self, owner.window?.isVisible == true else { break }
                owner.showTailnet(status.reading)
                try? await Task.sleep(for: .seconds(5))
            }
            self?.watchingTailnet = false
        }
    }

    private func showTailnet(_ reading: TailscaleReading) {
        tailnet = reading
        tailnetPill.stringValue = reading.title
        tailnetPill.textColor = reading.tone.color
        tailnetRemedy.write(reading)
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
        ompRadio.target = self
        ompRadio.action = #selector(agentPicked)
        claudeRadio.state = .on
        let kindRow = NSStackView(views: [claudeRadio, opencodeRadio, ompRadio, Self.spacer()])
        kindRow.orientation = .horizontal
        kindRow.spacing = MacTheme.Spacing.s

        applyTheme()

        let close = NSButton(title: Localized.text("Close"), target: self, action: #selector(closeWindow))
        let probe = NSButton(
            title: Localized.text("Probe and save"), target: self, action: #selector(probeAndSave))
        probe.keyEquivalent = "\r"
        #if TAILSCODE_MAS
            let actions = NSStackView(views: [Self.spacer(), close, probe])
        #else
            let scan = NSButton(
                title: Localized.text("Find my machines"), target: self,
                action: #selector(findMachines))
            let actions = NSStackView(views: [scan, Self.spacer(), close, probe])
        #endif
        actions.orientation = .horizontal
        actions.spacing = MacTheme.Spacing.s

        let tailnetRow = NSStackView(views: [tailnetCaption, Self.spacer(), tailnetPill])
        tailnetRow.orientation = .horizontal
        tailnetRow.spacing = MacTheme.Spacing.s
        tailnetRemedy.isHidden = true

        let column = FillingStack(views: [
            listHeader, listColumn, tailnetHeader, tailnetRow, tailnetRemedy, addHeader,
            addressField, nameField, passwordField, passwordHint, kindRow, statusLabel, actions,
        ])
        column.spacing = MacTheme.Spacing.m
        column.setCustomSpacing(MacTheme.Spacing.xs, after: passwordField)
        column.setCustomSpacing(MacTheme.Spacing.xl, after: listColumn)
        column.setCustomSpacing(MacTheme.Spacing.xs, after: tailnetRow)
        column.setCustomSpacing(MacTheme.Spacing.xl, after: tailnetRemedy)
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return MacDialogs.scrollColumn(holding: column)
    }

    @objc private func agentPicked(_ sender: NSButton) {
        for radio in [claudeRadio, opencodeRadio, ompRadio] {
            radio.state = radio === sender ? .on : .off
        }
    }

    @objc private func closeWindow() {
        window?.close()
    }

    private func renderList() {
        listColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        softwareCards = [:]
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

    /// A claude-bridge row's embedded software card is floored to a real width below: every label
    /// inside it, and every label beside it in the same column, shares one required width once the
    /// column fills to its widest member, and a card built entirely from wrapping content has no
    /// opinion of its own to offer that fill — left unfloored, the whole row settles on whatever the
    /// card's tightest internal line can still lay out.
    private func makeRow(_ profile: ConnectionProfile) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: MacTheme.brandSymbol(profile.backend),
            accessibilityDescription: ServerLabel.agent(profile.backend))?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        icon.contentTintColor = MacTheme.Color.brand(profile.backend)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField(labelWithString: profile.name)
        title.font = MacTheme.Ramp.font(.cardTitle)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = MacDialogs.detailLabel(
            "\(ServerLabel.agent(profile.backend)) · \(ServerLabel.address(profile))")

        let lines = FillingStack(views: [title, detail])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2

        if profile.backend == .claudeCode {
            let card = UpdateCardView(style: .embedded)
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
            card.onAction = { [weak self] action in
                guard let self, let reading = self.softwareReading(profile) else { return }
                UpdatePress.perform(action, for: reading, from: self.window) { [weak self] text in
                    self?.setStatus(text)
                }
            }
            card.onAutomation = { [weak self, weak card] enabled in
                guard let self, let card, let reading = self.softwareReading(profile) else { return }
                UpdatePress.setAutomation(enabled, for: reading, card: card)
            }
            softwareCards[profile.id] = card
            lines.addArrangedSubview(card)
            applySoftware(profile, into: card)

            lines.addArrangedSubview(
                makeInlineButton(Localized.text("All software updates")) { [weak self] in
                    self?.onOpenUpdateCenter?()
                })

            let account = NSStackView()
            account.orientation = .vertical
            account.alignment = .leading
            account.spacing = 3
            lines.addArrangedSubview(account)
            checkAccount(profile, into: account)

            let access = MacDialogs.detailLabel("")
            access.isHidden = true
            lines.addArrangedSubview(access)
            checkAccess(profile, into: access)
        }

        let remove = NSButton(title: Localized.text("Remove"), target: self, action: #selector(removeTapped))
        remove.bezelStyle = .inline
        remove.identifier = NSUserInterfaceItemIdentifier(profile.id)
        remove.setContentHuggingPriority(.required, for: .horizontal)

        var trailing: [NSView] = [icon, lines, Self.spacer()]
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
                    self?.setStatus(ServerRestart.underway)
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

    /// The other way to add a server: ask the tailnet instead of typing an address. What the scan
    /// finds is filled into the form rather than saved behind the person's back — the label and the
    /// password are still theirs to give, and the probe that saves is the same one either road ends
    /// at, so a machine found by scanning is checked exactly as a machine typed by hand.
    #if !TAILSCODE_MAS
        @objc private func findMachines() {
            guard let window else { return }
            DiscoveryPanel.present(
                on: window, configured: ServerDirectory.shared.profiles
            ) { [weak self] suggestion in
                guard let self else { return }
                self.addressField.stringValue = suggestion.baseURL.absoluteString
                if self.nameField.stringValue.isEmpty {
                    self.nameField.stringValue = suggestion.recommendedProfileName
                }
                self.claudeRadio.state = suggestion.backend == .claudeCode ? .on : .off
                self.opencodeRadio.state = suggestion.backend == .openCode ? .on : .off
                self.ompRadio.state = suggestion.backend == .omp ? .on : .off
                if suggestion.tailnetOnly {
                    self.setStatus(
                        ServerAccessReading.tailnetOnlyTitle(host: suggestion.recommendedProfileName)
                            + " — " + ServerAccessReading.tailnetOnlyDetail)
                } else if suggestion.requiresAuth, self.passwordField.stringValue.isEmpty {
                    self.setStatus(
                        Localized.text("%@ wants a password.", suggestion.recommendedProfileName))
                    self.window?.makeFirstResponder(self.passwordField)
                } else {
                    self.probeAndSave()
                }
            }
        }
    #endif

    @objc private func probeAndSave() {
        let raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var password = passwordField.stringValue
        if password.isEmpty, let pasted = BridgeInstall.password(in: raw) {
            password = pasted
            passwordField.stringValue = pasted
        }
        let backend: AgentType =
            opencodeRadio.state == .on
            ? .openCode : (ompRadio.state == .on ? .omp : .claudeCode)

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
                    username: ProbeSweep.username(for: agent))
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
                } catch is ServerDirectory.ProRequired {
                    self.setStatus(ProOffer.requirement)
                    self.offerPro()
                } catch {
                    self.setStatus(
                        Localized.text(
                            "Could not save: %@",
                            (error as? AgentError)?.errorDescription
                                ?? error.localizedDescription))
                }
            case .authFailed(.tailnetOnly):
                self.setStatus(
                    ServerAccessReading.tailnetOnlyTitle(host: verdict.url.absoluteString)
                        + " — " + ServerAccessReading.tailnetOnlyDetail)
            case .authFailed:
                self.setStatus(
                    password.isEmpty
                        ? Localized.text(
                            "%@ answered and wants a password.", verdict.url.absoluteString)
                        : Localized.text(
                            "%@ answered but refused the password. Check it on the server.",
                            verdict.url.absoluteString))
            case .notAnAgentServer, .unreachable:
                if let tailnet = self.tailnet, !tailnet.isUp, tailnet != .sandboxed {
                    self.setStatus(
                        Localized.text(
                            "This Mac is not on the tailnet — %@. Nothing over it answers until "
                                + "that is true.", tailnet.title))
                    return
                }
                let cause = await Self.diagnose(address: address, backend: backend)
                self.setStatus(cause)
            }
        }
    }

    private func softwareReading(_ profile: ConnectionProfile) -> UpdateReading? {
        UpdateLedger.remembered(.server(profileID: profile.id))
    }

    /// The card for this machine, drawn from the ledger — or, before anything has been asked, the
    /// card of a machine being asked. Every other client answers this the same way; the classifying
    /// of what a missing field means lives once, in Core's `UpdateReadings`.
    private func applySoftware(_ profile: ConnectionProfile, into card: UpdateCardView) {
        let component = UpdateComponent.server(profileID: profile.id)
        let remembered = UpdateLedger.remembered(component)
        let reading =
            remembered
            ?? UpdateReading(
                component: component, title: profile.name, installed: .unknown,
                verdict: .unverified(.neverChecked), product: UpdateProduct.name(for: profile.backend))
        let snapshot = MacUpdateWatch.shared.snapshot
        card.apply(
            UpdateCard(
                reading, acknowledged: UpdateLedger.isAcknowledged(reading),
                busy: remembered == nil || snapshot.isBusy(component)))
    }

    /// Which account this server's Claude answers as — or the warning that it answers as nobody,
    /// with the one button that fixes it from here.
    /// What let this Mac in, in the server's own words. A row that says nothing is a server that
    /// did not report it; a row that says "trusted through your tailnet" is the reason the form
    /// above never asked for a password.
    private func checkAccess(_ profile: ConnectionProfile, into label: NSTextField) {
        guard let backend = ServerDirectory.shared.backend(for: profile) else { return }
        Task { [weak label] in
            guard let health = try? await ServerProbe.health(of: backend),
                let line = ServerAccessReading.line(health.access), let label
            else { return }
            label.stringValue = line
            label.isHidden = false
        }
    }

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
            let expected: String
            switch backend {
            case .openCode: expected = "opencode"
            case .claudeCode: expected = "claude-bridge"
            case .omp: expected = "omp-bridge"
            }
            return Localized.text(
                "%@:%@ answers, but not like a %@ server — is the other agent on this port?",
                host, "\(port)", expected)
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

    /// The gate does not just refuse — it opens the one window that answers it. A price stated
    /// with no way to pay it is a dead end, and this is the only place in the app that asks.
    private func offerPro() {
        onNeedsPro?()
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
