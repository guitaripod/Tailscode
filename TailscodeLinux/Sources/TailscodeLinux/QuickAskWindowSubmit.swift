import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension QuickAskWindow {
    func pickAttachments() {
        guard !asking, abilities.attachments || isLocalAim else { return }
        stage.stepAside()
        Gtk.openFiles(parent: stage.dialogParent) { [weak self] paths in
            Gtk.onMain { [weak self] in self?.stage.stepBack() }
            self?.take(paths: paths)
        }
    }

    /// Read fully at pick time, so a file edited or deleted between picking and sending still
    /// sends the bytes that were chosen; a refusal names its reason instead of shrinking a file.
    /// When the machine asked is this one, the files go by their paths instead: the agent opens
    /// them where they are, and nothing is capped.
    func take(paths: [String]) {
        guard !asking else { return }
        if isLocalAim, !paths.isEmpty {
            editor.insertAtCaret(QuickAskLocal.mention(paths) + "\n")
            setHint(Localized.text("This machine is the one asked, so the files go by their paths."))
            return
        }
        guard abilities.attachments else { return }
        for path in paths {
            switch AttachmentIntake.read(path: path) {
            case .success(let attachment):
                guard abilities.accepts(mime: attachment.mime) else {
                    setHint(Localized.text("This model can't read %@", attachment.name))
                    continue
                }
                attachments.append(attachment)
            case .failure(let refusal):
                setHint(refusal.message)
            }
        }
        renderAttachments()
    }

    /// The clipboard, whatever it is holding. A screenshot and a file copied in a file manager
    /// both become chips here rather than making a person save one and pick the other back up, and
    /// words go in at the caret. What the aim cannot be handed says so in the hint line.
    func pasteFromClipboard() {
        guard !asking else { return }
        let able = abilities
        let named = pastedImageCount
        let visit = visit
        Gtk.readClipboard { offer in
            Gtk.onMain { [weak self] in
                guard let self, self.isServing(visit) else { return }
                let plan = PasteIntake.plan(for: offer, abilities: able, alreadyNamed: named)
                self.pastedImageCount = plan.named
                if let text = plan.text, !text.isEmpty { self.editor.insertAtCaret(text) }
                if !plan.attachments.isEmpty {
                    self.attachments.append(contentsOf: plan.attachments)
                    self.renderAttachments()
                }
                if let notice = plan.notices.first { self.setHint(notice) }
            }
        }
    }

    func renderAttachments() {
        Gtk.removeChildren(of: chips)
        gtk_widget_set_visible(chips, attachments.isEmpty ? 0 : 1)
        gtk_button_set_label(
            ptr(attach),
            attachments.isEmpty
                ? Localized.text("📎 Attach") : Localized.text("📎 %@ attached", "\(attachments.count)"))
        for attachment in attachments {
            let title = "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))  ✕"
            let id = attachment.id
            gtk_box_append(
                ptr(chips),
                Gtk.button(title, css: ["chip"]) { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.attachments.removeAll { $0.id == id }
                        self.renderAttachments()
                    }
                })
        }
        refreshStarterVisibility()
    }

    /// The window outlives Enter the way the new-chat modal outlives Start: the mint happens on
    /// another machine, and a surface that vanished the instant a request went out could never
    /// say it failed. Success closes it; failure names itself and gives the words — and the
    /// pictures — back.
    func submit() {
        guard !asking else { return }
        if dictation.stopAndSend() { return }
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickAskComposition.canSend(text: text, attachments: attachments.count) else { return }
        asking = true
        completion?.dismiss()
        editor.setSensitive(false)
        gtk_widget_set_sensitive(attach, 0)
        gtk_widget_set_sensitive(send, 0)
        gtk_widget_set_sensitive(target, 0)
        dictation.waiting = true
        refreshStarterVisibility()
        setHint(QuickAskComposition.waitingTitle(server: targetServer.name))
        let server = targetServer
        let onOffer = copied?.fingerprint
        let send = QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: promptTextGrammar[server.id] == true)
        if case .command(let command, _) = send.kind { SlashRecents.record(command.name) }
        let visit = visit
        onAsk(server.id, send, attachments) { [weak self] failure in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if failure == nil {
                    QuickAskDefaults.record(profileID: server.id)
                    Self.sent(text, on: server.id, settling: onOffer)
                    AppLog.write(.ui, "ASK sent server=\(server.name)")
                }
                guard self.isServing(visit) else { return }
                guard let failure else {
                    self.releaseHold(retargeting: false)
                    self.close()
                    return
                }
                self.unlock()
                self.editor.focus()
                self.setHint("\(failure.title) — \(failure.detail)")
                self.refreshStarterVisibility()
                AppLog.write(.ui, "ASK failed \(failure.title)")
            }
        }
    }

    func driveType(_ text: String) {
        write(text)
    }

    func driveGo() {
        submit()
    }

    func driveStarter(_ index: Int) {
        pickStarter(at: index)
    }

    func drivePick(_ index: Int) {
        pick(at: index)
    }

    /// What a question that went out leaves behind, whether or not the window is still up for it,
    /// since it may have been put away while the machine was minting: what was copied is set
    /// aside, and the words stop being a draft unless something new was written over them since.
    static func sent(_ text: String, on profileID: String, settling offer: String?) {
        if let offer { QuickAskClipboardMemory.settle(offer) }
        let scope = DraftScope.quickAsk(profileID: profileID)
        let filed = DraftStore.text(for: scope).trimmingCharacters(in: .whitespacesAndNewlines)
        guard filed == text else { return }
        DraftStore.clear(scope)
        guard let open, open.targetServer.id == profileID,
            open.editor.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
        else { return }
        open.write("")
    }

    /// Whether an answer that arrives now belongs to the question on screen: the one asked on this
    /// visit, with the window still up for it.
    func isServing(_ visit: Int) -> Bool {
        Self.open === self && self.visit == visit
    }

    /// The box is the person's again after a send that did not go out, or one the window was put
    /// away in the middle of.
    func unlock() {
        asking = false
        editor.setSensitive(true)
        gtk_widget_set_sensitive(attach, 1)
        gtk_widget_set_sensitive(target, servers.count > 1 ? 1 : 0)
        dictation.waiting = false
        refreshSend()
    }

    /// Puts the window away for the next summon rather than destroying it. What was typed is filed
    /// under its machine; what was in hand, what was copied, the line picked, a notice and the
    /// pills' popovers are let go, so the window comes back the way a new one would.
    func close() {
        dictation.stopKeepingShown()
        stage.putAway()
        releaseHold(retargeting: false)
        gathering = nil
        if let actionsWatch { NotificationCenter.default.removeObserver(actionsWatch) }
        actionsWatch = nil
        if let laterWatch { NotificationCenter.default.removeObserver(laterWatch) }
        laterWatch = nil
        if let summonWatch { NotificationCenter.default.removeObserver(summonWatch) }
        summonWatch = nil
        stashDraft()
        DraftStore.flush()
        catalogWatch?.cancel()
        catalogWatch = nil
        completion?.dismiss()
        gtk_menu_button_popdown(op(target))
        gtk_menu_button_popdown(op(dial.button))
        gtk_popover_popdown(ptr(dial.dial.popover))
        if asking { unlock() }
        copiedOffer = nil
        copied = nil
        attachments = []
        pastedImageCount = 0
        renderAttachments()
        setHint("")
        menuCursor.clear()
        paintSelection()
        Self.open = nil
        Self.standby = self
    }
}
