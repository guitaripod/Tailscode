import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The servers this machine knows, editable in place, in the desktop's own furniture: a
/// preferences window whose configured group holds one expander per machine — what it is, whether
/// it is answering, which software it runs, which account its Claude is signed into, and the three
/// fields that define it, all editable without removing and re-adding the row.
///
/// A window presented from a local variable is a window whose buttons do nothing: GTK owns the
/// widgets, nothing owns the Swift object behind them, and every `[weak self]` handler wakes up
/// holding nil. This one holds itself for exactly as long as its window is open, and lets go on
/// `close-request`.
///
/// Adding a server probes it before saving — a typo fails here, named, rather than becoming a row
/// that never loads — and the failure is the shared `ConnectDiagnosis`, so the address that didn't
/// parse, the port that answered as something else and the password that was refused each read the
/// same on this desk as on the phone, and each offers the one action that fixes it.
final class ServerManager: @unchecked Sendable {
    static let installCommand = BridgeInstall.installCommand

    private let onChanged: @Sendable () -> Void
    private var token: UInt = 0
    private var window: UnsafeMutablePointer<GtkWidget>?
    private var configuredGroup: UnsafeMutablePointer<GtkWidget>?
    private var addGroup: UnsafeMutablePointer<GtkWidget>?
    private var discovery: DiscoveryPanel?
    private var configuredRows: [UnsafeMutablePointer<GtkWidget>] = []
    private var rows: [String: ServerRow] = [:]

    private var addressRow: UnsafeMutablePointer<GtkWidget>?
    private var nameRow: UnsafeMutablePointer<GtkWidget>?
    private var passwordRow: UnsafeMutablePointer<GtkWidget>?
    private var agentRow: UnsafeMutablePointer<GtkWidget>?
    private var probeButton: UnsafeMutablePointer<GtkWidget>?
    private var statusRow: UnsafeMutablePointer<GtkWidget>?
    private var statusActions: UnsafeMutablePointer<GtkWidget>?
    private var probing = false
    /// The row a save came from, re-opened when the list redraws — an edit applied inside an
    /// expander should leave the reader where they were, not collapsed back to the top.
    private var expandAfterReload: String?
    private var profiles: [ConnectionProfile] = []

    init(onChanged: @escaping @Sendable () -> Void) {
        self.onChanged = onChanged
    }

    func present(parent: UnsafeMutablePointer<GtkWidget>?) {
        if let window {
            gtk_window_present(ptr(window))
            return
        }
        let window = adw_preferences_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Servers"))
        gtk_window_set_default_size(ptr(window), 640, 780)
        gtk_window_set_modal(ptr(window), 0)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        self.window = window

        let page = adw_preferences_page_new()!
        adw_preferences_window_add(ptr(window), ptr(page))
        configuredGroup = makeConfiguredGroup(on: page)
        let discovery = DiscoveryPanel(
            onAdd: { [weak self] suggestion in
                Gtk.onMain { [weak self] in self?.adopt(suggestion) }
            },
            onChanged: { [weak self] in
                Gtk.onMain { [weak self] in self?.toast(Localized.text("Install command copied")) }
            })
        self.discovery = discovery
        adw_preferences_page_add(ptr(page), ptr(discovery.group))
        addGroup = makeAddGroup(on: page)

        token = Self.hold(self)
        let token = self.token
        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") { Self.release(token) }

        reload()
        readTailnetAddress()
        gtk_window_present(ptr(window))
    }


    private func makeConfiguredGroup(on page: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(ptr(group), Localized.text("Configured"))
        adw_preferences_page_add(ptr(page), ptr(group))
        return group
    }

    private func makeAddGroup(on page: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(ptr(group), Localized.text("Add a server"))
        adw_preferences_group_set_description(
            ptr(group), Localized.text("Reading this machine's tailnet address…"))
        adw_preferences_page_add(ptr(page), ptr(group))

        let address = Self.entryRow(
            title: Localized.text("Tailnet address"),
            tooltip: Localized.text("100.x.y.z, name.tailnet.ts.net, host:port — or a whole line pasted out of the server's terminal"))
        addressRow = address
        adw_preferences_group_add(ptr(group), ptr(address))

        let name = Self.entryRow(title: Localized.text("Name (optional)"), tooltip: nil)
        nameRow = name
        adw_preferences_group_add(ptr(group), ptr(name))

        let password = Self.passwordRow(title: Localized.text("Password"))
        gtk_widget_set_tooltip_text(
            password,
            Localized.text("Only if the server asks for one — claude-bridge's BRIDGE_PASSWORD."))
        passwordRow = password
        adw_preferences_group_add(ptr(group), ptr(password))

        for row in [address, name, password] {
            Gtk.connect(UnsafeMutableRawPointer(row), "entry-activated") { [weak self] in
                self?.probeAndSave()
            }
        }

        let agent = adw_combo_row_new()!
        adw_preferences_row_set_title(ptr(agent), Localized.text("Agent"))
        adw_preferences_row_set_use_markup(ptr(agent), 0)
        adw_action_row_set_subtitle(
            ptr(agent),
            Localized.text("Both ports are tried anyway when you don't name one."))
        let model = gtk_string_list_new(nil)!
        gtk_string_list_append(model, "claude-bridge · 4098")
        gtk_string_list_append(model, "opencode · 4096")
        adw_combo_row_set_model(
            ptr(UnsafeMutableRawPointer(agent)),
            OpaquePointer(UnsafeMutableRawPointer(model)))
        adw_combo_row_set_selected(ptr(UnsafeMutableRawPointer(agent)), 0)
        agentRow = agent
        adw_preferences_group_add(ptr(group), ptr(agent))

        let (status, statusActions) = Self.factRow(title: "")
        gtk_widget_set_visible(status, 0)
        statusRow = status
        self.statusActions = statusActions
        adw_preferences_group_add(ptr(group), ptr(status))

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        Gtk.margins(buttons, top: 6)
        let probe = Gtk.button(
            Localized.text("Probe and save"), css: ["suggested-action", "pill"]
        ) { [weak self] in
            self?.probeAndSave()
        }
        probeButton = probe
        gtk_box_append(ptr(buttons), probe)
        adw_preferences_group_add(ptr(group), ptr(buttons))
        return group
    }


    private func reload() {
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            Gtk.onMain { [weak self] in self?.render(profiles) }
        }
    }

    private func render(_ profiles: [ConnectionProfile]) {
        guard let group = configuredGroup else { return }
        for row in configuredRows { adw_preferences_group_remove(ptr(group), ptr(row)) }
        configuredRows = []
        rows = [:]
        self.profiles = profiles

        let expanding = expandAfterReload
        expandAfterReload = nil
        adw_preferences_group_set_description(
            ptr(group),
            profiles.isEmpty
                ? Localized.text("No machines yet. Add the one running your agent below.")
                : Localized.text("%@ machines. Open one to check it, update it, or change it.",
                    "\(profiles.count)"))

        guard !profiles.isEmpty else {
            discovery?.setConfigured([])
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(ptr(row), Localized.text("Nothing configured"))
            adw_preferences_row_set_use_markup(ptr(row), 0)
            adw_action_row_set_subtitle(
                ptr(row),
                Localized.text(
                    "Run the install command on the machine you code on, then paste its address below."
                ))
            adw_action_row_set_subtitle_lines(ptr(row), 0)
            adw_action_row_add_suffix(
                ptr(row),
                Self.inlineButton(Localized.text("Copy the install command")) { [weak self] in
                    Gtk.copyToClipboard(Self.installCommand)
                    self?.toast(Localized.text("Install command copied"))
                })
            adw_preferences_group_add(ptr(group), ptr(row))
            configuredRows.append(row)
            return
        }

        discovery?.setConfigured(profiles)
        for profile in profiles {
            let row = makeRow(profile)
            if profile.id == expanding { adw_expander_row_set_expanded(ptr(row), 1) }
            adw_preferences_group_add(ptr(group), ptr(row))
            configuredRows.append(row)
        }
    }

    private func makeRow(_ profile: ConnectionProfile) -> UnsafeMutablePointer<GtkWidget> {
        let slots = ServerRow()
        rows[profile.id] = slots

        let row = adw_expander_row_new()!
        adw_preferences_row_set_title(ptr(row), profile.name)
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_expander_row_set_subtitle(
            ptr(row), "\(ServerLabel.agent(profile.backend)) · \(ServerLabel.address(profile))")

        let glyph = Gtk.label("○", css: "glyph-pending", selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        slots.glyph = glyph
        adw_expander_row_add_prefix(ptr(row), glyph)

        let refresh = gtk_button_new_from_icon_name("view-refresh-symbolic")!
        Gtk.addClass(refresh, "flat")
        gtk_widget_set_valign(refresh, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(refresh, Localized.text("Ask this machine again"))
        let refreshID = profile.id
        Gtk.connect(UnsafeMutableRawPointer(refresh), "clicked") { [weak self] in
            self?.recheck(refreshID)
        }
        adw_expander_row_add_suffix(ptr(row), refresh)

        let (health, healthActions) = Self.factRow(title: Localized.text("Connection"))
        slots.health = health
        slots.healthActions = healthActions
        adw_expander_row_add_row(ptr(row), health)

        let isDemo = profile.id.hasPrefix(DemoWorld.profilePrefix)
        let isEnvironment = profile.id == "environment"

        if profile.backend == .claudeCode && !isDemo {
            let (software, softwareActions) = Self.factRow(title: Localized.text("Software"))
            slots.software = software
            slots.softwareActions = softwareActions
            adw_expander_row_add_row(ptr(row), software)

            let (account, accountActions) = Self.factRow(title: Localized.text("Claude account"))
            slots.account = account
            slots.accountActions = accountActions
            adw_expander_row_add_row(ptr(row), account)
        }

        if isDemo || isEnvironment {
            let note = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(note), 0)
            adw_preferences_row_set_title(
                ptr(note),
                isDemo ? Localized.text("Demo world") : Localized.text("Set by the environment"))
            adw_action_row_set_subtitle(
                ptr(note),
                isDemo
                    ? Localized.text("Nothing here reaches a machine. Leave it to add a real one.")
                    : Localized.text(
                        "TAILSCODE_HOST defines this one, so it can't be edited or removed here."))
            adw_action_row_set_subtitle_lines(ptr(note), 0)
            adw_expander_row_add_row(ptr(row), note)
        } else {
            let address = Self.entryRow(title: Localized.text("Address"), tooltip: nil)
            gtk_editable_set_text(op(address), Self.editableAddress(profile))
            adw_entry_row_set_show_apply_button(ptr(address), 1)
            slots.address = address
            let id = profile.id
            Gtk.connect(UnsafeMutableRawPointer(address), "apply") { [weak self] in
                self?.applyAddress(id)
            }
            adw_expander_row_add_row(ptr(row), address)

            let name = Self.entryRow(title: Localized.text("Name"), tooltip: nil)
            gtk_editable_set_text(op(name), profile.name)
            adw_entry_row_set_show_apply_button(ptr(name), 1)
            slots.name = name
            Gtk.connect(UnsafeMutableRawPointer(name), "apply") { [weak self] in
                self?.applyName(id)
            }
            adw_expander_row_add_row(ptr(row), name)

            let password = Self.passwordRow(title: Localized.text("Password"))
            gtk_widget_set_tooltip_text(
                password,
                Localized.text(
                    "A stored password is never shown. Type a new one to replace it, or apply an empty field to connect without one."
                ))
            adw_entry_row_set_show_apply_button(ptr(password), 1)
            slots.password = password
            Gtk.connect(UnsafeMutableRawPointer(password), "apply") { [weak self] in
                self?.applyPassword(id)
            }
            adw_expander_row_add_row(ptr(row), password)
        }

        if !isEnvironment {
            let remove = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(remove), 0)
            adw_preferences_row_set_title(
                ptr(remove),
                isDemo ? Localized.text("Leave the demo") : Localized.text("Remove this server"))
            adw_action_row_set_subtitle(
                ptr(remove),
                Localized.text("Conversations stay on the machine — only this app forgets it."))
            adw_action_row_set_subtitle_lines(ptr(remove), 0)
            let id = profile.id
            let name = profile.name
            adw_action_row_add_suffix(
                ptr(remove),
                Self.inlineButton(Localized.text("Remove"), css: ["destructive-action"]) {
                    [weak self] in
                    self?.confirmRemove(id: id, name: name)
                })
            adw_expander_row_add_row(ptr(row), remove)
        }

        checkHealth(profile)
        if profile.backend == .claudeCode && !isDemo {
            checkSoftware(profile)
            checkAccount(profile)
        }
        return row
    }


    /// A configured server's own probe, run with the password it was saved with. It answers the
    /// two questions the row asks — is anything there, and what is it — and when the answer is no,
    /// it is the same named diagnosis the add form gives, with the same one action that fixes it.
    private func checkHealth(_ profile: ConnectionProfile) {
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
                let text = mismatched
                    ? Localized.text(
                        "Answering as %@, but this profile is saved as %@ — remove it and add it again.",
                        ServerLabel.agent(agent), ServerLabel.agent(profile.backend))
                    : Localized.text(
                        "Answering · %@ on %@", ServerLabel.agent(agent), address.displayHost)
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

    /// What this machine is running, asked through the same road the update centre uses — so the
    /// answer is written into ``UpdateLedger`` on the way past and the two screens cannot end up
    /// telling the person different things about the same server.
    private func checkSoftware(_ profile: ConnectionProfile) {
        guard let slots = rows[profile.id] else { return }
        setFact(
            slots.software, slots.softwareActions, Localized.text("Checking for updates…"),
            tone: .quiet, actions: [])
        let id = profile.id
        Task { [weak self] in
            let reading = await UpdateWatch.ask(profile, checkingRemote: true)
            Gtk.onMain { [weak self] in self?.renderSoftware(reading, profileID: id) }
        }
    }

    /// One `UpdateReading`, drawn. There is no decision left to make here: whether a server is
    /// current, too old for the route, unreachable, built but not restarted, or unable to update
    /// itself is Core's judgement, and a client that re-derived it from the same fields would
    /// eventually derive it differently.
    private func renderSoftware(_ reading: UpdateReading, profileID: String) {
        guard let slots = rows[profileID] else { return }
        var lines = [reading.headline, reading.detail()]
        let changes = reading.verdict.offer?.changes ?? []
        if !changes.isEmpty {
            lines.append(changes.prefix(5).map { "· \($0)" }.joined(separator: "\n"))
        }
        setFact(
            slots.software, slots.softwareActions, lines.joined(separator: "\n"),
            tone: Self.tone(for: reading),
            actions: softwareActions(for: reading, profileID: profileID))
    }

    private static func tone(for reading: UpdateReading) -> Tone {
        switch reading.verdict {
        case .current: return .good
        case .behind(let offer): return offer.canInstallHere ? .warn : .quiet
        case .failed: return .bad
        case .ahead, .working, .blocked, .unverified: return .quiet
        }
    }

    /// The one press the reading earned, and nothing else. `installHere` is the only one that ends
    /// on this machine; everything else says outright that it hands the job somewhere else.
    private func softwareActions(for reading: UpdateReading, profileID: String)
        -> [UnsafeMutablePointer<GtkWidget>]
    {
        guard let invitation = reading.invitation else { return [] }
        switch invitation {
        case .installHere:
            return [
                Self.inlineButton(invitation.label, css: ["suggested-action"]) { [weak self] in
                    self?.runUpdate(profileID: profileID)
                }
            ]
        case .copyCommand(let command):
            return [
                Self.inlineButton(invitation.label) { [weak self] in
                    Gtk.copyToClipboard(command)
                    self?.toast(Localized.text("Install command copied"))
                }
            ]
        case .recheck:
            return [
                Self.inlineButton(invitation.label) { [weak self] in
                    guard let self,
                        let profile = self.profiles.first(where: { $0.id == profileID })
                    else { return }
                    self.checkSoftware(profile)
                }
            ]
        case .openStore(let url), .openPage(let url):
            return [Self.inlineButton(invitation.label) { SignInDialog.openInBrowser(url) }]
        }
    }

    /// The update is followed to the end, not to the first heartbeat: the old process keeps
    /// answering `/health` through the whole fetch and build, so a refused connection is the restart
    /// doing its job. ``UpdateWatch`` owns that walk, and this row is one of the things it reports
    /// to — the update centre's own row updates from the same answers at the same moment.
    private func runUpdate(profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }),
            let slots = rows[profileID]
        else { return }
        setFact(
            slots.software, slots.softwareActions,
            Localized.text("Updating — asking the server to fetch and build…"), tone: .quiet,
            actions: [])
        UpdateWatch.updateServer(profile) { [weak self] reading in
            guard let self else { return }
            self.renderSoftware(reading, profileID: profileID)
            guard !reading.verdict.isBusy else { return }
            self.toast(Localized.text("%@ · %@", profile.name, reading.headline))
            self.checkHealth(profile)
        }
    }

    /// Which account this server's Claude answers as — or the warning that it answers as nobody,
    /// with the one button that fixes it from here rather than a sentence about a terminal.
    private func checkAccount(_ profile: ConnectionProfile) {
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

    private func renderAccount(
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


    private func applyAddress(_ id: String) {
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

    private func applyName(_ id: String) {
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

    private func applyPassword(_ id: String) {
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

    private func save(
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

    private func confirmRemove(id: String, name: String) {
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


    /// A machine the scan found, taken as it stands. Nothing is re-probed — the scanner already
    /// got an answer out of that exact address — except when it wants a password, which the scan
    /// cannot know, so the form is filled in and the person is asked for the one missing thing
    /// rather than being handed a profile that will fail on its first turn.
    private func adopt(_ suggestion: TailnetScanner.Suggestion) {
        guard !suggestion.requiresAuth else {
            if let addressRow {
                gtk_editable_set_text(op(addressRow), suggestion.baseURL.absoluteString)
            }
            if let nameRow {
                gtk_editable_set_text(op(nameRow), suggestion.recommendedProfileName)
            }
            if let agentRow {
                adw_combo_row_set_selected(
                    ptr(UnsafeMutableRawPointer(agentRow)),
                    suggestion.backend == .openCode ? 1 : 0)
            }
            setStatus(
                Localized.text("%@ wants a password", suggestion.recommendedProfileName),
                detail: Localized.text(
                    "It answered, so the address is right — type the password it was started with and probe."
                ), tone: .warn)
            if let passwordRow { gtk_widget_grab_focus(passwordRow) }
            return
        }
        let profile = ConnectionProfile(
            id: UUID().uuidString, name: suggestion.recommendedProfileName,
            backend: suggestion.backend, baseURL: suggestion.baseURL,
            username: ProbeSweep.username(for: suggestion.backend))
        Task { [weak self] in
            do {
                try await ServerDirectory.shared.save(profile, password: nil)
                self?.onChanged()
                Gtk.onMain { [weak self] in
                    self?.toast(Localized.text("Added %@", profile.name))
                    self?.reload()
                }
            } catch {
                let text = Localized.text("Could not save: %@", String(describing: error))
                Gtk.onMain { [weak self] in self?.toast(text) }
            }
        }
    }

    private func probeAndSave() {
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

    private var selectedBackend: AgentType {
        guard let agentRow else { return .claudeCode }
        return adw_combo_row_get_selected(ptr(UnsafeMutableRawPointer(agentRow))) == 1
            ? .openCode : .claudeCode
    }

    private func clearAddForm() {
        if let addressRow { gtk_editable_set_text(op(addressRow), "") }
        if let nameRow { gtk_editable_set_text(op(nameRow), "") }
        if let passwordRow { gtk_editable_set_text(op(passwordRow), "") }
    }

    private func setProbing(_ value: Bool) {
        probing = value
        guard let probeButton else { return }
        gtk_widget_set_sensitive(probeButton, value ? 0 : 1)
        gtk_button_set_label(
            ptr(probeButton),
            value ? Localized.text("Probing…") : Localized.text("Probe and save"))
    }

    /// What the add form is doing, or what it found, as a row of the same shape every server fact
    /// wears here — headline, sentence, and the one button worth pressing about it.
    private func setStatus(
        _ headline: String, detail: String = "", tone: Tone = .quiet,
        actions: [UnsafeMutablePointer<GtkWidget>] = []
    ) {
        guard let statusRow else { return }
        adw_preferences_row_set_title(ptr(statusRow), headline)
        setFact(statusRow, statusActions, detail, tone: tone, actions: actions)
        gtk_widget_set_visible(statusRow, headline.isEmpty ? 0 : 1)
    }

    private static func explain(_ reading: HostAddress.Reading, raw: String) -> String {
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
    private static func within<T: Sendable>(
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
    private static func diagnose(
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
    private static func otherAgentPort(for url: URL) -> URL? {
        guard let port = url.port else { return nil }
        let alternate: Int
        switch port {
        case HostAddress.openCodePort: alternate = HostAddress.claudeCodePort
        case HostAddress.claudeCodePort: alternate = HostAddress.openCodePort
        default: return nil
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.port = alternate
        return components.url
    }

    /// Everything a row can find out, asked again — the refresh button in its header, and what a
    /// failed probe's "try again" lands on.
    private func recheck(_ profileID: String) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        checkHealth(profile)
        if profile.backend == .claudeCode, !profile.id.hasPrefix(DemoWorld.profilePrefix) {
            checkSoftware(profile)
            checkAccount(profile)
        }
    }

    private func buttons(for diagnosis: ConnectDiagnosis, profileID: String?)
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
                Self.inlineButton(Localized.text("Copy `tailscale up`")) { [weak self] in
                    Gtk.copyToClipboard("tailscale up")
                    self?.toast(Localized.text("Copied — run it in a terminal."))
                }
            ]
        case .none, .openAppSettings, .revealPassword, .seePro:
            return []
        }
    }

    private func retry(profileID: String?, at url: URL? = nil) {
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


    private func readTailnetAddress() {
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
    private actor Tailnet {
        private var reading: Task<String?, Never>?

        func address() async -> String? {
            if let reading { return await reading.value }
            let made = Task.detached { TailnetStatusLinux.read().address }
            reading = made
            return await made.value
        }
    }

    private static let tailnet = Tailnet()


    private enum Tone {
        case good, warn, bad, quiet

        var css: String? {
            switch self {
            case .good: return "fact-good"
            case .warn: return "fact-warn"
            case .bad: return "fact-bad"
            case .quiet: return nil
            }
        }
    }

    private static let glyphTones = [
        "glyph-done", "glyph-error", "glyph-pending", "glyph-needs",
    ]
    private static let factTones = ["fact-good", "fact-warn", "fact-bad", "row-detail", "glyph-error"]

    private func setGlyph(_ slots: ServerRow, _ text: String, css: String) {
        guard let glyph = slots.glyph else { return }
        gtk_label_set_text(op(glyph), text)
        Gtk.setTone(glyph, css, from: Self.glyphTones)
    }

    private func setFact(
        _ row: UnsafeMutablePointer<GtkWidget>?, _ actionBox: UnsafeMutablePointer<GtkWidget>?,
        _ text: String, tone: Tone, actions: [UnsafeMutablePointer<GtkWidget>],
        title: String? = nil
    ) {
        guard let row else { return }
        if let title { adw_preferences_row_set_title(ptr(row), title) }
        adw_action_row_set_subtitle(ptr(row), text)
        Gtk.setTone(row, tone.css, from: Self.factTones)
        guard let actionBox else { return }
        Gtk.removeChildren(of: actionBox)
        for action in actions { gtk_box_append(ptr(actionBox), action) }
        gtk_widget_set_visible(actionBox, actions.isEmpty ? 0 : 1)
    }

    /// A row that states one fact about a server and carries whatever buttons that fact earns.
    /// The subtitle is where the sentence goes — it wraps to as many lines as it needs, because a
    /// named diagnosis is a paragraph and truncating it would put the app back to "unreachable".
    private static func factRow(title: String)
        -> (UnsafeMutablePointer<GtkWidget>, UnsafeMutablePointer<GtkWidget>)
    {
        let row = adw_action_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        adw_action_row_set_subtitle_lines(ptr(row), 0)
        adw_action_row_set_subtitle_selectable(ptr(row), 1)
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_valign(actions, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(actions, 0)
        adw_action_row_add_suffix(ptr(row), actions)
        return (row, actions)
    }

    /// What an address field puts in front of someone who wants to change it: `host:port` when the
    /// scheme is the ordinary one, and the whole URL when it isn't — a field that hid an `https`
    /// would silently downgrade the server the moment it was applied.
    private static func editableAddress(_ profile: ConnectionProfile) -> String {
        guard profile.baseURL.scheme == "http" else {
            var text = profile.baseURL.absoluteString
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return ServerLabel.address(profile)
    }

    private static func entryRow(title: String, tooltip: String?)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = adw_entry_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        if let tooltip { gtk_widget_set_tooltip_text(row, tooltip) }
        return row
    }

    /// A password is taken exactly as typed. Every other field here is trimmed, because a stray
    /// space in an address is a typo — in a secret it is a character the server is expecting.
    private static func secretText(_ row: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let raw = gtk_editable_get_text(op(row)) else { return "" }
        return String(cString: raw)
    }

    private static func passwordRow(title: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_password_entry_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        return row
    }

    private static func inlineButton(
        _ title: String, css: [String] = ["flat"], onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(title, css: css, onClick: onClick)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        return button
    }

    private func toast(_ text: String) {
        guard let window, let toast = adw_toast_new(text) else { return }
        adw_preferences_window_add_toast(ptr(window), toast)
    }


    private final class Registry: @unchecked Sendable {
        var managers: [UInt: ServerManager] = [:]
        var next: UInt = 1
    }

    private static let registry = Registry()

    private static func hold(_ manager: ServerManager) -> UInt {
        let token = registry.next
        registry.next += 1
        registry.managers[token] = manager
        return token
    }

    private static func release(_ token: UInt) {
        registry.managers[token]?.forgetWidgets()
        registry.managers[token] = nil
    }

    /// Every pointer here belongs to a window GTK has destroyed. The manager itself may outlive it
    /// — the app holds one so a second ask raises rather than rebuilds — and a probe still in
    /// flight will come back to write into a row. Nothing may be touched again, and a reopened
    /// window must build a fresh set rather than take back the group it used to remove rows from.
    private func forgetWidgets() {
        window = nil
        configuredGroup = nil
        addGroup = nil
        discovery = nil
        configuredRows = []
        rows = [:]
        addressRow = nil
        nameRow = nil
        passwordRow = nil
        agentRow = nil
        probeButton = nil
        statusRow = nil
        statusActions = nil
        probing = false
        expandAfterReload = nil
    }
}

/// The widgets one configured server's expander owns, so a probe that finishes a second later can
/// write into exactly its own row rather than rebuilding the list under whoever is reading it.
private final class ServerRow {
    var glyph: UnsafeMutablePointer<GtkWidget>?
    var health: UnsafeMutablePointer<GtkWidget>?
    var healthActions: UnsafeMutablePointer<GtkWidget>?
    var software: UnsafeMutablePointer<GtkWidget>?
    var softwareActions: UnsafeMutablePointer<GtkWidget>?
    var account: UnsafeMutablePointer<GtkWidget>?
    var accountActions: UnsafeMutablePointer<GtkWidget>?
    var address: UnsafeMutablePointer<GtkWidget>?
    var name: UnsafeMutablePointer<GtkWidget>?
    var password: UnsafeMutablePointer<GtkWidget>?
}
