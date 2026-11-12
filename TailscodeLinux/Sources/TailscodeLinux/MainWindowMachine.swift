import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// The sidebar's one line while anything is scheduled — "Next: “AI news” tomorrow 07:30 on
    /// arch" — which opens Scheduled. It says nothing at all while nothing is.
    func makeScheduleLine() -> UnsafeMutablePointer<GtkWidget> {
        gtk_widget_set_visible(scheduleBox, 0)
        Gtk.addClass(scheduleBox, "usage-footer")
        Gtk.margins(scheduleBox, top: 4, bottom: 2, leading: 10, trailing: 10)
        gtk_widget_set_cursor_from_name(scheduleBox, "pointer")
        gtk_widget_set_tooltip_text(scheduleBox, ScheduleWords.title)
        let glyph = Gtk.label("◷", css: "accent", selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        gtk_box_append(ptr(scheduleBox), glyph)
        gtk_label_set_wrap(op(scheduleLabel), 1)
        gtk_label_set_xalign(op(scheduleLabel), 0)
        gtk_widget_set_hexpand(scheduleLabel, 1)
        gtk_box_append(ptr(scheduleBox), scheduleLabel)
        Gtk.onRelease(scheduleBox) { [weak self] in self?.presentScheduled() }
        return scheduleBox
    }

    func startMachineWatch() {
        refreshScheduleLine()
        Gtk.after(8_000) { [weak self] in self?.nudgeAgents() }
        machineBeat()
    }

    private func machineBeat() {
        Gtk.after(60_000) { [weak self] in
            guard let self, !Gtk.isQuitting else { return }
            self.refreshScheduleLine()
            self.machineBeat()
        }
    }

    func refreshScheduleLine() {
        scheduleGeneration += 1
        let mine = scheduleGeneration
        Task { [weak self] in
            let board = await ScheduleBoard.load(await MachineFeatures.schedulingServers())
            Gtk.onMain { [weak self] in
                guard let self, mine == self.scheduleGeneration else { return }
                self.scheduleBoard = board
                let line = board.homeLine()
                gtk_label_set_text(op(self.scheduleLabel), line ?? "")
                gtk_widget_set_visible(self.scheduleBox, line == nil ? 0 : 1)
            }
        }
    }

    func presentScheduled(profileID: String? = nil) {
        SchedulesWindow.present(profileID: profileID, parent: sidebarPane ?? window)
    }

    func presentMachineAgents(profileID: String, card agentID: String? = nil) {
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            guard let profile = profiles.first(where: { $0.id == profileID }),
                let backend = await ServerDirectory.shared.backend(for: profile)
            else { return }
            Gtk.onMain { [weak self] in
                let parent = self?.window
                MachineAgentsWindow.present(profile: profile, backend: backend, parent: parent)
                guard let agentID else { return }
                AgentCardWindow.present(
                    profile: profile, backend: backend, agentID: agentID, parent: parent,
                    onChange: { MachineAgentsWindow.refresh(profileID: profileID) })
            }
        }
    }

    /// Ask later for whatever is in a pane's prompt box, aimed where that box is aimed: its
    /// machine, its model and level, its folder, and its own conversation for a repeat to keep.
    func askLater(from pane: ChatPane, text override: String? = nil, sessionID: String? = nil) {
        let text = (override ?? pane.composedText()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            toast(Localized.text("Write the question first, then ask it later."))
            return
        }
        guard let entry = pane.entry, let backend = pane.backend,
            let profile = fleetProfiles().first(where: { $0.id == entry.profileID })
        else {
            toast(Localized.text("Open a chat on a machine first."))
            return
        }
        let choice = pane.promptChoice
        let target = AskLaterDialog.Target(
            profile: profile, backend: backend, model: choice.model, effort: choice.effort,
            directory: entry.session.directory, sessionID: sessionID ?? entry.session.id)
        let clears = override == nil
        AskLaterDialog.present(text: text, target: target, parent: window) { [weak pane] in
            guard clears else { return }
            Gtk.onMain { [weak pane] in pane?.clearComposer() }
        }
    }

    /// Agents a machine has that nobody has been told about, said once in a toast that adds them.
    func nudgeAgents() {
        guard !DesktopGuard.isHarnessed || DemoMode.isActive else { return }
        Task { [weak self] in
            for server in await MachineFeatures.servers() where await MachineFeatures.read(server.backend).agents {
                guard let hosting = server.backend as? any MachineAgentHosting,
                    let report = try? await hosting.machineAgents(refreshBrains: false)
                else { continue }
                let unseen = AgentNewsStore.unseen(report, profileID: server.profile.id)
                guard let news = MachineAgentReading.news([(server.profile.name, unseen)]) else { continue }
                AgentNewsStore.markSeen(unseen, profileID: server.profile.id)
                SettingsFile.capture()
                let ids = unseen.map(\.id)
                let profileID = server.profile.id
                Gtk.onMain { [weak self] in
                    self?.agentNewsToast(news, ids: ids, profileID: profileID, hosting: hosting)
                }
                return
            }
        }
    }

    private func agentNewsToast(
        _ news: (title: String, detail: String), ids: [String], profileID: String, hosting: any MachineAgentHosting
    ) {
        guard let toastOverlay, let toast = adw_toast_new("\(news.title). \(news.detail)") else { return }
        adw_toast_set_timeout(toast, 0)
        adw_toast_set_button_label(toast, Localized.text("Add"))
        Gtk.connect(UnsafeMutableRawPointer(toast), "button-clicked") { [weak self] in
            Task { [weak self] in
                for id in ids { _ = try? await hosting.addAgent(id) }
                Gtk.onMain { [weak self] in
                    self?.toast(Localized.text("Added. They are in the model pill once they answer."))
                    MachineAgentsWindow.refresh(profileID: profileID)
                }
            }
        }
        adw_toast_overlay_add_toast(op(toastOverlay), toast)
    }

    /// Drive verbs for the agents a machine runs and the schedules it keeps.
    func driveMachine(_ verb: String, _ argument: String) -> Bool {
        let demo = DemoWorld.claudeProfile.id
        switch verb {
        case "scheduled":
            presentScheduled(profileID: argument.isEmpty ? nil : argument)
            FileHandle.standardOutput.write(Data("SCHEDULED \(scheduleBoard?.rows.count ?? -1)\n".utf8))
        case "schedule":
            Task {
                let servers = await MachineFeatures.schedulingServers()
                for server in servers {
                    guard let scheduling = server.backend as? any MachineScheduling,
                        let schedule = (try? await scheduling.machineSchedules())?.first(where: { $0.id == argument })
                    else { continue }
                    Gtk.onMain { [weak self] in
                        ScheduleDetailWindow.present(
                            profileID: server.profile.id, machine: server.profile.name, backend: server.backend,
                            schedule: schedule, parent: self?.window)
                        FileHandle.standardOutput.write(Data("SCHEDULE \(schedule.title) runs=\(schedule.runs.count)\n".utf8))
                    }
                    return
                }
                FileHandle.standardOutput.write(Data("SCHEDULE missing \(argument)\n".utf8))
            }
        case "asklater":
            let pane = activePane
            let phrase = argument
            if pane.composerText().isEmpty { pane.insertIntoComposer(Self.driveLaterQuestion) }
            askLater(from: pane)
            Gtk.after(900) {
                guard let dialog = AskLaterDialog.current else {
                    FileHandle.standardOutput.write(Data("ASKLATER no dialog\n".utf8))
                    return
                }
                if !phrase.isEmpty { dialog.type(phrase) }
                let line = dialog.sheet.understoodLine()
                FileHandle.standardOutput.write(
                    Data("ASKLATER \(line?.headline ?? "-") | \(line?.detail ?? "-") | \(dialog.sheet.confirmTitle())\n".utf8))
            }
        case "machineagents":
            presentMachineAgents(profileID: argument.isEmpty ? demo : argument)
        case "agent":
            presentMachineAgents(profileID: demo, card: argument.isEmpty ? "hermes" : argument)
        case "agentsignin":
            let id = argument.isEmpty ? "gemini" : argument
            presentMachineAgents(profileID: demo, card: id)
            Gtk.after(1_200) {
                guard let card = MachineWindowRegistry.existing(AgentCardWindow.key(demo, id)) as? AgentCardWindow
                else { return }
                card.startSignIn(card.agent?.signIn.first?.id ?? "")
            }
        case "registry":
            Task { [weak self] in
                let profiles = await ServerDirectory.shared.profiles()
                let id = argument.isEmpty ? demo : argument
                guard let profile = profiles.first(where: { $0.id == id }),
                    let backend = await ServerDirectory.shared.backend(for: profile)
                else { return }
                Gtk.onMain { [weak self] in
                    AgentRegistryWindow.present(profile: profile, backend: backend, parent: self?.window)
                }
            }
        case "agentnews":
            AgentNewsStore.markSeen([], profileID: demo)
            UserDefaults.standard.removeObject(forKey: AgentNewsStore.key)
            nudgeAgents()
        default:
            return false
        }
        return true
    }

    static let driveLaterQuestion = "What's new in AI today? Three lines, links."
}
