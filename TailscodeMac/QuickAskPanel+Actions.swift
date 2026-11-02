import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension QuickAskPanel {
    /// What this panel can fetch for a template: the screen where the system's capture can be
    /// run, the chat list it was handed, and paths on this disk when the aimed machine is this
    /// Mac and the build can look inside a folder.
    var surface: QuickAskSurfaceAbilities {
        .desktop(screen: MacScreenGrab.isAvailable, localFiles: isLocalAim)
    }

    var isLocalAim: Bool {
        #if TAILSCODE_MAS
            return false
        #else
            return QuickAskLocal.isThisMachine(targetServer)
        #endif
    }

    /// An action, picked: its aim first, because moving the machine hands back that machine's own
    /// draft, then whatever its template has to fetch, one thing at a time, and only then the
    /// words. A copied-thing action reads the pasteboard now — the card was drawn from its types
    /// alone — and a pasteboard that changed since then redraws the card instead.
    func run(_ action: QuickAskAction, copied errand: Bool, typed: String? = nil) {
        guard !asking else { return }
        releaseHold()
        gathering = nil
        var offer: ClipboardOffer?
        var fingerprint: String?
        if errand {
            guard let copied else { return }
            guard copied.fingerprint == Self.pasteboardFingerprint() else {
                readCopied()
                return
            }
            offer = pasteboardOffer()
            fingerprint = copied.fingerprint
        }
        applyAim(of: action)
        var gathering = QuickAskGathering(action: action)
        gathering.fingerprint = fingerprint
        gathering.fill.typed = typed
        if let offer {
            if action.offer == .files, isLocalAim, !offer.paths.isEmpty {
                gathering.fill.clipboard = QuickAskLocal.mention(offer.paths)
            } else {
                let plan = PasteIntake.plan(
                    for: offer, abilities: abilities, alreadyNamed: pastedImageCount)
                pastedImageCount = plan.named
                gathering.fill.clipboard = plan.text
                gathering.copiedAttachments = plan.attachments
                if let notice = plan.notices.first { setStatus(notice) }
            }
        } else if action.offer == .always {
            QuickAskStarterRecents.record(action.id)
        }
        self.gathering = gathering
        continueGathering()
    }

    /// The action's machine, model and level, held for this one question. The send stamps the
    /// conversation with the aim in force, so the aim really moves, and `hold` remembers what to
    /// put back.
    func applyAim(of action: QuickAskAction) {
        guard let aim = action.aim else { return }
        let profileID = aim.profileID(among: servers) ?? targetServer.id
        var hold = QuickAskAimHold.begin(profileIDs: [targetServer.id, profileID])
        if profileID != targetServer.id, servers.contains(where: { $0.id == profileID }) {
            self.aim(at: profileID)
        }
        if let selection = aim.selection {
            QuickAskDefaults.recordModel(selection, forProfileID: profileID)
        }
        if let effort = aim.effort { QuickAskDefaults.recordEffort(effort, forProfileID: profileID) }
        QuickAskDefaults.record(profileID: profileID)
        refreshAim()
        hold.settle()
        self.hold = hold
    }

    /// Hands the person's own aim back once the question an action aimed has left, or the action
    /// was set aside — and, while the panel stays, the machine they were on with it.
    func releaseHold(retargeting: Bool = true) {
        guard let hold else { return }
        self.hold = nil
        hold.release()
        guard retargeting else { return }
        if let back = QuickAskDefaults.lastProfileID, back != targetServer.id,
            servers.contains(where: { $0.id == back })
        {
            aim(at: back)
        }
        refreshAim()
    }

    /// Emptying the box is setting the action aside, so its aim goes with its words.
    func releaseHoldIfEmptied() {
        guard hold != nil, gathering == nil, editor.text.isEmpty, attachments.isEmpty else { return }
        releaseHold()
    }

    func continueGathering() {
        guard var gathering else { return }
        guard let next = gathering.awaiting else {
            finishGathering()
            return
        }
        switch next {
        case .session:
            renderStarters()
        case .screen:
            grab { [weak self] picture in
                guard let self, var current = self.gathering else { return }
                guard let picture else {
                    self.cancelGathering()
                    return
                }
                current.attachments.append(picture)
                current.advance()
                self.gathering = current
                self.continueGathering()
            }
        case .file, .photo:
            let chooser = NSOpenPanel()
            chooser.allowsMultipleSelection = true
            chooser.canChooseDirectories = false
            chooser.beginSheetModal(for: self) { [weak self] response in
                guard let self, var current = self.gathering else { return }
                guard response == .OK, !chooser.urls.isEmpty else {
                    self.cancelGathering()
                    return
                }
                let paths = chooser.urls.map(\.path)
                if self.isLocalAim {
                    current.mentions += paths
                } else {
                    for path in paths {
                        switch AttachmentIntake.read(path: path) {
                        case .success(let attachment): current.attachments.append(attachment)
                        case .failure(let refusal): self.setStatus(refusal.message)
                        }
                    }
                }
                current.advance()
                self.gathering = current
                self.continueGathering()
            }
        case .camera:
            gathering.advance()
            self.gathering = gathering
            continueGathering()
        }
    }

    /// The words land, the caret goes where the template left room, what was fetched rides as
    /// chips — and an action the person wrote to send at once is sent.
    func finishGathering() {
        guard let gathering else { return }
        self.gathering = nil
        let composed = gathering.composed()
        editor.setText(composed.text, caretAtEnd: true)
        editor.placeCaret(at: composed.caret)
        let fetched = gathering.attachments + gathering.copiedAttachments
        if !fetched.isEmpty {
            attachments.append(contentsOf: fetched)
            syncAttachments()
        }
        if let fingerprint = gathering.fingerprint { QuickAskClipboardMemory.settle(fingerprint) }
        renderStarters()
        editor.focus()
        guard gathering.action.sends,
            QuickAskComposition.canSend(text: editor.text, attachments: attachments.count)
        else { return }
        submit()
    }

    func cancelGathering() {
        guard gathering != nil else { return }
        gathering = nil
        releaseHold()
        renderStarters()
        refreshStarterVisibility()
        editor.focus()
        setStatus(Localized.text("Set aside — nothing was written."))
    }

    func pickSession(_ entry: SessionEntry) {
        guard var current = gathering, current.awaiting == .session else { return }
        current.fill.session = QuickAskSessionReference.words(for: entry)
        current.advance()
        gathering = current
        continueGathering()
    }

    /// The panel steps out of the way, the system draws the drag, and the picture comes back as a
    /// chip; a drag called off leaves the question as it was.
    func grabScreen() {
        guard !asking, gathering == nil else { return }
        guard abilities.vision else {
            setStatus(Localized.text("This model can't see pictures."))
            return
        }
        grab { [weak self] picture in
            guard let self, let picture else { return }
            self.attachments.append(picture)
            self.syncAttachments()
        }
    }

    private func grab(then done: @escaping @MainActor (PendingAttachment?) -> Void) {
        guard MacScreenGrab.isAvailable else {
            setStatus(Localized.text("This build can't capture the screen."))
            done(nil)
            return
        }
        orderOut(nil)
        MacScreenGrab.grab { [weak self] outcome in
            guard let self else { return }
            NSApp.activate()
            self.makeKeyAndOrderFront(nil)
            self.editor.focus()
            switch outcome {
            case .picture(let picture): done(picture)
            case .cancelled:
                self.setStatus(Localized.text("The drag was called off."))
                done(nil)
            case .failed(let reason):
                self.setStatus(reason)
                done(nil)
            }
        }
    }

    /// The same question to every party slot that can answer, each its own chat on the machine
    /// that runs it. Fewer than two is said rather than quietly sent as one ordinary question.
    func submitToParty() {
        guard !asking, gathering == nil else { return }
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickAskComposition.canSend(text: text, attachments: attachments.count) else { return }
        let targets = QuickAskParty.targets(partyCards())
        guard targets.count >= 2 else {
            setStatus(Localized.text("The party needs two filled slots that can answer."))
            return
        }
        let server = targetServer
        let question = QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: ServerDirectory.shared.backend(for: server)?
                .resolvesCommandsFromPromptText == true)
        if case .command = question.kind {
            setStatus(Localized.text("A command belongs to one machine — send it with enter."))
            return
        }
        let seats = targets.map { target in
            QuickAskPartySend.Seat(
                profileID: target.profileID, model: target.preset.selection,
                effort: target.preset.applied(
                    currentEffort: nil, models: ModelCatalogStore.cached(target.profileID),
                    agentOptions: servers.first { $0.id == target.profileID }
                        .flatMap { ServerDirectory.shared.backend(for: $0)?.reasoningEffortOptions }
                        ?? []
                ).level,
                word: target.word)
        }
        let onOffer = copied?.fingerprint
        asking = true
        dismissCompletion()
        editor.isEditable = false
        machinePill.isEnabled = false
        dialPopover?.close()
        partyPopover?.close()
        makeRoomPopover?.close()
        dialPill.isEnabled = false
        attachButton.isEnabled = false
        screenButton.isEnabled = false
        sendButton.isEnabled = false
        refreshStarterVisibility()
        setStatus(Localized.text("Asking the party — %@ models…", "\(seats.count)"))
        onAskParty(QuickAskPartySend(seats: seats, send: question, attachments: attachments)) {
            [weak self] failure in
            guard let self else { return }
            guard let failure else {
                if let onOffer { QuickAskClipboardMemory.settle(onOffer) }
                DraftStore.clear(.quickAsk(profileID: server.id))
                self.close()
                return
            }
            self.asking = false
            self.editor.isEditable = true
            self.machinePill.isEnabled = true
            self.dialPill.isEnabled = true
            self.attachButton.isEnabled = true
            self.screenButton.isEnabled = true
            self.refreshSend()
            self.setStatus("\(failure.title) — \(failure.detail)")
            self.refreshStarterVisibility()
            self.editor.focus()
        }
    }

    /// The aim showing now, as an action would keep it.
    func currentAim() -> QuickAskActionAim {
        let server = targetServer
        return QuickAskActionAim(
            server: server.id, model: QuickAskDefaults.model(forProfileID: server.id)?.rawValue,
            effort: QuickAskDefaults.effort(forProfileID: server.id))
    }

    /// An aim said the way the strip and the dial say it: machine, model, level.
    func aimWords(_ aim: QuickAskActionAim) -> String {
        let profileID = aim.profileID(among: servers)
        var parts: [String] = []
        if let profile = servers.first(where: { $0.id == profileID }) {
            parts.append(profile.name)
        } else if let server = aim.server {
            parts.append(server)
        }
        if let selection = aim.selection {
            parts.append(
                ModelBadge.word(
                    for: selection, in: ModelCatalogStore.cached(profileID ?? targetServer.id)))
        }
        if let effort = aim.effort { parts.append(effort) }
        return parts.isEmpty ? Localized.text("The aim in force") : parts.joined(separator: " · ")
    }

    /// What a right click on an action offers: change it, move it, put it away, or start another.
    func actionMenu(for action: QuickAskAction?) -> NSMenu {
        let menu = NSMenu()
        if let action {
            let id = action.id
            menu.addItem(ClosureMenuItem(title: Localized.text("Edit…")) { [weak self] in
                self?.editAction(id: id)
            })
            menu.addItem(ClosureMenuItem(title: Localized.text("Move earlier")) {
                QuickAskActions.move(id: id, by: -1)
            })
            menu.addItem(ClosureMenuItem(title: Localized.text("Move later")) {
                QuickAskActions.move(id: id, by: 1)
            })
            menu.addItem(
                ClosureMenuItem(
                    title: action.isBuiltIn ? Localized.text("Hide") : Localized.text("Delete")
                ) {
                    QuickAskActions.remove(id: id)
                })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: Localized.text("New action…")) { [weak self] in
            self?.newAction()
        })
        menu.addItem(ClosureMenuItem(title: Localized.text("Open quick-actions.json")) {
            Self.openActionsFile()
        })
        if QuickAskActions.all().contains(where: {
            $0.isBuiltIn && ($0.hidden || $0 != QuickAskBuiltIns.action(id: $0.id))
        }) {
            menu.addItem(ClosureMenuItem(title: Localized.text("Restore the app's actions")) {
                QuickAskActions.restoreBuiltIns()
            })
        }
        return menu
    }

    func newAction() {
        actionSheet = QuickAskActionSheet.present(
            QuickAskAction(id: QuickAskActions.newID(), title: "", prompt: ""), isNew: true,
            current: currentAim(), over: self)
    }

    /// What is in the box, kept: the words as the template and the aim showing now on offer.
    func saveAsAction() {
        guard !asking, gathering == nil else { return }
        let text = editor.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            newAction()
            return
        }
        actionSheet = QuickAskActionSheet.present(
            QuickAskAction(id: QuickAskActions.newID(), title: "", prompt: text), isNew: true,
            current: currentAim(), over: self)
    }

    func editAction(id: String) {
        guard let action = QuickAskActions.action(id: id) else { return }
        actionSheet = QuickAskActionSheet.present(
            action, isNew: false, current: currentAim(), over: self)
    }

    static func openActionsFile() {
        if (try? QuickAskActions.fileURL.checkResourceIsReachable()) != true {
            QuickAskActions.write(QuickAskActions.all())
        }
        NSWorkspace.shared.open(QuickAskActions.fileURL)
    }
}
