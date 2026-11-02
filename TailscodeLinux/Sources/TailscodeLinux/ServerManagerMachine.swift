import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ServerManager {
    /// Two rows in a machine's expander, hidden until the machine says it keeps what they open:
    /// the agents it runs besides its own, and the schedules it asks on its own.
    func addMachineRows(to row: UnsafeMutablePointer<GtkWidget>, profile: ConnectionProfile, slots: ServerRow) {
        let id = profile.id
        let agents = MachineRows.link(MachineAgentReading.section, subtitle: Localized.text("Asking…")) { [weak self] in
            guard let self else { return }
            mainWindow?.presentMachineAgents(profileID: id)
            if mainWindow == nil { self.toast(Localized.text("Open the main window first.")) }
        }
        MachineRows.prefix("◆", css: "accent", on: agents)
        gtk_widget_set_visible(agents, 0)
        slots.agents = agents
        adw_expander_row_add_row(ptr(row), agents)

        let scheduled = MachineRows.link(ScheduleWords.title, subtitle: Localized.text("Asking…")) {
            mainWindow?.presentScheduled(profileID: id)
        }
        MachineRows.prefix("◷", css: "accent", on: scheduled)
        gtk_widget_set_visible(scheduled, 0)
        slots.scheduled = scheduled
        adw_expander_row_add_row(ptr(row), scheduled)
        checkMachine(profile)
    }

    /// Reads what the machine keeps, then says it in a line on each row: which agents and in what
    /// state, how many schedules and when the next one asks.
    func checkMachine(_ profile: ConnectionProfile) {
        let id = profile.id
        let name = profile.name
        Task { [weak self] in
            guard let backend = await ServerDirectory.shared.backend(for: profile) else { return }
            let features = await MachineFeatures.read(backend)
            var agentsLine: String?
            if features.agents, let hosting = backend as? any MachineAgentHosting {
                let report = try? await hosting.machineAgents(refreshBrains: false)
                agentsLine = Self.agentsSummary(report, machine: name)
            }
            var scheduledLine: String?
            if features.schedules, let scheduling = backend as? any MachineScheduling {
                let schedules = (try? await scheduling.machineSchedules()) ?? []
                let board = ScheduleBoard.make([ScheduleBoard.Source(profileID: id, machine: name, schedules: schedules)])
                scheduledLine = board.isEmpty ? ScheduleWords.empty : (board.homeLine() ?? "")
            }
            let agentsSaid = agentsLine
            let scheduledSaid = scheduledLine
            FileHandle.standardOutput.write(
                Data("MACHINE \(name) agents=\(agentsSaid ?? "-") schedules=\(scheduledSaid ?? "-")\n".utf8))
            Gtk.onMain { [weak self] in
                guard let self, let slots = self.rows[id] else { return }
                if let agents = slots.agents {
                    gtk_widget_set_visible(agents, agentsSaid == nil ? 0 : 1)
                    if let agentsSaid { adw_action_row_set_subtitle(ptr(agents), agentsSaid) }
                }
                if let scheduled = slots.scheduled {
                    gtk_widget_set_visible(scheduled, scheduledSaid == nil ? 0 : 1)
                    if let scheduledSaid { adw_action_row_set_subtitle(ptr(scheduled), scheduledSaid) }
                }
            }
        }
    }

    /// "Hermes · Ready, Gemini CLI · Needs a key, goose · Found on arch".
    static func agentsSummary(_ report: MachineAgentsReport?, machine: String) -> String {
        let agents = report?.agents ?? []
        guard !agents.isEmpty else { return Localized.text("Only its own agent so far. More agents… adds one.") }
        return agents.prefix(4).map { agent in
            let (words, _) = MachineAgentReading.state(agent, machine: machine)
            let short = words.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? words
            return "\(agent.name) · \(short)"
        }.joined(separator: ", ")
    }
}
