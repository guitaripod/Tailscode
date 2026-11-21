import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// Masters, one window per app: every machine's masters and the chosen one's page, opened from
    /// the sidebar's place, the View menu and a master's mark wherever it is drawn.
    @discardableResult
    func presentMasters(selecting id: String? = nil) -> MastersWindow {
        let controller = mastersController()
        controller.present(selecting: id)
        return controller
    }

    private func mastersController() -> MastersWindow {
        if let mastersWindow { return mastersWindow }
        let controller = MastersWindow()
        controller.onNewTask = { [weak self, weak controller] row in
            self?.presentMasterTask(row, on: controller?.window)
        }
        controller.onEdit = { [weak self, weak controller] row in
            self?.editMaster(row, on: controller?.window)
        }
        controller.onCreateBlank = { [weak self, weak controller] profile in
            self?.newMaster(on: profile, skill: nil, host: controller?.window)
        }
        controller.onCreateFromSkill = { [weak self, weak controller] profile, skill in
            self?.newMaster(on: profile, skill: skill, host: controller?.window)
        }
        controller.onOpenChat = { [weak self] profileID, sessionID in
            self?.openMasterChat(profileID: profileID, sessionID: sessionID)
        }
        controller.onOpenSchedule = { [weak self] id in self?.presentScheduled(selecting: id) }
        controller.onHandFailure = { [weak self, weak controller] row, item in
            self?.handFailure(row, item, on: controller?.window)
        }
        controller.onToast = { [weak self] text in self?.toast(text) }
        mastersWindow = controller
        return controller
    }

    /// A task's conversation, opened where chats open, the main window brought forward first
    /// because the press was made in another window.
    func openMasterChat(profileID: String, sessionID: String) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let entry = sidebar.allEntries.first(where: { $0.profileID == profileID && $0.session.id == sessionID }) {
            sidebar.open(entry)
            return
        }
        openSession(withID: sessionID)
    }

    /// New task: the sheet over the window it was asked from, the conversation opened once the
    /// machine has it.
    @discardableResult
    func presentMasterTask(
        _ row: MasterRow, on host: NSWindow? = nil, carry: ConversationBrief? = nil, prefill: String = ""
    ) -> MasterTaskSheet? {
        guard let host = host ?? window else { return nil }
        if host === window, window?.isVisible != true { showWindow(nil) }
        return MasterTaskSheet.present(on: host, row: row, carry: carry, prefill: prefill) { [weak self] row, started in
            self?.landTask(row, started)
        }
    }

    /// The task the machine made, opened in the focused pane the way a new chat opens.
    private func landTask(_ row: MasterRow, _ started: ExpertTaskStarted) {
        guard let profile = MasterDesk.shared.profile(row.profileID) else { return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let entry = SessionEntry(
            profileID: profile.id, profileName: profile.name, host: profile.baseURL.host ?? profile.name,
            backendType: profile.backend, session: started.session)
        sidebar.noteCreated(entry)
        toast(
            started.queued.map { Localized.text("%@ is on it, behind %d turns", row.master.name, $0) }
                ?? MasterWords.taskStarted(row.master.name))
        MasterDesk.shared.refreshSoon()
        Task { [weak self] in await self?.sidebar.refresh() }
    }

    /// Hand to a master…: the masters every machine keeps, in a menu at the composer; a pick
    /// starts a task there with this conversation carried as a brief.
    func handToMaster(from pane: TranscriptViewController? = nil) {
        let pane = pane ?? transcript
        let rows = MasterDesk.shared.board.rows
        let anchor: NSView? = pane.view.window == nil ? window?.contentView : pane.composer
        guard !rows.isEmpty, let anchor else {
            NSSound.beep()
            return
        }
        let menu = NSMenu(title: MasterWords.handToMaster)
        let heading = NSMenuItem(title: MasterWords.handToMaster, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let machines = Set(rows.map(\.profileID)).count
        for row in rows {
            let item = NSMenuItem(
                title: machines > 1 ? "\(row.master.name) · \(row.machine)" : row.master.name,
                action: #selector(masterMenuPicked(_:)), keyEquivalent: "")
            item.image = MasterMarkView.image(row, side: 16)
            item.representedObject = MasterMenuPick(row: row, pane: pane)
            item.target = self
            item.toolTip = row.state().text
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 16, y: anchor.bounds.height - 4), in: anchor)
    }

    @objc func masterMenuPicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? MasterMenuPick else { return }
        chooseMaster(pick.row, from: pick.pane)
    }

    /// A master chosen from inside a chat — the chooser's Masters section or Hand to a master…:
    /// a new task there, carrying this conversation when it has anything to carry.
    func chooseMaster(_ row: MasterRow, from pane: TranscriptViewController?) {
        var carry: ConversationBrief?
        if let pane, let entry = pane.currentEntry, let messages = pane.currentState?.messages, !messages.isEmpty {
            carry = ConversationBrief.make(title: entry.session.title, messages: messages, window: nil)
        }
        presentMasterTask(row, carry: carry)
    }

    /// Make a master from this chat…: the machine drafts one from the conversation, then the form
    /// opens on the draft for review; nothing is made until Create.
    func makeMasterFromChat(from pane: TranscriptViewController? = nil) {
        let pane = pane ?? transcript
        guard let entry = pane.currentEntry, let host = window, Self.canMakeMaster(from: entry),
            let profile = MasterDesk.shared.profile(entry.profileID),
            let keeping = MasterDesk.shared.keeping(for: entry.profileID)
        else {
            NSSound.beep()
            return
        }
        let session = entry.session.id
        MasterDraftingSheet.present(
            on: host, title: Localized.text("Drafting a master from “%@”", entry.session.title),
            detail: Localized.text(
                "A fork of this conversation on %@, never saved, reads what the work needed. It takes a minute.",
                profile.name),
            work: { try await keeping.draftExpert(session: session, skill: nil) }
        ) { [weak self] draft in
            self?.reviewDraft(draft, on: profile, host: host)
        }
    }

    /// New master on a machine, from one of its skills or blank.
    func newMaster(on profile: ConnectionProfile, skill: ExpertSkill?, host: NSWindow?) {
        guard let host = host ?? window else { return }
        guard let skill, let keeping = MasterDesk.shared.keeping(for: profile.id) else {
            MasterEditorSheet.present(on: host, profile: profile, editing: nil) { [weak self] made in
                self?.masterMade(made, profileID: profile.id)
            }
            return
        }
        MasterDraftingSheet.present(
            on: host, title: Localized.text("Drafting a master from the %@ skill", skill.name),
            detail: skill.description,
            work: { try await keeping.draftExpert(session: nil, skill: skill.name) }
        ) { [weak self] draft in
            self?.reviewDraft(draft, on: profile, host: host)
        }
    }

    private func reviewDraft(_ draft: ExpertDraft, on profile: ConnectionProfile, host: NSWindow) {
        MasterEditorSheet.present(on: host, profile: profile, editing: nil, seed: draft) { [weak self] made in
            self?.masterMade(made, profileID: profile.id)
        }
    }

    private func masterMade(_ master: MachineExpert, profileID: String) {
        toast(Localized.text("Made %@", master.name))
        presentMasters(selecting: "\(profileID)·\(master.id)")
    }

    func editMaster(_ row: MasterRow, on host: NSWindow?) {
        guard let host = host ?? window, let profile = MasterDesk.shared.profile(row.profileID) else { return }
        MasterEditorSheet.present(on: host, profile: profile, editing: row.master) { [weak self] saved in
            self?.toast(Localized.text("Saved %@", saved.name))
        }
    }

    /// A failing guard handed to its master: a new task that starts with what failed.
    func handFailure(_ row: MasterRow, _ item: ExpertGuard, on host: NSWindow?) {
        presentMasterTask(row, on: host, prefill: MasterMaking.failureTask(item, machine: row.machine))
    }

    /// Finish task: the focused pane's task is debriefed by its machine.
    func finishExpertTask(from pane: TranscriptViewController? = nil) {
        (pane ?? transcript).debriefSlot.finish()
    }

    /// Whether the focused chat can be handed to a master: a master exists somewhere and the
    /// chat has something to carry.
    var canHandToMaster: Bool {
        !MasterDesk.shared.board.isEmpty && currentEntry != nil
    }

    var canMakeMasterFromChat: Bool {
        guard let entry = currentEntry else { return false }
        return Self.canMakeMaster(from: entry)
    }

    /// Only a machine that answered can draft a master, the same machines New master offers, and
    /// never from a subagent's conversation.
    private static func canMakeMaster(from entry: SessionEntry) -> Bool {
        MasterDesk.shared.makers.contains { $0.id == entry.profileID } && entry.session.agentID == nil
    }

    var canFinishMasterTask: Bool {
        guard let entry = currentEntry, entry.session.expertID != nil else { return false }
        return transcript.currentState?.status != .running && transcript.debriefSlot.offersFinish
    }

    /// `--open masters`, `master[:<id>]`, `master-task[:<id>]`, `master-debrief`, `master-editor[:<id>]`
    /// and `master-make`: the surfaces on the demo world's machine, so they can be drawn and
    /// measured with no server behind them.
    func openMasterFixture(_ name: String, detail: String?) {
        MasterDesk.shared.stageDemo()
        Task { @MainActor [weak self] in
            await MachineDesk.shared.refresh()
            await MasterDesk.shared.refresh()
            guard let self else { return }
            let demo = DemoWorld.claudeProfile
            let rows = MasterDesk.shared.board.rows
            let chosen = detail.flatMap { id in rows.first { $0.master.id == id } } ?? rows.first
            switch name {
            case "masters":
                self.presentMasters()
            case "master":
                self.presentMasters(selecting: chosen?.id)
            case "master-task":
                let host = self.presentMasters(selecting: chosen?.id).window
                try? await Task.sleep(for: .milliseconds(300))
                if let chosen { self.presentMasterTask(chosen, on: host) }
            case "master-editor":
                let host = self.presentMasters(selecting: chosen?.id).window
                try? await Task.sleep(for: .milliseconds(300))
                if let chosen, let host { self.editMaster(chosen, on: host) }
            case "master-make":
                let host = self.presentMasters().window
                try? await Task.sleep(for: .milliseconds(300))
                guard let host, let keeping = MasterDesk.shared.keeping(for: demo.id),
                    let draft = try? await keeping.draftExpert(session: "demo-c3", skill: nil)
                else { return }
                self.reviewDraft(draft, on: demo, host: host)
            case "master-debrief":
                self.presentDebriefFixture()
            default:
                break
            }
        }
    }

    /// The demo's open debrief on its own, drawn the way a task's end draws it.
    private func presentDebriefFixture() {
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        host.title = MasterWords.title
        host.isReleasedWhenClosed = false
        let slot = MasterDebriefSlot()
        let column = FillingStack(topDown: false)
        column.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        column.addArrangedSubview(slot)
        host.contentView = MacDialogs.scrollColumn(holding: column)
        host.center()
        host.makeKeyAndOrderFront(nil)
        machineFixtureWindow = host
        guard let backend = MasterDesk.shared.keeping(for: DemoWorld.claudeProfile.id) else { return }
        Task {
            guard let debrief = try? await backend.expertDebrief(sessionID: DemoWorld.demoReviewedTaskID),
                let row = MasterDesk.shared.row(profileID: DemoWorld.claudeProfile.id, expertID: debrief.expertID)
            else { return }
            slot.stage(debrief, row: row)
        }
    }
}

/// What a master picked from a menu carries: the master, and the pane whose conversation it is
/// handed.
final class MasterMenuPick: NSObject {
    let row: MasterRow
    weak var pane: TranscriptViewController?

    init(row: MasterRow, pane: TranscriptViewController?) {
        self.row = row
        self.pane = pane
    }
}

/// A draft being made on the machine: a spinner, what is being read, and Cancel. The draft opens
/// in the form once it arrives; a draft that could not be made says why.
@MainActor
enum MasterDraftingSheet {
    static func present(
        on host: NSWindow, title: String, detail: String,
        work: @escaping @Sendable () async throws -> ExpertDraft,
        onDraft: @escaping @MainActor (ExpertDraft) -> Void
    ) {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 180), styleMask: [.titled], backing: .buffered,
            defer: false)
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = MacTheme.Ramp.font(.cardTitle)
        let words = NSTextField(wrappingLabelWithString: detail)
        words.font = MacTheme.Ramp.font(.panelDetail)
        words.textColor = MacTheme.Color.secondaryLabel
        let spinner = NSProgressIndicator()
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        let cancel = NSButton(title: MasterWords.cancel, target: nil, action: nil)
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1B}"
        let buttons = NSStackView(views: [NSView(), cancel])
        buttons.orientation = .horizontal
        let column = FillingStack(topDown: false)
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        for view in [heading, words, spinner, buttons] as [NSView] { column.addArrangedSubview(view) }
        sheet.contentView = column
        let job = Task { @MainActor in
            do {
                let draft = try await work()
                guard !Task.isCancelled else { return }
                host.endSheet(sheet)
                onDraft(draft)
            } catch {
                guard !Task.isCancelled else { return }
                spinner.stopAnimation(nil)
                spinner.isHidden = true
                heading.stringValue = MasterWords.draftFailed
                words.stringValue = AgentErrorText.readable(error)
                words.textColor = MacTheme.Color.danger
                cancel.title = Localized.text("Close")
            }
        }
        let actions = MasterSheetActions(
            done: { [weak host, weak sheet] in
                job.cancel()
                if let sheet { host?.endSheet(sheet) }
            }, copy: {})
        cancel.target = actions
        cancel.action = #selector(MasterSheetActions.doneTapped)
        objc_setAssociatedObject(sheet, &MasterSheetActions.key, actions, .OBJC_ASSOCIATION_RETAIN)
        host.beginSheet(sheet)
    }
}
