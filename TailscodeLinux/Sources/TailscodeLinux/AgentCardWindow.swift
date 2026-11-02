import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// One agent's card: the checklist the machine proves, in Core's words, each step that is not yet
/// true carrying its one press — a brain from the machine's own model servers, a key kept on the
/// machine, a sign-in run there and relayed here — and, once it answered, the models it offered
/// and a chat with it.
final class AgentCardWindow: MachineWindow, @unchecked Sendable {
    let profile: ConnectionProfile
    let backend: any CodingAgentBackend
    let agentID: String
    let onChange: @Sendable () -> Void
    var report: MachineAgentsReport?
    var busy: String?
    var showsBrains = false
    var relay: AgentSignInRelay?
    var signInText = ""
    var generation = 0

    static func key(_ profileID: String, _ agentID: String) -> String { "agent·\(profileID)·\(agentID)" }

    static func present(
        profile: ConnectionProfile, backend: any CodingAgentBackend, agentID: String,
        parent: UnsafeMutablePointer<GtkWidget>?, onChange: @escaping @Sendable () -> Void = {}
    ) {
        let window =
            (MachineWindowRegistry.existing(key(profile.id, agentID)) as? AgentCardWindow)
            ?? AgentCardWindow(profile: profile, backend: backend, agentID: agentID, onChange: onChange)
        window.show(title: Localized.text("Agent on %@", profile.name), parent: parent, width: 540, height: 720)
    }

    init(
        profile: ConnectionProfile, backend: any CodingAgentBackend, agentID: String,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.profile = profile
        self.backend = backend
        self.agentID = agentID
        self.onChange = onChange
        super.init(key: Self.key(profile.id, agentID))
    }

    var hosting: (any MachineAgentHosting)? { backend as? any MachineAgentHosting }

    var agent: MachineAgent? { report?.agents.first { $0.id == agentID } }

    override func opened() {
        render()
        reload(refreshBrains: true)
    }

    override func closed() {
        generation += 1
    }

    func reload(refreshBrains: Bool = false) {
        guard let hosting else { return }
        generation += 1
        let mine = generation
        Task { [weak self] in
            let report = try? await hosting.machineAgents(refreshBrains: refreshBrains)
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen, mine == self.generation else { return }
                if let report { self.report = report }
                self.render()
                if let state = self.agent?.state, state == .checking || state == .installing {
                    Gtk.after(2_000) { [weak self] in
                        guard let self, self.isOpen, mine == self.generation else { return }
                        self.reload()
                    }
                }
            }
        }
    }

    func render() {
        guard let window else { return }
        guard let agent else {
            let group = MachineRows.group(nil)
            MachineRows.add(MachineRows.row(Localized.text("Asking %@…", profile.name)), to: group)
            replaceGroups([group])
            return
        }
        gtk_window_set_title(ptr(window), Localized.text("%@ on %@", agent.name, profile.name))
        var built: [UnsafeMutablePointer<GtkWidget>] = [stepsGroup(agent)]
        let brains = MachineAgentReading.brains(report, for: agent, machine: profile.name)
        if agent.brainStyle != nil, showsBrains || agent.state == .needsBrain {
            built.append(brainsGroup(agent, brains: brains))
        }
        if let relay { built.append(signInGroup(relay)) }
        if agent.state == .ready, !agent.models.isEmpty { built.append(modelsGroup(agent)) }
        built.append(actionsGroup(agent, brains: brains))
        replaceGroups(built)
    }

    private func stepsGroup(_ agent: MachineAgent) -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(agent.name, description: agent.description)
        if let busy {
            let row = MachineRows.row(busy)
            MachineRows.prefix("…", css: "glyph-pending", on: row)
            MachineRows.add(row, to: group)
        }
        for step in MachineAgentReading.steps(agent, machine: profile.name) {
            let row = MachineRows.row(step.title, subtitle: step.detail)
            let (glyph, css) = MachineRows.stepGlyph(step.state)
            MachineRows.prefix(glyph, css: css, on: row)
            if let press = step.press, let title = step.pressTitle, press != .startChat, press != .add {
                MachineRows.suffixButton(title, sensitive: busy == nil, on: row) { [weak self] in
                    self?.perform(press)
                }
            }
            MachineRows.add(row, to: group)
        }
        return group
    }

    private func brainsGroup(_ agent: MachineAgent, brains: [BrainOption]) -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(
            Localized.text("A brain"), description: Localized.text("%@ needs a model to think with.", agent.name))
        if brains.isEmpty {
            MachineRows.add(MachineRows.row(Localized.text("No model server answered on this machine.")), to: group)
        }
        for option in brains {
            let row = MachineRows.row(option.title, subtitle: option.detail)
            let chosen = agent.brain.map { brain in
                option.choice?.model == brain.model && brain.kind == "local"
            } ?? false
            MachineRows.prefix(chosen ? "●" : "○", css: chosen ? "glyph-done" : "dim-label", on: row)
            MachineRows.suffixButton(
                option.keyProvider == nil ? Localized.text("Use") : Localized.text("Paste"),
                sensitive: busy == nil, on: row
            ) { [weak self] in
                self?.choose(option)
            }
            MachineRows.add(row, to: group)
        }
        return group
    }

    private func signInGroup(_ relay: AgentSignInRelay) -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(
            Localized.text("Sign in"), description: MachineAgentReading.signInState(relay))
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        if !relay.lines.isEmpty {
            let console = Gtk.label(relay.lines.suffix(14).joined(separator: "\n"), css: "monospace", wrap: true)
            gtk_label_set_xalign(op(console), 0)
            Gtk.addClass(console, "tool-output")
            gtk_box_append(ptr(column), console)
        }
        for link in relay.links {
            let button = Gtk.button(Localized.text("Open %@", Self.shortLink(link)), css: ["suggested-action"]) {
                MachineRows.openLink(link)
            }
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_widget_set_tooltip_text(button, link)
            gtk_box_append(ptr(column), button)
        }
        for code in relay.codes {
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_box_append(ptr(line), Gtk.label(code, css: "title-3", selectable: true))
            gtk_box_append(
                ptr(line),
                Gtk.button(Localized.text("Copy"), css: ["flat"]) { [weak self] in
                    Gtk.copyToClipboard(code)
                    Gtk.onMain { [weak self] in self?.toast(Localized.text("Copied")) }
                })
            gtk_box_append(ptr(column), line)
        }
        if relay.state == .running {
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            let entry = gtk_entry_new()!
            gtk_entry_set_placeholder_text(ptr(entry), MachineAgentReading.signInInputPlaceholder)
            gtk_widget_set_hexpand(entry, 1)
            let entryBits = UInt(bitPattern: entry)
            let send: @Sendable () -> Void = { [weak self] in
                guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
                let text = Dialogs.entryText(ptr(raw))
                gtk_editable_set_text(op(raw), "")
                Gtk.onMain { [weak self] in self?.sendSignIn(text) }
            }
            Gtk.connect(UnsafeMutableRawPointer(entry), "activate", send)
            gtk_box_append(ptr(line), entry)
            gtk_box_append(ptr(line), Gtk.button(Localized.text("Send"), css: ["suggested-action"], onClick: send))
            gtk_box_append(
                ptr(line),
                Gtk.button(Localized.text("Cancel"), css: ["flat"]) { [weak self] in
                    Gtk.onMain { [weak self] in self?.cancelSignIn() }
                })
            gtk_box_append(ptr(column), line)
        }
        MachineRows.add(MachineRows.wrapped(column), to: group)
        return group
    }

    private static func shortLink(_ link: String) -> String {
        URL(string: link)?.host ?? String(link.prefix(40))
    }

    private func modelsGroup(_ agent: MachineAgent) -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(
            Localized.text("In the model pill"),
            description: Localized.text("Pick one in any chat's model chooser, under %@.", agent.name))
        for model in agent.models.prefix(12) {
            let current = model.id == agent.currentModel
            let row = MachineRows.row(model.name, subtitle: current ? Localized.text("What it thinks with now") : nil)
            MachineRows.prefix(current ? "●" : "·", css: current ? "glyph-done" : "dim-label", on: row)
            MachineRows.add(row, to: group)
        }
        if agent.models.count > 12 {
            MachineRows.add(MachineRows.row(Localized.text("and %d more", agent.models.count - 12)), to: group)
        }
        return group
    }

    private func actionsGroup(_ agent: MachineAgent, brains: [BrainOption]) -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil, description: MachineAgentReading.permissionNote)
        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        if let (press, title) = MachineAgentReading.primary(agent, brains: brains, machine: profile.name) {
            let primary = Gtk.button(title, css: ["suggested-action"]) { [weak self] in
                Gtk.onMain { [weak self] in self?.perform(press, brains: brains) }
            }
            gtk_widget_set_sensitive(primary, busy == nil ? 1 : 0)
            gtk_box_append(ptr(buttons), primary)
        }
        if agent.added, agent.state != .checking, agent.state != .installing {
            let check = Gtk.button(Localized.text("Check again"), css: []) { [weak self] in
                Gtk.onMain { [weak self] in self?.perform(.check) }
            }
            gtk_widget_set_sensitive(check, busy == nil ? 1 : 0)
            gtk_box_append(ptr(buttons), check)
        }
        if agent.state == .ready, agent.brainStyle != nil, !showsBrains {
            gtk_box_append(
                ptr(buttons),
                Gtk.button(Localized.text("Change its brain"), css: []) { [weak self] in
                    Gtk.onMain { [weak self] in
                        self?.showsBrains = true
                        self?.render()
                    }
                })
        }
        if let website = agent.website {
            gtk_box_append(
                ptr(buttons),
                Gtk.button(Localized.text("Website"), css: ["flat"]) { MachineRows.openLink(website) })
        }
        MachineRows.add(MachineRows.wrapped(buttons, margin: 8), to: group)
        if agent.added {
            let remove = MachineRows.row(
                MachineAgentReading.removeTitle,
                subtitle: Localized.text("%@ stays installed; the machine stops offering it.", agent.name))
            MachineRows.suffixButton(Localized.text("Remove"), css: ["destructive-action"], sensitive: busy == nil, on: remove) {
                [weak self] in
                self?.confirmRemove(agent)
            }
            MachineRows.add(remove, to: group)
        }
        return group
    }

    func perform(_ press: AgentPress, brains: [BrainOption] = []) {
        switch press {
        case .add: run(Localized.text("Adding…")) { try await $0.addAgent(self.agentID) }
        case .check: run(Localized.text("Checking…")) { try await $0.checkAgent(self.agentID) }
        case .install: run(Localized.text("Installing…")) { try await $0.installAgent(self.agentID) }
        case .giveBrain:
            guard let first = brains.first(where: { $0.choice != nil }) else {
                showsBrains = true
                render()
                return
            }
            choose(first)
        case .enterKey(let env): askKey(env: env)
        case .signIn(let method): startSignIn(method)
        case .startChat: startChat()
        case .remove: if let agent { confirmRemove(agent) }
        case .open: render()
        }
    }

    func choose(_ option: BrainOption) {
        if let choice = option.choice {
            run(Localized.text("Giving it %@…", option.title)) { try await $0.setAgentBrain(self.agentID, choice) }
            return
        }
        guard let provider = option.keyProvider else { return }
        Dialogs.prompt(
            title: option.title, body: MachineAgentReading.keyNote, placeholder: MachineAgentReading.keyPlaceholder,
            confirmLabel: Localized.text("Keep on %@", profile.name), secret: true, parent: window
        ) { [weak self] key in
            guard !key.isEmpty else { return }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.run(Localized.text("Giving it %@…", option.title)) {
                    try await $0.setAgentBrain(self.agentID, .key(provider: provider, key: key))
                }
            }
        }
    }

    func askKey(env: String) {
        guard let key = agent?.keys.first(where: { $0.env == env }) else { return }
        let (dialog, content, actions) = Dialogs.windowWithActions(title: key.name, parent: window)
        gtk_window_set_modal(ptr(dialog), 0)
        gtk_box_append(
            ptr(content),
            Gtk.label(
                Localized.text("%@ reads it as %@.", agent?.name ?? "", env) + " " + MachineAgentReading.keyNote,
                css: "row-detail", wrap: true, selectable: false))
        if let url = key.url {
            let get = Gtk.button(Localized.text("Get a key"), css: ["flat"]) { MachineRows.openLink(url) }
            gtk_widget_set_halign(get, GTK_ALIGN_START)
            gtk_widget_set_tooltip_text(get, url)
            gtk_box_append(ptr(content), get)
        }
        let entry = gtk_password_entry_new()!
        gtk_box_append(ptr(content), entry)
        let entryBits = UInt(bitPattern: entry)
        let save: @Sendable () -> Void = { [weak self] in
            guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
            let value: String = {
                guard let text = gtk_editable_get_text(op(raw)) else { return "" }
                return String(cString: text)
            }()
            Dialogs.close(ptr(raw))
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.run(Localized.text("Keeping the key on %@…", self.profile.name)) {
                    try await $0.setAgentKey(self.agentID, env: env, value: value)
                }
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate", save)
        let dialogBits = UInt(bitPattern: dialog)
        gtk_box_append(
            ptr(actions),
            Gtk.button(Localized.text("Cancel"), css: ["flat"]) {
                guard let raw = UnsafeMutableRawPointer(bitPattern: dialogBits) else { return }
                gtk_window_destroy(ptr(raw))
            })
        gtk_box_append(ptr(actions), Gtk.button(Localized.text("Keep on %@", profile.name), css: ["suggested-action"], onClick: save))
        gtk_window_present(ptr(dialog))
        gtk_widget_grab_focus(entry)
    }

    func startSignIn(_ method: String) {
        guard let hosting else { return }
        busy = Localized.text("Starting the sign-in on %@…", profile.name)
        render()
        Task { [weak self] in
            do {
                let relay = try await hosting.startAgentSignIn(self?.agentID ?? "", method: method)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.busy = nil
                    self.relay = relay
                    self.render()
                    self.pollSignIn()
                }
            } catch {
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.busy = nil
                    self.toast(Self.words(error))
                    self.render()
                }
            }
        }
    }

    func pollSignIn() {
        guard let hosting else { return }
        let mine = generation
        Gtk.after(1_000) { [weak self] in
            guard let self, self.isOpen, mine == self.generation else { return }
            let id = self.agentID
            Task { [weak self] in
                let relay = try? await hosting.agentSignIn(id)
                Gtk.onMain { [weak self] in
                    guard let self, self.isOpen else { return }
                    let changed = relay != self.relay
                    self.relay = relay
                    if changed { self.render() }
                    if relay?.state == .running {
                        self.pollSignIn()
                    } else {
                        self.reload()
                        self.onChange()
                    }
                }
            }
        }
    }

    func sendSignIn(_ text: String) {
        guard let hosting, !text.isEmpty else { return }
        let id = agentID
        Task { try? await hosting.sendAgentSignIn(id, text: text) }
    }

    func cancelSignIn() {
        guard let hosting else { return }
        let id = agentID
        relay = nil
        render()
        Task { try? await hosting.cancelAgentSignIn(id) }
    }

    func confirmRemove(_ agent: MachineAgent) {
        Dialogs.confirm(
            title: Localized.text("Remove %@ from %@?", agent.name, profile.name),
            body: Localized.text("%@ stays installed; the machine stops offering it and it leaves the model pill. Conversations with it stay.", agent.name),
            confirmLabel: Localized.text("Remove"), parent: window
        ) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let hosting = self.hosting else { return }
                let id = self.agentID
                Task { [weak self] in
                    try? await hosting.removeAgent(id)
                    Gtk.onMain { [weak self] in
                        self?.onChange()
                        self?.reload()
                    }
                }
            }
        }
    }

    /// A chat on this machine with the agent, on the model it thinks with now.
    func startChat() {
        guard let agent else { return }
        let model = agent.currentModel ?? agent.models.first?.id ?? "default"
        let selection = ModelSelection(providerID: agent.id, modelID: model)
        ModelFleet.adopt(
            ModelPick(
                profileID: profile.id, selection: selection, isElsewhere: true, serverName: profile.name,
                modelName: agent.name))
        mainWindow?.createChat(onProfileID: profile.id, directory: nil)
        close()
    }

    /// One press against the machine: the card says it is working, the machine answers with the
    /// agent as it now stands, and every list showing this machine reads it again.
    func run(_ words: String, _ work: @escaping @Sendable (any MachineAgentHosting) async throws -> MachineAgent) {
        guard let hosting, busy == nil else { return }
        busy = words
        render()
        Task { [weak self] in
            let outcome: Result<MachineAgent, Error>
            do {
                outcome = .success(try await work(hosting))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.busy = nil
                switch outcome {
                case .success(let agent):
                    if var report = self.report, let index = report.agents.firstIndex(where: { $0.id == agent.id }) {
                        report.agents[index] = agent
                        self.report = report
                    }
                    if agent.state == .ready { self.showsBrains = false }
                    let (words, _) = MachineAgentReading.state(agent, machine: self.profile.name)
                    self.toast("\(agent.name): \(words)")
                case .failure(let error):
                    self.toast(Self.words(error))
                }
                self.render()
                self.reload()
                self.onChange()
            }
        }
    }
}
