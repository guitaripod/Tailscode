import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension QuickAskWindow {
    /// What this window can fetch for a template: the screen where the desktop has a portal for
    /// it, the chat list it was handed, and paths on this disk when the aimed machine is this one.
    var surface: QuickAskSurfaceAbilities {
        .desktop(screen: ScreenGrab.shared.isAvailable, localFiles: isLocalAim)
    }

    var isLocalAim: Bool { QuickAskLocal.isThisMachine(targetServer) }

    /// An action, picked: its aim first, because moving the machine hands back that machine's own
    /// draft, then whatever its template has to fetch, one thing at a time, and only then the
    /// words. A copied-thing action brings the clipboard along the way the composer's own paste
    /// would, or as paths when the files are on this machine.
    func run(_ action: QuickAskAction, copied errand: Bool, typed: String? = nil) {
        guard !asking else { return }
        releaseHold()
        gathering = nil
        let held = (copied, copiedOffer)
        if errand, held.0 == nil || held.1 == nil { return }
        applyAim(of: action)
        var gathering = QuickAskGathering(action: action)
        gathering.fill.typed = typed
        if errand, let copied = held.0, let offer = held.1 {
            gathering.fingerprint = copied.fingerprint
            if action.offer == .files, isLocalAim, !offer.paths.isEmpty {
                gathering.fill.clipboard = QuickAskLocal.mention(offer.paths)
            } else {
                let plan = PasteIntake.plan(
                    for: offer, abilities: abilities, alreadyNamed: pastedImageCount)
                pastedImageCount = plan.named
                gathering.fill.clipboard = plan.text
                gathering.copiedAttachments = plan.attachments
                if let notice = plan.notices.first { setHint(notice) }
            }
        } else if action.offer == .always {
            QuickAskStarterRecents.record(action.id)
        }
        self.gathering = gathering
        AppLog.write(.ui, "ASK action=\(action.id) gathers=\(action.gathers.count)")
        continueGathering()
    }

    /// The action's machine, model and level, held for this one question. The send stamps the
    /// conversation with the aim in force, so the aim really moves, and `hold` remembers what to
    /// put back.
    func applyAim(of action: QuickAskAction) {
        guard let aim = action.aim else { return }
        let profileID = aim.profileID(among: servers) ?? targetServer.id
        var hold = QuickAskAimHold.begin(profileIDs: [targetServer.id, profileID])
        if let index = servers.firstIndex(where: { $0.id == profileID }), index != targetIndex {
            retarget(to: index)
        }
        if let selection = aim.selection {
            QuickAskDefaults.recordModel(selection, forProfileID: profileID)
        }
        if let effort = aim.effort { QuickAskDefaults.recordEffort(effort, forProfileID: profileID) }
        QuickAskDefaults.record(profileID: profileID)
        refreshTarget()
        hold.settle()
        self.hold = hold
    }

    /// Hands the person's own aim back once the question an action aimed has left, or the action
    /// was set aside — and, while the window stays, the machine they were on with it.
    func releaseHold(retargeting: Bool = true) {
        guard let hold else { return }
        self.hold = nil
        AppLog.write(.ui, "ASK aim released untouched=\(hold.isUntouched)")
        hold.release()
        if retargeting, let back = QuickAskDefaults.lastProfileID, back != targetServer.id,
            let index = servers.firstIndex(where: { $0.id == back })
        {
            retarget(to: index)
        }
        if retargeting { refreshTarget() }
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
            stage.stepAside()
            Gtk.openFiles(parent: stage.dialogParent) { [weak self] paths in
                Gtk.onMain { [weak self] in
                    self?.stage.stepBack()
                    guard let self, var current = self.gathering else { return }
                    guard !paths.isEmpty else {
                        self.cancelGathering()
                        return
                    }
                    if self.isLocalAim {
                        current.mentions += paths
                    } else {
                        for path in paths {
                            switch AttachmentIntake.read(path: path) {
                            case .success(let attachment): current.attachments.append(attachment)
                            case .failure(let refusal): self.setHint(refusal.message)
                            }
                        }
                    }
                    current.advance()
                    self.gathering = current
                    self.continueGathering()
                }
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
        write(composed.text)
        editor.placeCaret(at: composed.caret)
        attachments.append(contentsOf: gathering.attachments + gathering.copiedAttachments)
        if !gathering.attachments.isEmpty || !gathering.copiedAttachments.isEmpty {
            renderAttachments()
        }
        if let fingerprint = gathering.fingerprint { QuickAskClipboardMemory.settle(fingerprint) }
        renderStarters()
        refreshStarterVisibility()
        refreshSend()
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
        editor.focus()
        setHint(Localized.text("Set aside — nothing was written."))
    }

    func pickSession(_ entry: SessionEntry) {
        guard var current = gathering, current.awaiting == .session else { return }
        current.fill.session = QuickAskSessionReference.words(for: entry)
        current.advance()
        gathering = current
        continueGathering()
    }

    /// The panel steps out of the way, the desktop draws the drag, and the picture comes back as a
    /// chip; a drag called off leaves the question as it was.
    func grabScreen() {
        guard !asking, gathering == nil else { return }
        guard abilities.vision else {
            setHint(Localized.text("This model can't see pictures."))
            return
        }
        grab { [weak self] picture in
            guard let self, let picture else { return }
            self.attachments.append(picture)
            self.renderAttachments()
            self.refreshSend()
        }
    }

    private func grab(then done: @escaping @Sendable (PendingAttachment?) -> Void) {
        let grab = ScreenGrab.shared
        guard grab.isAvailable else {
            setHint(Localized.text("This desktop has no screenshot portal to drag with."))
            done(nil)
            return
        }
        gtk_widget_set_visible(window, 0)
        Gtk.after(180) {
            grab.grab { outcome in
                Gtk.onMain {
                    guard let open = QuickAskWindow.open else { return }
                    gtk_window_present(ptr(open.window))
                    open.editor.focus()
                    switch outcome {
                    case .picture(let picture):
                        AppLog.write(.ui, "ASK screen grabbed")
                        done(picture)
                    case .cancelled:
                        open.setHint(Localized.text("The drag was called off."))
                        done(nil)
                    case .failed(let reason):
                        open.setHint(reason)
                        done(nil)
                    }
                }
            }
        }
    }

    /// The same question to every party slot that can answer, each its own chat on the machine
    /// that runs it. Fewer than two is said rather than quietly sent as one ordinary question.
    func submitToParty() {
        guard !asking, gathering == nil else { return }
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickAskComposition.canSend(text: text, attachments: attachments.count) else { return }
        let targets = QuickAskParty.targets(partyInputs().cards)
        guard targets.count >= 2 else {
            setHint(Localized.text("The party needs two filled slots that can answer."))
            return
        }
        let question = QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: promptTextGrammar[targetServer.id] == true)
        if case .command = question.kind {
            setHint(Localized.text("A command belongs to one machine — send it with enter."))
            return
        }
        let seats = targets.map { target in
            QuickAskPartySend.Seat(
                profileID: target.profileID, model: target.preset.selection,
                effort: target.preset.applied(
                    currentEffort: nil, models: ModelCatalogStore.cached(target.profileID),
                    agentOptions: agentEfforts[target.profileID] ?? []
                ).level,
                word: target.word)
        }
        asking = true
        completion?.dismiss()
        editor.setSensitive(false)
        gtk_widget_set_sensitive(attach, 0)
        gtk_widget_set_sensitive(send, 0)
        gtk_widget_set_sensitive(target, 0)
        refreshStarterVisibility()
        setHint(Localized.text("Asking the party — %@ models…", "\(seats.count)"))
        let server = targetServer
        let onOffer = copied?.fingerprint
        onAskParty(QuickAskPartySend(seats: seats, send: question, attachments: attachments)) {
            [weak self] failure in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard let failure else {
                    if let onOffer { QuickAskClipboardMemory.settle(onOffer) }
                    DraftStore.clear(.quickAsk(profileID: server.id))
                    AppLog.write(.ui, "ASK party seats=\(seats.count)")
                    self.close()
                    return
                }
                self.asking = false
                self.editor.setSensitive(true)
                gtk_widget_set_sensitive(self.attach, 1)
                gtk_widget_set_sensitive(self.target, self.servers.count > 1 ? 1 : 0)
                self.refreshSend()
                self.editor.focus()
                self.setHint("\(failure.title) — \(failure.detail)")
                self.refreshStarterVisibility()
            }
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
    func showActionMenu(
        for action: QuickAskAction?, on widget: UnsafeMutablePointer<GtkWidget>, x: Double,
        y: Double
    ) {
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
        if let action {
            let id = action.id
            rows.append(
                (Localized.text("Edit…"), nil, { Gtk.onMain { QuickAskWindow.open?.editAction(id: id) } }))
            rows.append(
                (Localized.text("Move earlier"), nil, { Gtk.onMain { QuickAskActions.move(id: id, by: -1) } }))
            rows.append(
                (Localized.text("Move later"), nil, { Gtk.onMain { QuickAskActions.move(id: id, by: 1) } }))
            rows.append(
                (
                    action.isBuiltIn ? Localized.text("Hide") : Localized.text("Delete"),
                    action.isBuiltIn ? Localized.text("Restore the app's actions brings it back") : nil,
                    { Gtk.onMain { QuickAskActions.remove(id: id) } }
                ))
        }
        rows.append(
            (
                Localized.text("New action…"), Localized.text("Or type it and press ctrl+s"),
                { Gtk.onMain { QuickAskWindow.open?.newAction() } }
            ))
        rows.append(
            (
                Localized.text("Open quick-actions.json"), Localized.text("Edit the whole list by hand"),
                { Gtk.onMain { QuickAskWindow.openActionsFile() } }
            ))
        if QuickAskActions.all().contains(where: { $0.isBuiltIn && ($0.hidden || $0 != QuickAskBuiltIns.action(id: $0.id)) }) {
            rows.append(
                (
                    Localized.text("Restore the app's actions"),
                    Localized.text("Hidden and rewritten ones come back; yours stay"),
                    { Gtk.onMain { QuickAskActions.restoreBuiltIns() } }
                ))
        }
        Gtk.contextMenu(on: widget, x: x, y: y, rows: rows)
    }

    func newAction() {
        QuickAskActionEditor.open(
            QuickAskAction(id: QuickAskActions.newID(), title: "", prompt: ""), isNew: true,
            current: currentAim(), on: self)
    }

    /// What is in the box, kept: the words as the template and the aim showing now on offer.
    func saveAsAction() {
        guard !asking, gathering == nil else { return }
        let text = editor.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            newAction()
            return
        }
        QuickAskActionEditor.open(
            QuickAskAction(id: QuickAskActions.newID(), title: "", prompt: text), isNew: true,
            current: currentAim(), on: self)
    }

    func editAction(id: String) {
        guard let action = QuickAskActions.action(id: id) else { return }
        QuickAskActionEditor.open(action, isNew: false, current: currentAim(), on: self)
    }

    static func openActionsFile() {
        if (try? QuickAskActions.fileURL.checkResourceIsReachable()) != true {
            QuickAskActions.write(QuickAskActions.all())
        }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        opener.arguments = [QuickAskActions.fileURL.path]
        try? opener.run()
    }
}
