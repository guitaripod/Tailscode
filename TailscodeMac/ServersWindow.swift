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
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/guitaripod/claude-bridge/master/install.sh | bash"

    private let onChanged: @MainActor () -> Void
    private let listColumn = NSStackView()
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        renderList()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeContent() -> NSView {
        listColumn.orientation = .vertical
        listColumn.alignment = .width
        listColumn.spacing = MacTheme.Spacing.m

        addressField.placeholderString = Localized.text(
            "Tailnet address — 100.x.y.z, name.tailnet.ts.net, host:port")
        addressField.font = MacTheme.Font.mono()
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

        statusLabel.font = MacTheme.Font.caption()
        statusLabel.textColor = MacTheme.Color.secondaryLabel

        let close = NSButton(title: Localized.text("Close"), target: self, action: #selector(closeWindow))
        let probe = NSButton(
            title: Localized.text("Probe and save"), target: self, action: #selector(probeAndSave))
        probe.keyEquivalent = "\r"
        let actions = NSStackView(views: [Self.spacer(), close, probe])
        actions.orientation = .horizontal
        actions.spacing = MacTheme.Spacing.s

        let column = NSStackView(views: [
            MacDialogs.sectionHeader(Localized.text("CONFIGURED")),
            listColumn,
            MacDialogs.sectionHeader(Localized.text("ADD A SERVER")),
            addressField, nameField, passwordField, kindRow, statusLabel, actions,
        ])
        column.orientation = .vertical
        column.alignment = .width
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
        title.font = MacTheme.Font.emphasis()
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
            checkSoftware(profile, into: software)

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

        let row = NSStackView(views: [lines, Self.spacer(), remove])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = MacTheme.Spacing.s
        return row
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
        let password = passwordField.stringValue
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
        let profile = ConnectionProfile(
            id: UUID().uuidString,
            name: label.isEmpty ? address.displayHost : label,
            backend: backend,
            baseURL: address.url,
            username: backend == .claudeCode ? "claude" : "opencode")

        Task { [weak self] in
            let candidate = profile.makeBackend(password: password.isEmpty ? nil : password)
            do {
                let health = try await ServerProbe.health(of: candidate)
                guard let self else { return }
                try ServerDirectory.shared.save(
                    profile, password: password.isEmpty ? nil : password)
                self.onChanged()
                self.setStatus(
                    Localized.text("Saved %@ — %@", profile.name, health.version ?? "connected"))
                self.renderList()
                self.addressField.stringValue = ""
            } catch {
                let cause = await Self.diagnose(address: address, backend: backend, error: error)
                self?.setStatus(cause)
            }
        }
    }

    /// An unanswered `/update` has two very different causes, and only one deserves the install
    /// command: a bridge old enough to lack the route still answers `/health`, while a machine
    /// that answers neither is unreachable — telling someone to reinstall a server that is merely
    /// asleep would be worse than saying nothing.
    private func checkSoftware(_ profile: ConnectionProfile, into box: NSStackView) {
        setSoftwareText(box, Localized.text("Checking for updates…"))
        guard
            let backend = ServerDirectory.shared.backend(for: profile)
                as? any SelfUpdatingBackend
        else { return }
        Task { [weak self] in
            if let update = try? await backend.updateStatus(checkingRemote: true) {
                self?.renderSoftware(update, profile: profile, into: box)
            } else if (try? await backend.health()) != nil {
                self?.renderSoftware(nil, profile: profile, into: box)
            } else {
                self?.setSoftwareText(
                    box,
                    Localized.text("Could not check for updates — the server is unreachable."))
            }
        }
    }

    private func renderSoftware(
        _ update: ServerUpdate?, profile: ConnectionProfile, into box: NSStackView
    ) {
        box.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let update else {
            box.addArrangedSubview(
                MacDialogs.detailLabel(
                    Localized.text(
                        "This bridge is too old to report its software. Update it by hand:"),
                    wraps: true))
            box.addArrangedSubview(
                makeInlineButton(Localized.text("Copy the install command")) { [weak self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.installCommand, forType: .string)
                    self?.setStatus(Localized.text("Command copied"))
                })
            return
        }
        if update.phase == .failed {
            let detail = update.reason ?? update.log.map { String($0.suffix(300)) } ?? ""
            let failure = NSTextField(
                wrappingLabelWithString: Localized.text("The last update failed. %@", detail))
            failure.font = MacTheme.Font.caption()
            failure.textColor = MacTheme.Color.danger
            box.addArrangedSubview(failure)
        }
        guard update.updateAvailable else {
            box.addArrangedSubview(
                MacDialogs.detailLabel(Localized.text("%@ · up to date", update.version)))
            return
        }
        let target = update.latestVersion
            ?? update.latestCommit.map { String($0.prefix(7)) }
            ?? Localized.text("latest")
        var headline = "\(update.version) → \(target)"
        if let behind = update.behind, behind > 0 {
            headline += " · " + Localized.text("%@ commits behind", "\(behind)")
        }
        let head = NSTextField(labelWithString: headline)
        head.font = MacTheme.Font.emphasis()
        box.addArrangedSubview(head)
        for change in update.changes.prefix(5) {
            box.addArrangedSubview(MacDialogs.detailLabel("· \(change)", wraps: true))
        }
        if update.canUpdate {
            box.addArrangedSubview(
                makeInlineButton(Localized.text("Update the server")) { [weak self] in
                    self?.runUpdate(profile, into: box)
                })
        } else if let reason = update.reason {
            box.addArrangedSubview(MacDialogs.detailLabel(reason, wraps: true))
        }
    }

    /// The update is followed to the end, not to the first heartbeat: the old process keeps
    /// answering `/health` through the whole fetch and build, so the loop watches the update's
    /// own phase and treats a refused connection as the restart doing its job. Only a settled
    /// phase — or ten minutes of silence — ends it.
    private func runUpdate(_ profile: ConnectionProfile, into box: NSStackView) {
        setSoftwareText(box, Localized.text("Updating — asking the server to fetch and build…"))
        guard
            let backend = ServerDirectory.shared.backend(for: profile)
                as? any SelfUpdatingBackend
        else { return }
        Task { [weak self] in
            _ = try? await backend.startUpdate()
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                guard let update = try? await backend.updateStatus(checkingRemote: false) else {
                    self.setSoftwareText(
                        box, Localized.text("Updating — the server is restarting…"))
                    continue
                }
                if update.isRunning {
                    let phase =
                        update.phase == .building
                        ? Localized.text("Updating — building…")
                        : update.phase == .restarting
                            ? Localized.text("Updating — restarting…")
                            : Localized.text("Updating — fetching…")
                    self.setSoftwareText(box, phase)
                    continue
                }
                self.renderSoftware(update, profile: profile, into: box)
                self.setStatus(Localized.text("%@ is back — %@", profile.name, update.version))
                return
            }
            self?.setSoftwareText(
                box,
                Localized.text(
                    "The update did not settle within ten minutes — check the server over ssh."))
        }
    }

    /// Which account this server's Claude answers as — or the warning that it answers as nobody,
    /// with the one button that fixes it from here.
    private func checkAccount(_ profile: ConnectionProfile, into box: NSStackView) {
        guard
            let backend = ServerDirectory.shared.backend(for: profile)
                as? any AuthenticatingBackend
        else { return }
        Task { [weak self] in
            guard let auth = try? await backend.authStatus() else { return }
            self?.renderAccount(auth, profile: profile, backend: backend, into: box)
        }
    }

    private func renderAccount(
        _ auth: ServerAuth, profile: ConnectionProfile, backend: any AuthenticatingBackend,
        into box: NSStackView
    ) {
        box.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !auth.loggedIn else {
            var line = Localized.text("Claude account: %@", auth.accountLabel ?? "signed in")
            if let subscription = auth.subscription, !subscription.isEmpty {
                line += " · \(subscription)"
            }
            box.addArrangedSubview(MacDialogs.detailLabel(line))
            return
        }
        let warning = NSTextField(
            wrappingLabelWithString: Localized.text(
                "⚠ Claude is signed out — every turn will refuse until it signs in."))
        warning.font = MacTheme.Font.caption()
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
