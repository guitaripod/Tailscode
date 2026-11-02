import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// Scheduled, one window per app: every machine's schedules, opened from the sidebar's entry,
    /// the View menu and a server's Scheduled line.
    @discardableResult
    func presentScheduled(selecting id: String? = nil) -> ScheduledWindow {
        let controller = scheduledController()
        controller.present(selecting: id)
        return controller
    }

    private func scheduledController() -> ScheduledWindow {
        if let scheduledWindow { return scheduledWindow }
        let controller = ScheduledWindow()
        controller.onOpenChat = { [weak self] profileID, sessionID in
            self?.openScheduledChat(profileID: profileID, sessionID: sessionID)
        }
        controller.onAskLater = { [weak self, weak controller] in
            guard let self, let host = controller?.window else { return }
            self.presentAskLater(text: "", on: host)
        }
        controller.onToast = { [weak self] text in self?.toast(text) }
        scheduledWindow = controller
        return controller
    }

    /// A run's conversation, opened where chats open. The main window comes forward first, because
    /// the press was made in the Scheduled window.
    func openScheduledChat(profileID: String, sessionID: String) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        openSession(withID: sessionID)
    }

    /// The machine and aim of the focused chat, or the first machine that keeps schedules when no
    /// chat is open — the one a question asked later from here would be asked on.
    private func laterAim(from pane: TranscriptViewController?) -> AskLaterSheetController.Aim? {
        if let pane, let entry = pane.currentEntry,
            let profile = MachineDesk.shared.profile(entry.profileID)
                ?? ServerDirectory.shared.profiles.first(where: { $0.id == entry.profileID })
        {
            return AskLaterSheetController.Aim(
                profile: profile, model: pane.composer.activeSelection, effort: pane.composer.activeEffort,
                directory: entry.session.directory, sessionID: entry.session.id)
        }
        let servers = MachineDesk.shared.servers()
        guard let server = servers.first(where: { MachineDesk.shared.keepsSchedules($0.profile.id) }) ?? servers.first
        else { return nil }
        return AskLaterSheetController.Aim(
            profile: server.profile, model: nil, effort: nil, directory: nil, sessionID: nil)
    }

    /// ⌥⏎ and Chat ▸ Ask Later…: the words in the focused chat's box, asked later by its machine.
    func presentAskLater(from pane: TranscriptViewController? = nil) {
        let pane = pane ?? transcript
        presentAskLater(text: pane.composer.currentText, on: window, pane: pane)
    }

    @discardableResult
    func presentAskLater(
        text: String, on host: NSWindow?, pane: TranscriptViewController? = nil, phrase: String = "",
        aim fixed: AskLaterSheetController.Aim? = nil, sessionID: String? = nil
    ) -> AskLaterSheetController? {
        guard let host, var aim = fixed ?? laterAim(from: pane) else {
            NSSound.beep()
            return nil
        }
        if let sessionID { aim.sessionID = sessionID }
        let catalog = ModelCatalogStore.cached(aim.profile.id)
        let modelWord = aim.model.map { ModelBadge.word(for: $0, in: catalog) }
        let scheduledText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AskLaterSheetController.present(
            on: host, text: text, aim: aim, modelWord: modelWord,
            keepsSchedules: MachineDesk.shared.keepsSchedules(aim.profile.id), phrase: phrase
        ) { [weak self, weak pane] made in
            if let pane, pane.composer.currentText.trimmingCharacters(in: .whitespacesAndNewlines) == scheduledText,
                !scheduledText.isEmpty, made.text == scheduledText
            {
                pane.composer.clearAfterScheduling()
            }
            self?.toast(Localized.text("Scheduled on %@: %@", aim.profile.name, made.title))
        }
    }

    /// Ask this again…: a prompt from the transcript, asked again later in this same chat.
    func askAgain(_ words: String, in pane: TranscriptViewController) {
        presentAskLater(text: words, on: window, pane: pane)
    }

    /// Start a chat with <agent>: the agent's model remembered as that machine's choice, and a new
    /// chat opened there, which then opens on it — the road a carried pick already takes.
    func startAgentChat(on profile: ConnectionProfile, agent: MachineAgent) {
        let model = agent.currentModel ?? agent.models.first?.id ?? "default"
        let selection = ModelSelection(providerID: agent.id, modelID: model)
        ModelFleet.adopt(
            ModelPick(
                profileID: profile.id, selection: selection, isElsewhere: true, serverName: profile.name,
                modelName: agent.name))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        createChat(on: profile, directory: nil) { [weak self] failure in
            if let failure { self?.toast(failure.title) }
        }
    }

    @discardableResult
    func presentAgentCard(profile: ConnectionProfile, agentID: String, on host: NSWindow? = nil) -> AgentCardSheet? {
        guard let host = host ?? serversWindow?.window ?? window else { return nil }
        let card = AgentCardSheet.present(on: host, profile: profile, agentID: agentID)
        card.onStartChat = { [weak self] profile, agent in self?.startAgentChat(on: profile, agent: agent) }
        card.onToast = { [weak self] text in self?.toast(text) }
        return card
    }

    @discardableResult
    func presentAgentRegistry(profile: ConnectionProfile, on host: NSWindow? = nil) -> AgentRegistrySheet? {
        guard let host = host ?? serversWindow?.window ?? window else { return nil }
        let sheet = AgentRegistrySheet.present(on: host, profile: profile)
        sheet.onToast = { [weak self] text in self?.toast(text) }
        return sheet
    }

    /// `--open scheduled`, `schedule:<id>`, `ask-later`, `machine-agents`, `agent:<id>` and
    /// `agent-registry`: the screens on the demo world's machine, so they can be drawn and measured
    /// with no server behind them.
    func openMachineFixture(_ name: String, detail: String?) {
        MachineDesk.shared.stageDemo()
        Task { @MainActor [weak self] in
            await MachineDesk.shared.refresh()
            guard let self else { return }
            let demo = DemoWorld.claudeProfile
            switch name {
            case "scheduled":
                self.presentScheduled()
            case "schedule":
                self.presentScheduled(selecting: detail ?? "demo-s1")
            case "ask-later":
                let aim = AskLaterSheetController.Aim(
                    profile: demo, model: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
                    effort: nil, directory: nil, sessionID: nil)
                self.presentAskLater(
                    text: detail ?? "What's new in AI today? Three lines, links.", on: self.window,
                    phrase: "weekdays 7:30", aim: aim)
            case "machine-agents":
                self.presentMachineFixture()
            case "agent":
                let host = self.presentMachineFixture()
                try? await Task.sleep(for: .milliseconds(300))
                self.presentAgentCard(profile: demo, agentID: detail ?? "hermes", on: host)
            case "agent-registry":
                let host = self.presentMachineFixture()
                try? await Task.sleep(for: .milliseconds(300))
                self.presentAgentRegistry(profile: demo, on: host)
            default:
                break
            }
        }
    }

    /// The demo machine's Agents section on its own, laid out the way its row in Servers lays it
    /// out, so the section and the sheets it opens can be drawn without anybody's fleet.
    @discardableResult
    func presentMachineFixture() -> NSWindow {
        if let machineFixtureWindow {
            machineFixtureWindow.makeKeyAndOrderFront(nil)
            return machineFixtureWindow
        }
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        host.title = DemoWorld.claudeProfile.name
        host.isReleasedWhenClosed = false
        let section = MachineAgentsSection(profile: DemoWorld.claudeProfile)
        section.onOpenAgent = { [weak self, weak host] profile, id in
            self?.presentAgentCard(profile: profile, agentID: id, on: host)
        }
        section.onOpenRegistry = { [weak self, weak host] profile in
            self?.presentAgentRegistry(profile: profile, on: host)
        }
        section.onOpenScheduled = { [weak self] _ in self?.presentScheduled() }
        section.onToast = { [weak self] text in self?.toast(text) }
        let column = FillingStack(views: [section])
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        host.contentView = MacDialogs.scrollColumn(holding: column)
        host.center()
        host.makeKeyAndOrderFront(nil)
        machineFixtureWindow = host
        return host
    }

    /// The desk starts with the window, and the sidebar's two places and the news line follow it.
    func startMachineDesk() {
        let staged = ["--selftest", "--bench"]
        guard !CommandLine.arguments.contains(where: staged.contains) else { return }
        MachineDesk.shared.start()
    }
}

extension ComposerView {
    /// The box is let go once its words were handed to the machine for later, the way a send lets
    /// it go: the draft with it, so it does not come back on the next visit.
    func clearAfterScheduling() {
        setEditorText("", caretAtEnd: true)
        if let draftScope { DraftStore.clear(draftScope) }
    }
}
