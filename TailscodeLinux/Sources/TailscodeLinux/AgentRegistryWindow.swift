import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// More agents: the ACP registry as this machine could run it, searched by name, each one
/// installed on the machine with one press — downloaded there and checked against the registry's
/// checksum, never on this computer — and then proved like any other.
final class AgentRegistryWindow: MachineWindow, @unchecked Sendable {
    let profile: ConnectionProfile
    let backend: any CodingAgentBackend
    let onChange: @Sendable () -> Void
    var agents: [RegistryAgent]?
    var failure: String?
    var query = ""
    var installing: Set<String> = []
    var searchHost: UnsafeMutablePointer<GtkWidget>?

    static func key(_ profileID: String) -> String { "registry·\(profileID)" }

    static func present(
        profile: ConnectionProfile, backend: any CodingAgentBackend, parent: UnsafeMutablePointer<GtkWidget>?,
        onChange: @escaping @Sendable () -> Void = {}
    ) {
        let window =
            (MachineWindowRegistry.existing(key(profile.id)) as? AgentRegistryWindow)
            ?? AgentRegistryWindow(profile: profile, backend: backend, onChange: onChange)
        window.show(title: Localized.text("More agents for %@", profile.name), parent: parent, width: 560, height: 720)
    }

    init(profile: ConnectionProfile, backend: any CodingAgentBackend, onChange: @escaping @Sendable () -> Void) {
        self.profile = profile
        self.backend = backend
        self.onChange = onChange
        super.init(key: Self.key(profile.id))
    }

    override func opened() {
        render()
        load()
    }

    func load() {
        guard let hosting = backend as? any MachineAgentHosting else { return }
        Task { [weak self] in
            do {
                let agents = try await hosting.agentRegistry()
                Gtk.onMain { [weak self] in
                    guard let self, self.isOpen else { return }
                    self.agents = agents
                    self.failure = nil
                    self.render()
                }
            } catch {
                Gtk.onMain { [weak self] in
                    guard let self, self.isOpen else { return }
                    self.failure = Self.words(error)
                    self.render()
                }
            }
        }
    }

    var shown: [RegistryAgent] {
        let all = agents ?? []
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(needle) || $0.id.contains(needle)
                || ($0.authors ?? []).contains { $0.lowercased().contains(needle) }
                || ($0.description ?? "").lowercased().contains(needle)
        }
    }

    func render() {
        let search = MachineRows.group(nil, description: MachineAgentReading.registryNote)
        let entry = gtk_search_entry_new()!
        gtk_search_entry_set_placeholder_text(op(entry), MachineAgentReading.searchRegistry)
        gtk_editable_set_text(op(entry), query)
        let entryBits = UInt(bitPattern: entry)
        Gtk.connect(UnsafeMutableRawPointer(entry), "search-changed") { [weak self] in
            guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits),
                let text = gtk_editable_get_text(op(raw))
            else { return }
            let typed = String(cString: text)
            Gtk.onMain { [weak self] in
                guard let self, self.query != typed else { return }
                self.query = typed
                self.renderList()
            }
        }
        MachineRows.add(MachineRows.wrapped(entry, margin: 6), to: search)
        searchHost = search
        replaceGroups([search, listGroup()])
    }

    /// Only the list is redrawn while typing, so the search field keeps its focus and its caret.
    func renderList() {
        guard let page, groups.count == 2 else { return render() }
        adw_preferences_page_remove(ptr(page), ptr(groups[1]))
        let list = listGroup()
        groups[1] = list
        adw_preferences_page_add(ptr(page), ptr(list))
    }

    private func listGroup() -> UnsafeMutablePointer<GtkWidget> {
        let group = MachineRows.group(nil)
        if let failure {
            MachineRows.add(MachineRows.row(failure, subtitleCSS: "fact-bad"), to: group)
            return group
        }
        guard agents != nil else {
            MachineRows.add(MachineRows.row(Localized.text("Reading the ACP registry…")), to: group)
            return group
        }
        let shown = self.shown
        if shown.isEmpty {
            MachineRows.add(MachineRows.row(Localized.text("No agent matches \u{201C}%@\u{201D}", query)), to: group)
        }
        for agent in shown {
            let reading = MachineAgentReading.registryRow(agent, machine: profile.name)
            let busy = installing.contains(agent.id)
            let row = MachineRows.row(reading.title, subtitle: busy ? Localized.text("Installing on %@…", profile.name) : reading.subtitle)
            MachineRows.prefix(MachineAgentReading.registryInitial(agent), css: "heading", on: row)
            if let description = agent.description { gtk_widget_set_tooltip_text(row, description) }
            if let press = reading.press {
                let id = agent.id
                MachineRows.suffixButton(
                    press, css: reading.enabled ? ["suggested-action"] : ["flat"],
                    sensitive: reading.enabled && !busy, on: row
                ) { [weak self] in
                    self?.install(id)
                }
            }
            MachineRows.add(row, to: group)
        }
        return group
    }

    func install(_ id: String) {
        guard let hosting = backend as? any MachineAgentHosting else { return }
        installing.insert(id)
        renderList()
        Task { [weak self] in
            let outcome: Result<MachineAgent, Error>
            do {
                outcome = .success(try await hosting.installAgent(id))
            } catch {
                outcome = .failure(error)
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.installing.remove(id)
                switch outcome {
                case .success(let agent):
                    let (words, _) = MachineAgentReading.state(agent, machine: self.profile.name)
                    self.toast("\(agent.name): \(words)")
                    AgentCardWindow.present(
                        profile: self.profile, backend: self.backend, agentID: agent.id, parent: self.window,
                        onChange: self.onChange)
                case .failure(let error):
                    self.toast(Self.words(error))
                }
                self.onChange()
                self.load()
            }
        }
    }
}

extension MachineAgentReading {
    /// The letter a registry row wears, for a list with no icons drawn.
    static func registryInitial(_ agent: RegistryAgent) -> String {
        agent.name.first.map { String($0).uppercased() } ?? "?"
    }
}
