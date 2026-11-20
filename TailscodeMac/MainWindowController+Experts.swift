import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// Experts, one window per app: every machine's experts and the chosen one's page, opened from
    /// the sidebar's place, the View menu and an expert's mark wherever it is drawn.
    @discardableResult
    func presentExperts(selecting id: String? = nil) -> ExpertsWindow {
        let controller = expertsController()
        controller.present(selecting: id)
        return controller
    }

    private func expertsController() -> ExpertsWindow {
        if let expertsWindow { return expertsWindow }
        let controller = ExpertsWindow()
        controller.onNewTask = { [weak self, weak controller] row in
            self?.presentExpertTask(row, on: controller?.window)
        }
        controller.onEdit = { [weak self, weak controller] row in
            self?.editExpert(row, on: controller?.window)
        }
        controller.onCreateBlank = { [weak self, weak controller] profile in
            self?.newExpert(on: profile, skill: nil, host: controller?.window)
        }
        controller.onCreateFromSkill = { [weak self, weak controller] profile, skill in
            self?.newExpert(on: profile, skill: skill, host: controller?.window)
        }
        controller.onOpenChat = { [weak self] profileID, sessionID in
            self?.openExpertChat(profileID: profileID, sessionID: sessionID)
        }
        controller.onOpenSchedule = { [weak self] id in self?.presentScheduled(selecting: id) }
        controller.onHandFailure = { [weak self, weak controller] row, item in
            self?.handFailure(row, item, on: controller?.window)
        }
        controller.onToast = { [weak self] text in self?.toast(text) }
        expertsWindow = controller
        return controller
    }

    /// A task's conversation, opened where chats open, the main window brought forward first
    /// because the press was made in another window.
    func openExpertChat(profileID: String, sessionID: String) {
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
    func presentExpertTask(
        _ row: ExpertRow, on host: NSWindow? = nil, carry: ConversationBrief? = nil, prefill: String = ""
    ) -> ExpertTaskSheet? {
        guard let host = host ?? window else { return nil }
        if host === window, window?.isVisible != true { showWindow(nil) }
        return ExpertTaskSheet.present(on: host, row: row, carry: carry, prefill: prefill) { [weak self] row, started in
            self?.landTask(row, started)
        }
    }

    /// The task the machine made, opened in the focused pane the way a new chat opens.
    private func landTask(_ row: ExpertRow, _ started: ExpertTaskStarted) {
        guard let profile = ExpertDesk.shared.profile(row.profileID) else { return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let entry = SessionEntry(
            profileID: profile.id, profileName: profile.name, host: profile.baseURL.host ?? profile.name,
            backendType: profile.backend, session: started.session)
        sidebar.noteCreated(entry)
        toast(
            started.queued.map { Localized.text("%@ is on it, behind %d turns", row.expert.name, $0) }
                ?? ExpertWords.taskStarted(row.expert.name))
        ExpertDesk.shared.refreshSoon()
        Task { [weak self] in await self?.sidebar.refresh() }
    }

    /// Hand to an expert…: the experts every machine keeps, in a menu at the composer; a pick
    /// starts a task there with this conversation carried as a brief.
    func handToExpert(from pane: TranscriptViewController? = nil) {
        let pane = pane ?? transcript
        let rows = ExpertDesk.shared.board.rows
        let anchor: NSView? = pane.view.window == nil ? window?.contentView : pane.composer
        guard !rows.isEmpty, let anchor else {
            NSSound.beep()
            return
        }
        let menu = NSMenu(title: ExpertWords.handToExpert)
        let heading = NSMenuItem(title: ExpertWords.handToExpert, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let machines = Set(rows.map(\.profileID)).count
        for row in rows {
            let item = NSMenuItem(
                title: machines > 1 ? "\(row.expert.name) · \(row.machine)" : row.expert.name,
                action: #selector(expertMenuPicked(_:)), keyEquivalent: "")
            item.image = ExpertMarkView.image(row, side: 16)
            item.representedObject = ExpertMenuPick(row: row, pane: pane)
            item.target = self
            item.toolTip = row.state().text
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 16, y: anchor.bounds.height - 4), in: anchor)
    }

    @objc func expertMenuPicked(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? ExpertMenuPick else { return }
        chooseExpert(pick.row, from: pick.pane)
    }

    /// An expert chosen from inside a chat — the chooser's Experts section or Hand to an expert…:
    /// a new task there, carrying this conversation when it has anything to carry.
    func chooseExpert(_ row: ExpertRow, from pane: TranscriptViewController?) {
        var carry: ConversationBrief?
        if let pane, let entry = pane.currentEntry, let messages = pane.currentState?.messages, !messages.isEmpty {
            carry = ConversationBrief.make(title: entry.session.title, messages: messages, window: nil)
        }
        presentExpertTask(row, carry: carry)
    }

    /// Make an expert from this chat…: the machine drafts one from the conversation, then the form
    /// opens on the draft for review; nothing is made until Create.
    func makeExpertFromChat(from pane: TranscriptViewController? = nil) {
        let pane = pane ?? transcript
        guard let entry = pane.currentEntry, let host = window, Self.canMakeExpert(from: entry),
            let profile = ExpertDesk.shared.profile(entry.profileID),
            let keeping = ExpertDesk.shared.keeping(for: entry.profileID)
        else {
            NSSound.beep()
            return
        }
        let session = entry.session.id
        ExpertDraftingSheet.present(
            on: host, title: Localized.text("Drafting an expert from “%@”", entry.session.title),
            detail: Localized.text(
                "A fork of this conversation on %@, never saved, reads what the work needed. It takes a minute.",
                profile.name),
            work: { try await keeping.draftExpert(session: session, skill: nil) }
        ) { [weak self] draft in
            self?.reviewDraft(draft, on: profile, host: host)
        }
    }

    /// New expert on a machine, from one of its skills or blank.
    func newExpert(on profile: ConnectionProfile, skill: ExpertSkill?, host: NSWindow?) {
        guard let host = host ?? window else { return }
        guard let skill, let keeping = ExpertDesk.shared.keeping(for: profile.id) else {
            ExpertEditorSheet.present(on: host, profile: profile, editing: nil) { [weak self] made in
                self?.expertMade(made, profileID: profile.id)
            }
            return
        }
        ExpertDraftingSheet.present(
            on: host, title: Localized.text("Drafting an expert from the %@ skill", skill.name),
            detail: skill.description,
            work: { try await keeping.draftExpert(session: nil, skill: skill.name) }
        ) { [weak self] draft in
            self?.reviewDraft(draft, on: profile, host: host)
        }
    }

    private func reviewDraft(_ draft: ExpertDraft, on profile: ConnectionProfile, host: NSWindow) {
        ExpertEditorSheet.present(on: host, profile: profile, editing: nil, seed: draft) { [weak self] made in
            self?.expertMade(made, profileID: profile.id)
        }
    }

    private func expertMade(_ expert: MachineExpert, profileID: String) {
        toast(Localized.text("Made %@", expert.name))
        presentExperts(selecting: "\(profileID)·\(expert.id)")
    }

    func editExpert(_ row: ExpertRow, on host: NSWindow?) {
        guard let host = host ?? window, let profile = ExpertDesk.shared.profile(row.profileID) else { return }
        ExpertEditorSheet.present(on: host, profile: profile, editing: row.expert) { [weak self] saved in
            self?.toast(Localized.text("Saved %@", saved.name))
        }
    }

    /// A failing guard handed to its expert: a new task that starts with what failed.
    func handFailure(_ row: ExpertRow, _ item: ExpertGuard, on host: NSWindow?) {
        presentExpertTask(row, on: host, prefill: ExpertMaking.failureTask(item, machine: row.machine))
    }

    /// Finish task: the focused pane's task is debriefed by its machine.
    func finishExpertTask(from pane: TranscriptViewController? = nil) {
        (pane ?? transcript).debriefSlot.finish()
    }

    /// Whether the focused chat can be handed to an expert: an expert exists somewhere and the
    /// chat has something to carry.
    var canHandToExpert: Bool {
        !ExpertDesk.shared.board.isEmpty && currentEntry != nil
    }

    var canMakeExpertFromChat: Bool {
        guard let entry = currentEntry else { return false }
        return Self.canMakeExpert(from: entry)
    }

    /// Only a machine that answered can draft an expert, the same machines New expert offers, and
    /// never from a subagent's conversation.
    private static func canMakeExpert(from entry: SessionEntry) -> Bool {
        ExpertDesk.shared.makers.contains { $0.id == entry.profileID } && entry.session.agentID == nil
    }

    var canFinishExpertTask: Bool {
        guard let entry = currentEntry, entry.session.expertID != nil else { return false }
        return transcript.currentState?.status != .running && transcript.debriefSlot.offersFinish
    }

    /// `--open experts`, `expert[:<id>]`, `expert-task[:<id>]`, `expert-debrief`, `expert-editor[:<id>]`
    /// and `expert-make`: the surfaces on the demo world's machine, so they can be drawn and
    /// measured with no server behind them.
    func openExpertFixture(_ name: String, detail: String?) {
        ExpertDesk.shared.stageDemo()
        Task { @MainActor [weak self] in
            await MachineDesk.shared.refresh()
            await ExpertDesk.shared.refresh()
            guard let self else { return }
            let demo = DemoWorld.claudeProfile
            let rows = ExpertDesk.shared.board.rows
            let chosen = detail.flatMap { id in rows.first { $0.expert.id == id } } ?? rows.first
            switch name {
            case "experts":
                self.presentExperts()
            case "expert":
                self.presentExperts(selecting: chosen?.id)
            case "expert-task":
                let host = self.presentExperts(selecting: chosen?.id).window
                try? await Task.sleep(for: .milliseconds(300))
                if let chosen { self.presentExpertTask(chosen, on: host) }
            case "expert-editor":
                let host = self.presentExperts(selecting: chosen?.id).window
                try? await Task.sleep(for: .milliseconds(300))
                if let chosen, let host { self.editExpert(chosen, on: host) }
            case "expert-make":
                let host = self.presentExperts().window
                try? await Task.sleep(for: .milliseconds(300))
                guard let host, let keeping = ExpertDesk.shared.keeping(for: demo.id),
                    let draft = try? await keeping.draftExpert(session: "demo-c3", skill: nil)
                else { return }
                self.reviewDraft(draft, on: demo, host: host)
            case "expert-debrief":
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
        host.title = ExpertWords.title
        host.isReleasedWhenClosed = false
        let slot = ExpertDebriefSlot()
        let column = FillingStack(topDown: false)
        column.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        column.addArrangedSubview(slot)
        host.contentView = MacDialogs.scrollColumn(holding: column)
        host.center()
        host.makeKeyAndOrderFront(nil)
        machineFixtureWindow = host
        guard let backend = ExpertDesk.shared.keeping(for: DemoWorld.claudeProfile.id) else { return }
        Task {
            guard let debrief = try? await backend.expertDebrief(sessionID: "demo-c3"),
                let row = ExpertDesk.shared.row(profileID: DemoWorld.claudeProfile.id, expertID: debrief.expertID)
            else { return }
            slot.stage(debrief, row: row)
        }
    }
}

/// What an expert picked from a menu carries: the expert, and the pane whose conversation it is
/// handed.
final class ExpertMenuPick: NSObject {
    let row: ExpertRow
    weak var pane: TranscriptViewController?

    init(row: ExpertRow, pane: TranscriptViewController?) {
        self.row = row
        self.pane = pane
    }
}

/// A draft being made on the machine: a spinner, what is being read, and Cancel. The draft opens
/// in the form once it arrives; a draft that could not be made says why.
@MainActor
enum ExpertDraftingSheet {
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
        let cancel = NSButton(title: ExpertWords.cancel, target: nil, action: nil)
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
                heading.stringValue = ExpertWords.draftFailed
                words.stringValue = AgentErrorText.readable(error)
                words.textColor = MacTheme.Color.danger
                cancel.title = Localized.text("Close")
            }
        }
        let actions = ExpertSheetActions(
            done: { [weak host, weak sheet] in
                job.cancel()
                if let sheet { host?.endSheet(sheet) }
            }, copy: {})
        cancel.target = actions
        cancel.action = #selector(ExpertSheetActions.doneTapped)
        objc_setAssociatedObject(sheet, &ExpertSheetActions.key, actions, .OBJC_ASSOCIATION_RETAIN)
        host.beginSheet(sheet)
    }
}
