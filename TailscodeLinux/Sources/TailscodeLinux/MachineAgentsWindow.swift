import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The agents one machine runs: its own built in, every ACP agent it hosts or found, and the door
/// to the registry. A row opens the agent's card; a found agent is added with one press, and the
/// list asks again every two seconds while the machine is still proving something.
final class MachineAgentsWindow: MachineWindow, @unchecked Sendable {
    let profile: ConnectionProfile
    let backend: any CodingAgentBackend
    var report: MachineAgentsReport?
    var registryCount: Int?
    var adding: Set<String> = []
    var pollGeneration = 0

    static func key(_ profileID: String) -> String { "agents·\(profileID)" }

    static func present(profile: ConnectionProfile, backend: any CodingAgentBackend, parent: UnsafeMutablePointer<GtkWidget>?) {
        let window =
            (MachineWindowRegistry.existing(key(profile.id)) as? MachineAgentsWindow)
            ?? MachineAgentsWindow(profile: profile, backend: backend)
        window.show(
            title: Localized.text("Agents on %@", profile.name), parent: parent)
    }

    init(profile: ConnectionProfile, backend: any CodingAgentBackend) {
        self.profile = profile
        self.backend = backend
        super.init(key: Self.key(profile.id))
    }

    override func opened() {
        render()
        reload()
        loadRegistryCount()
    }

    override func closed() {
        pollGeneration += 1
    }

    func reload() {
        guard let hosting = backend as? any MachineAgentHosting else { return }
        pollGeneration += 1
        let generation = pollGeneration
        Task { [weak self] in
            let report = try? await hosting.machineAgents(refreshBrains: false)
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen, generation == self.pollGeneration else { return }
                self.report = report
                self.render()
                if self.isProving { Gtk.after(2_000) { [weak self] in self?.reloadIfOpen(generation) } }
            }
        }
    }

    private func reloadIfOpen(_ generation: Int) {
        guard isOpen, generation == pollGeneration else { return }
        reload()
    }

    var isProving: Bool {
        !adding.isEmpty
            || (report?.agents.contains { $0.state == .checking || $0.state == .installing } ?? false)
    }

    func loadRegistryCount() {
        guard let hosting = backend as? any MachineAgentHosting else { return }
        Task { [weak self] in
            let count = (try? await hosting.agentRegistry())?.count
            Gtk.onMain { [weak self] in
                guard let self, self.isOpen, let count else { return }
                self.registryCount = count
                self.render()
            }
        }
    }

    func render() {
        let group = MachineRows.group(MachineAgentReading.section, description: MachineAgentReading.permissionNote)
        let builtIn: AgentType? = backend.agentType == .claudeCode ? .claudeCode : nil
        let rows = MachineAgentReading.rows(report, machine: profile.name, builtIn: builtIn)
        for reading in rows {
            MachineRows.add(row(for: reading), to: group)
        }
        if report == nil {
            MachineRows.add(MachineRows.row(Localized.text("Asking %@…", profile.name)), to: group)
        }
        let more = MachineRows.link(
            MachineAgentReading.moreAgents,
            subtitle: registryCount.map(MachineAgentReading.moreAgentsDetail) ?? MachineAgentReading.registryNote
        ) { [weak self] in
            guard let self else { return }
            AgentRegistryWindow.present(
                profile: self.profile, backend: self.backend, parent: self.window,
                onChange: { [weak self] in self?.reload() })
        }
        MachineRows.prefix("＋", css: "accent", on: more)
        MachineRows.add(more, to: group)
        replaceGroups([group])
    }

    private func row(for reading: AgentRowReading) -> UnsafeMutablePointer<GtkWidget> {
        let working = adding.contains(reading.id)
        let subtitle = working ? Localized.text("Checking…") : reading.subtitle
        let row = MachineRows.row(reading.title, subtitle: subtitle)
        if let css = MachineRows.tone(working ? .working : reading.tone) { Gtk.addClass(row, css) }
        MachineRows.prefix(reading.initial, css: reading.isBuiltIn ? "accent" : "heading", on: row)
        guard !reading.isBuiltIn else { return row }
        if reading.press == .add, let title = reading.pressTitle {
            let id = reading.id
            MachineRows.suffixButton(title, css: ["suggested-action"], sensitive: !working, on: row) { [weak self] in
                self?.add(id)
            }
        }
        let chevron = Gtk.label("›", css: "dim-label", selectable: false)
        gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), chevron)
        gtk_list_box_row_set_activatable(ptr(row), 1)
        let id = reading.id
        Gtk.connect(UnsafeMutableRawPointer(row), "activated") { [weak self] in
            Gtk.onMain { [weak self] in self?.openCard(id) }
        }
        return row
    }

    func openCard(_ id: String) {
        AgentCardWindow.present(
            profile: profile, backend: backend, agentID: id, parent: window,
            onChange: { [weak self] in self?.reload() })
    }

    func add(_ id: String) {
        guard let hosting = backend as? any MachineAgentHosting else { return }
        adding.insert(id)
        render()
        Task { [weak self] in
            let outcome: Result<MachineAgent, Error>
            do {
                outcome = .success(try await hosting.addAgent(id))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.adding.remove(id)
                switch outcome {
                case .success(let agent):
                    let (words, _) = MachineAgentReading.state(agent, machine: self.profile.name)
                    self.toast("\(agent.name): \(words)")
                case .failure(let error):
                    self.toast(Self.words(error))
                }
                self.reload()
            }
        }
    }

    /// Every open agents window for this machine reads the machine again.
    static func refresh(profileID: String) {
        (MachineWindowRegistry.existing(key(profileID)) as? MachineAgentsWindow)?.reload()
    }
}
