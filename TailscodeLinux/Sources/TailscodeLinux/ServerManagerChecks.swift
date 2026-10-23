import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ServerManager {
    /// A configured server's own probe, run with the password it was saved with. It answers the
    /// two questions the row asks — is anything there, and what is it — and when the answer is no,
    /// it is the same named diagnosis the add form gives, with the same one action that fixes it.
    func checkHealth(_ profile: ConnectionProfile) {
        guard let slots = rows[profile.id] else { return }
        if profile.id.hasPrefix(DemoWorld.profilePrefix) {
            setFact(
                slots.health, slots.healthActions,
                Localized.text("A scripted world on this machine — nothing to reach."),
                tone: .quiet, actions: [], title: Localized.text("Connection"))
            setGlyph(slots, "◍", css: "glyph-pending")
            return
        }
        setFact(
            slots.health, slots.healthActions, Localized.text("Checking…"), tone: .quiet,
            actions: [], title: Localized.text("Connection"))
        setGlyph(slots, "○", css: "glyph-pending")
        let id = profile.id
        Task { [weak self] in
            let tailnet = await Self.tailnet.address()
            let password = await ServerDirectory.shared.password(for: profile)
            let address = HostAddress(url: profile.baseURL, portWasInferred: false)
            let found = await Self.within(15) {
                await ProbeSweep.best(
                    address: address, password: password, preferring: profile.backend,
                    retryUnreachable: false)
            }
            guard let verdict = found else {
                Gtk.onMain { [weak self] in
                    guard let self, let slots = self.rows[id] else { return }
                    self.setFact(
                        slots.health, slots.healthActions,
                        Localized.text(
                            "Fifteen seconds and nothing came back — asleep, or busy with a turn."),
                        tone: .bad, actions: [], title: Localized.text("No answer in time"))
                    self.setGlyph(slots, "✕", css: "glyph-error")
                }
                return
            }
            if case .ok(let agent, _) = verdict.outcome {
                let mismatched = agent != profile.backend
                let answering = mismatched
                    ? Localized.text(
                        "Answering as %@, but this profile is saved as %@ — remove it and add it again.",
                        ServerLabel.agent(agent), ServerLabel.agent(profile.backend))
                    : Localized.text(
                        "Answering · %@ on %@", ServerLabel.agent(agent), address.displayHost)
                let access = mismatched ? nil : await Self.access(of: profile)
                let text = access.map { answering + "\n" + $0 } ?? answering
                Gtk.onMain { [weak self] in
                    guard let self, let slots = self.rows[id] else { return }
                    self.setFact(
                        slots.health, slots.healthActions, text, tone: mismatched ? .warn : .good,
                        actions: [], title: Localized.text("Connection"))
                    self.setGlyph(slots, "●", css: mismatched ? "glyph-needs" : "glyph-done")
                }
                return
            }
            let diagnosis = await Self.diagnose(
                outcome: verdict.outcome, address: address, tailnetAddress: tailnet,
                sentPassword: password?.isEmpty == false)
            Gtk.onMain { [weak self] in
                guard let self, let slots = self.rows[id] else { return }
                guard let diagnosis else {
                    self.setFact(
                        slots.health, slots.healthActions,
                        Localized.text("Nothing came back from %@.", address.displayHost),
                        tone: .bad, actions: [], title: Localized.text("No answer"))
                    self.setGlyph(slots, "✕", css: "glyph-error")
                    return
                }
                self.setFact(
                    slots.health, slots.healthActions, diagnosis.detail, tone: .bad,
                    actions: self.buttons(for: diagnosis, profileID: id),
                    title: diagnosis.title)
                self.setGlyph(slots, "✕", css: "glyph-error")
            }
        }
    }

    /// Which account this server's Claude answers as — or the warning that it answers as nobody,
    /// with the one button that fixes it from here rather than a sentence about a terminal.
    func checkAccount(_ profile: ConnectionProfile) {
        guard let slots = rows[profile.id] else { return }
        setFact(
            slots.account, slots.accountActions, Localized.text("Asking…"), tone: .quiet,
            actions: [])
        let id = profile.id
        Task { [weak self] in
            guard
                let backend = await ServerDirectory.shared.backend(for: profile)
                    as? any AuthenticatingBackend
            else { return }
            guard let auth = await Self.within(15, { try? await backend.authStatus() }) else {
                Gtk.onMain { [weak self] in
                    guard let self, let slots = self.rows[id] else { return }
                    self.setFact(
                        slots.account, slots.accountActions,
                        Localized.text("The server didn't say."), tone: .quiet, actions: [])
                }
                return
            }
            Gtk.onMain { [weak self] in
                self?.renderAccount(auth, profile: profile, backend: backend)
            }
        }
    }

    func renderAccount(
        _ auth: ServerAuth, profile: ConnectionProfile, backend: any AuthenticatingBackend
    ) {
        guard let slots = rows[profile.id] else { return }
        guard !auth.loggedIn else {
            var line = auth.accountLabel ?? Localized.text("Signed in")
            if let subscription = auth.subscription, !subscription.isEmpty {
                line += " · \(subscription)"
            }
            setFact(slots.account, slots.accountActions, line, tone: .good, actions: [])
            return
        }
        setFact(
            slots.account, slots.accountActions,
            Localized.text("Signed out — every turn will refuse until it signs in."), tone: .bad,
            actions: [
                Self.inlineButton(Localized.text("Sign in"), css: ["suggested-action"]) {
                    [weak self] in
                    guard let self, let window = self.window else { return }
                    SignInDialog.present(
                        parent: window, serverName: profile.name, backend: backend
                    ) { [weak self] in
                        Gtk.onMain { [weak self] in self?.checkAccount(profile) }
                    }
                }
            ])
    }

    /// Whether the Mac this server runs on has given its agents Full Disk Access — read without
    /// ever raising a prompt, so a Linux desktop across the room can watch the checklist without
    /// waking anything on the Mac.
    func checkPermissions(_ profile: ConnectionProfile) {
        let id = profile.id
        Task { [weak self] in
            guard
                let backend = await ServerDirectory.shared.backend(for: profile)
                    as? any PermissionReportingBackend
            else { return }
            guard
                let permissions = await Self.within(15, { try? await backend.machinePermissions() })
            else { return }
            Gtk.onMain { [weak self] in self?.renderPermissions(permissions, profileID: id) }
        }
    }

    func renderPermissions(_ permissions: MachinePermissions, profileID: String) {
        guard let slots = rows[profileID], let wrapper = slots.permissionsWrapper,
            let box = slots.permissionsBox
        else { return }
        guard MachinePermissionReading.isShown(permissions) else {
            gtk_widget_set_visible(wrapper, 0)
            return
        }
        box.apply(permissions)
        gtk_widget_set_visible(wrapper, 1)
        schedulePermissionPoll(profileID: profileID, waiting: MachinePermissionReading.isWaiting(permissions))
    }

    /// The press: asks the Mac to open its own System Settings pane, then reads the grant back —
    /// the switch itself is always the person's, on whichever screen they are holding.
    func requestPermission(_ kind: MachinePermissions.Grant.Kind, profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        Task { [weak self] in
            guard
                let backend = await ServerDirectory.shared.backend(for: profile)
                    as? any PermissionReportingBackend
            else { return }
            guard
                let permissions = await Self.within(
                    15, { try? await backend.requestMachinePermission(kind) })
            else {
                Gtk.onMain { [weak self] in self?.rows[profileID]?.permissionsBox?.showRequestFailed() }
                return
            }
            Gtk.onMain { [weak self] in self?.renderPermissions(permissions, profileID: profileID) }
        }
    }

    /// The steps stay on screen until the switch is noticed, so this asks again every
    /// `MachinePermissionReading.pollInterval` while it is waiting on one — and stops the moment
    /// the row is gone, rather than polling a window nobody has open.
    func schedulePermissionPoll(profileID: String, waiting: Bool) {
        guard waiting, let slots = rows[profileID], !slots.permissionPollPending else { return }
        slots.permissionPollPending = true
        Gtk.after(Gtk.milliseconds(MachinePermissionReading.pollInterval)) { [weak self] in
            self?.rows[profileID]?.permissionPollPending = false
            guard let self, self.window != nil, self.rows[profileID] != nil,
                let profile = self.profiles.first(where: { $0.id == profileID })
            else { return }
            self.checkPermissions(profile)
        }
    }

    /// Everything a row can find out, asked again — the refresh button in its header, and what a
    /// failed probe's "try again" lands on.
    func recheck(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        checkHealth(profile)
        if !profile.id.hasPrefix(DemoWorld.profilePrefix) {
            UpdateWatch.recheck(.server(profileID: profile.id))
        }
        if profile.backend == .claudeCode, !profile.id.hasPrefix(DemoWorld.profilePrefix) {
            checkAccount(profile)
            checkPermissions(profile)
        }
    }

    func buttons(for diagnosis: ConnectDiagnosis, profileID: String?)
        -> [UnsafeMutablePointer<GtkWidget>]
    {
        switch diagnosis.fix {
        case .retry:
            return [
                Self.inlineButton(diagnosis.actionTitle ?? Localized.text("Try again")) {
                    [weak self] in
                    self?.retry(profileID: profileID)
                }
            ]
        case .retryOtherPort(let url), .usePlainHTTP(let url):
            return [
                Self.inlineButton(diagnosis.actionTitle ?? Localized.text("Try again")) {
                    [weak self] in
                    self?.retry(profileID: profileID, at: url)
                }
            ]
        case .openTailscale:
            return [
                Self.inlineButton(diagnosis.actionTitle ?? Localized.text("Open Tailscale")) {
                    [weak self] in
                    self?.openTailscale()
                }
            ]
        case .copyCommand(let command):
            return [
                Self.inlineButton(diagnosis.actionTitle ?? Localized.text("Copy")) {
                    [weak self] in
                    Gtk.copyToClipboard(command)
                    self?.toast(Localized.text("Copied — run it in a terminal."))
                }
            ]
        case .none, .openAppSettings, .revealPassword, .seePro:
            return []
        }
    }

    /// The machine is added from the first-run checklist, which is where the link way, the install
    /// command and the tailnet scan live; a machine saved there lands back in this list.
    func addMachine() {
        FirstRunDialog.present(way: nil, parent: window) { [weak self] in
            self?.onChanged()
            Gtk.onMain { [weak self] in self?.reload() }
        }
    }

    /// The remedy this machine's own Tailscale reading offers, run here with what it prints told in
    /// a toast — never "run it in a terminal". A reading that has no remedy because Tailscale is
    /// up (a refusal that names the tailnet) goes to the page where the account is chosen.
    func openTailscale() {
        let latch = FirstSay()
        Task.detached { [weak self] in
            let reading = TailnetStatusLinux.read().reading
            Gtk.onMain { [weak self] in
                guard let self else { return }
                let handled = TailnetRemedyRunner.perform(reading) { text in
                    guard latch.first() else { return }
                    Gtk.onMain { self.toast(text) }
                }
                if !handled { SignInDialog.openInBrowser(Self.tailnetPage) }
            }
        }
    }

    static let tailnetPage = "https://login.tailscale.com/admin/machines"

    final class FirstSay: @unchecked Sendable {
        private let lock = NSLock()
        private var said = false

        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !said else { return false }
            said = true
            return true
        }
    }

    func retry(profileID: String?, at url: URL? = nil) {
        guard let profileID else {
            if let url, let addressRow {
                gtk_editable_set_text(op(addressRow), url.absoluteString)
            }
            probeAndSave()
            return
        }
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard let url else {
            recheck(profile.id)
            return
        }
        save(
            ConnectionProfile(
                id: profile.id, name: profile.name, backend: profile.backend, baseURL: url,
                username: profile.username),
            keepingPasswordOf: profile,
            toast: Localized.text("%@ now points at %@", profile.name, url.absoluteString))
    }

    func readTailnetAddress() {
        Task { [weak self] in
            let address = await Self.tailnet.address()
            Gtk.onMain { [weak self] in
                guard let group = self?.addGroup else { return }
                adw_preferences_group_set_description(
                    ptr(group),
                    address.map { Localized.text("This machine is %@ on your tailnet.", $0) }
                        ?? Localized.text(
                            "Tailscale isn't reporting an address here — nothing will answer until it is connected."
                        ))
            }
        }
    }

    /// One reading of this machine's tailnet address, shared by every probe on the screen.
    /// `ConnectDiagnosis` reads a missing address as "this machine isn't on your tailnet", which
    /// is the wrong sentence to put under a server that is merely on the wrong port — so a probe
    /// waits for the reading rather than racing it and inheriting the nil.
    actor Tailnet {
        private var reading: Task<String?, Never>?

        func address() async -> String? {
            if let reading { return await reading.value }
            let made = Task.detached { TailnetStatusLinux.read().address }
            reading = made
            return await made.value
        }
    }

    static let tailnet = Tailnet()
}
