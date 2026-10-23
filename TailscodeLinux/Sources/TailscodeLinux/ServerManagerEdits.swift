import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ServerManager {
    func applyAddress(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }),
            let slots = rows[id], let field = slots.address
        else { return }
        let raw = Dialogs.entryText(field)
        let reading = HostAddress.read(raw, defaultPort: HostAddress.port(for: profile.backend))
        guard case .address(let address) = reading else {
            gtk_editable_set_text(op(field), Self.editableAddress(profile))
            toast(Self.explain(reading, raw: raw))
            return
        }
        guard address.url != profile.baseURL else { return }
        save(
            ConnectionProfile(
                id: profile.id, name: profile.name, backend: profile.backend,
                baseURL: address.url, username: profile.username),
            keepingPasswordOf: profile,
            toast: Localized.text("%@ now points at %@", profile.name, address.displayHost))
    }

    func applyName(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }),
            let slots = rows[id], let field = slots.name
        else { return }
        let name = Dialogs.entryText(field)
        guard !name.isEmpty else {
            gtk_editable_set_text(op(field), profile.name)
            return
        }
        guard name != profile.name else { return }
        save(
            ConnectionProfile(
                id: profile.id, name: name, backend: profile.backend, baseURL: profile.baseURL,
                username: profile.username),
            keepingPasswordOf: profile,
            toast: Localized.text("Renamed to %@", name))
    }

    func applyPassword(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }),
            let slots = rows[id], let field = slots.password
        else { return }
        let password = Self.secretText(field)
        expandAfterReload = profile.id
        Task { [weak self] in
            do {
                try await ServerDirectory.shared.save(
                    profile, password: password.isEmpty ? nil : password)
                self?.onChanged()
                Gtk.onMain { [weak self] in
                    self?.toast(
                        password.isEmpty
                            ? Localized.text("%@ will connect without a password.", profile.name)
                            : Localized.text("New password saved for %@.", profile.name))
                    self?.reload()
                }
            } catch {
                let text = Localized.text("Could not save: %@", String(describing: error))
                Gtk.onMain { [weak self] in self?.toast(text) }
            }
        }
    }

    func save(
        _ profile: ConnectionProfile, keepingPasswordOf previous: ConnectionProfile, toast: String
    ) {
        expandAfterReload = profile.id
        Task { [weak self] in
            let password = await ServerDirectory.shared.password(for: previous)
            do {
                try await ServerDirectory.shared.save(profile, password: password)
                self?.onChanged()
                Gtk.onMain { [weak self] in
                    self?.toast(toast)
                    self?.reload()
                }
            } catch {
                let text = Localized.text("Could not save: %@", String(describing: error))
                Gtk.onMain { [weak self] in self?.toast(text) }
            }
        }
    }

    /// The press states its cost first, then hands the ask over and stops: the connection it went
    /// over dies with the process it restarted, so the reconnect every pane already watches is what
    /// says the machine is back. A machine set up by hand refuses the restart, and the refusal is
    /// the offer: the setup that makes it restartable is one press, not a terminal instruction.
    func confirmRestart(id: String, name: String) {
        guard let window else { return }
        Dialogs.confirm(
            title: ServerRestart.confirmTitle(name),
            body: ServerRestart.confirmBody(workingTurns: 0),
            confirmLabel: ServerRestart.action, parent: window
        ) { [weak self] in
            Task { [weak self] in
                guard let profile = await ServerDirectory.shared.profiles().first(where: { $0.id == id }),
                    let restartable = await ServerDirectory.shared.backend(for: profile)
                        as? any RestartableBackend
                else { return }
                do {
                    try await restartable.restart()
                    Gtk.onMain { [weak self] in
                        self?.toast(Localized.text("%@ is restarting.", name))
                    }
                } catch {
                    self?.offerSetup(name: name, backend: restartable)
                }
            }
        }
    }

    func offerSetup(name: String, backend: any CodingAgentBackend) {
        guard let window else { return }
        guard let settable = backend as? any ServeManagerBackend else {
            Gtk.onMain { [weak self] in
                self?.toast(ServerRestart.refused(name))
            }
            return
        }
        Dialogs.confirm(
            title: ServerRestart.setupTitle,
            body: ServerRestart.setupDetail,
            confirmLabel: ServerRestart.setupAction, parent: window
        ) { [weak self] in
            Task { [weak self] in
                do {
                    try await settable.installServeManager()
                    Gtk.onMain { [weak self] in
                        self?.toast(Localized.text("%@ is restarting with its new setup.", name))
                    }
                } catch {
                    Gtk.onMain { [weak self] in
                        self?.toast(ServerRestart.setupFailedDetail)
                    }
                }
            }
        }
    }

    func confirmRemove(id: String, name: String) {
        guard let window else { return }
        Dialogs.confirm(
            title: Localized.text("Remove %@?", name),
            body: Localized.text(
                "The saved address and password go away. Conversations stay on the server."),
            confirmLabel: Localized.text("Remove"), parent: window
        ) { [weak self] in
            Task { [weak self] in
                await ServerDirectory.shared.delete(id: id)
                self?.onChanged()
                Gtk.onMain { [weak self] in
                    self?.toast(Localized.text("%@ removed.", name))
                    self?.reload()
                }
            }
        }
    }

    func probeAndSave() {
        guard !probing, let addressRow, let nameRow, let passwordRow else { return }
        let raw = Dialogs.entryText(addressRow)
        let label = Dialogs.entryText(nameRow)
        var password = Self.secretText(passwordRow)
        if password.isEmpty, let pasted = BridgeInstall.password(in: raw) {
            password = pasted
            gtk_editable_set_text(op(passwordRow), pasted)
        }
        let backend: AgentType = selectedBackend

        guard !raw.isEmpty else {
            setStatus(
                Localized.text("Nothing typed yet"),
                detail: Localized.text(
                    "Paste the machine's tailnet address — 100.x.y.z, a MagicDNS name, or the whole line the server printed when it started."
                ), tone: .warn)
            return
        }
        let reading = HostAddress.read(raw, defaultPort: HostAddress.port(for: backend))
        guard case .address(let address) = reading else {
            setStatus(
                Localized.text("That doesn't read as an address"),
                detail: Self.explain(reading, raw: raw), tone: .bad)
            return
        }

        let secret = password.isEmpty ? nil : password
        setProbing(true)
        setStatus(
            Localized.text("Probing %@…", address.displayHost),
            detail: Localized.text("Trying every port worth trying before saving anything."))
        Task { [weak self] in
            let tailnet = await Self.tailnet.address()
            let found = await Self.within(25) {
                await ProbeSweep.best(
                    address: address, password: secret, preferring: backend)
            }
            guard let verdict = found else {
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.setProbing(false)
                    self.setStatus(
                        Localized.text("%@ did not answer in time", address.displayHost),
                        detail: Localized.text(
                            "Twenty-five seconds and nothing came back. The machine may be asleep, or the agent may be busy with a turn — try again in a moment."
                        ), tone: .bad,
                        actions: [
                            Self.inlineButton(Localized.text("Try again")) { [weak self] in
                                self?.probeAndSave()
                            }
                        ])
                }
                return
            }
            if case .ok(let agent, _) = verdict.outcome {
                let profile = ConnectionProfile(
                    id: UUID().uuidString,
                    name: label.isEmpty ? address.displayHost : label,
                    backend: agent,
                    baseURL: verdict.url,
                    username: ProbeSweep.username(for: agent))
                do {
                    try await ServerDirectory.shared.save(profile, password: secret)
                    self?.onChanged()
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.setProbing(false)
                        self.clearAddForm()
                        self.setStatus("")
                        self.toast(
                            Localized.text(
                                "Saved %@ — %@ answered.", profile.name,
                                ServerLabel.agent(agent)))
                        self.reload()
                    }
                } catch {
                    let text = Localized.text("Could not save: %@", String(describing: error))
                    Gtk.onMain { [weak self] in
                        self?.setProbing(false)
                        self?.setStatus(
                            Localized.text("%@ answered, but it could not be saved", address.displayHost),
                            detail: text, tone: .bad)
                    }
                }
                return
            }
            let diagnosis = await Self.diagnose(
                outcome: verdict.outcome, address: address, tailnetAddress: tailnet,
                sentPassword: secret != nil)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.setProbing(false)
                guard let diagnosis else {
                    self.setStatus(
                        Localized.text("No answer from %@", address.displayHost), tone: .bad)
                    return
                }
                self.setStatus(
                    diagnosis.title, detail: diagnosis.detail, tone: .bad,
                    actions: self.buttons(for: diagnosis, profileID: nil))
            }
        }
    }

    static let addFormBackends: [AgentType] = [.claudeCode, .openCode, .omp]

    var selectedBackend: AgentType {
        guard let agentRow else { return .claudeCode }
        let index = adw_combo_row_get_selected(ptr(UnsafeMutableRawPointer(agentRow)))
        return Self.addFormBackends[Int(index)]
    }

    func clearAddForm() {
        if let addressRow { gtk_editable_set_text(op(addressRow), "") }
        if let nameRow { gtk_editable_set_text(op(nameRow), "") }
        if let passwordRow { gtk_editable_set_text(op(passwordRow), "") }
    }

    func setProbing(_ value: Bool) {
        probing = value
        guard let probeButton else { return }
        gtk_widget_set_sensitive(probeButton, value ? 0 : 1)
        gtk_button_set_label(
            ptr(probeButton),
            value ? Localized.text("Probing…") : Localized.text("Probe and save"))
    }

    /// What the add form is doing, or what it found, as a row of the same shape every server fact
    /// wears here — headline, sentence, and the one button worth pressing about it.
    func setStatus(
        _ headline: String, detail: String = "", tone: Tone = .quiet,
        actions: [UnsafeMutablePointer<GtkWidget>] = []
    ) {
        guard let statusRow else { return }
        adw_preferences_row_set_title(ptr(statusRow), headline)
        setFact(statusRow, statusActions, detail, tone: tone, actions: actions)
        gtk_widget_set_visible(statusRow, headline.isEmpty ? 0 : 1)
    }

    static func explain(_ reading: HostAddress.Reading, raw: String) -> String {
        switch reading {
        case .empty:
            return Localized.text("Type the server's tailnet address first.")
        case .bindAll:
            return Localized.text(
                "0.0.0.0 is what a server binds to, never where it lives — use the machine's 100.x tailnet address."
            )
        case .unsupportedScheme(let scheme):
            return Localized.text("%@:// is not something this app can speak.", scheme)
        case .invalid, .address:
            return Localized.text("“%@” does not read as an address.", raw)
        }
    }

    /// Nothing on this screen may wait forever. A machine that is merely busy answers late, and a
    /// bridge in the middle of a turn may not answer at all until it finishes — so every ask is
    /// raced against a deadline and reports that it gave up, rather than leaving a row reading
    /// "checking…" for as long as the window is open.
    static func within<T: Sendable>(
        _ seconds: Int, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The named cause of a failed probe, and the one action worth offering for it. Takes this
    /// machine's tailnet address rather than reading the property, because it runs off the main
    /// context and the window that holds that reading lives on it.
    /// What let this machine in, in the server's own words — the reason a row that never asked
    /// for a password is not an unprotected one. Nil for a server that does not say.
    static func access(of profile: ConnectionProfile) async -> String? {
        guard let backend = await ServerDirectory.shared.backend(for: profile) else { return nil }
        let health = await within(10) { try? await backend.health() }
        return ServerAccessReading.line(health?.access)
    }

    static func diagnose(
        outcome: ConnectionProbe.Outcome, address: HostAddress, tailnetAddress: String?,
        sentPassword: Bool
    ) async -> ConnectDiagnosis? {
        var reachability: PortReachability.Verdict?
        if let host = address.url.host, let port = address.url.port {
            reachability = await PortReachability.check(host: host, port: UInt16(port))
        }
        return ConnectDiagnosis.make(
            outcome: outcome, address: address, tailnetAddress: tailnetAddress,
            alternatePort: otherAgentPort(for: address.url),
            sentPassword: sentPassword, reachability: reachability,
            deviceName: Localized.text("This machine"))
    }

    /// The same address on the other agent's port — the single most likely correction when
    /// something answered but not as the agent this profile expects.
    static func otherAgentPort(for url: URL) -> URL? {
        guard let port = url.port else { return nil }
        let alternate: Int
        switch port {
        case HostAddress.openCodePort: alternate = HostAddress.claudeCodePort
        case HostAddress.claudeCodePort: alternate = HostAddress.ompPort
        case HostAddress.ompPort: alternate = HostAddress.openCodePort
        default: return nil
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.port = alternate
        return components.url
    }
}
