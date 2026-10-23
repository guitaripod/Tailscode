import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension QuickAskWindow {
    func pickAttachments() {
        guard !asking, abilities.attachments else { return }
        Gtk.openFiles(parent: window) { [weak self] paths in
            self?.take(paths: paths)
        }
    }

    /// Read fully at pick time, so a file edited or deleted between picking and sending still
    /// sends the bytes that were chosen; a refusal names its reason instead of shrinking a file.
    func take(paths: [String]) {
        guard !asking, abilities.attachments else { return }
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
        Gtk.readClipboard { offer in
            Gtk.onMain { [weak self] in
                guard let self else { return }
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
            ptr(attach), attachments.isEmpty ? "📎" : "📎 \(attachments.count)")
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
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickAskComposition.canSend(text: text, attachments: attachments.count) else { return }
        asking = true
        completion?.dismiss()
        editor.setSensitive(false)
        gtk_widget_set_sensitive(attach, 0)
        gtk_widget_set_sensitive(send, 0)
        gtk_widget_set_sensitive(aimStrip, 0)
        refreshStarterVisibility()
        setHint(QuickAskComposition.waitingTitle(server: targetServer.name))
        let server = targetServer
        let onOffer = copied?.fingerprint
        let send = QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: promptTextGrammar[server.id] == true)
        if case .command(let command, _) = send.kind { SlashRecents.record(command.name) }
        onAsk(server.id, send, attachments) { [weak self] failure in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard let failure else {
                    QuickAskDefaults.record(profileID: server.id)
                    if let onOffer { QuickAskClipboardMemory.settle(onOffer) }
                    DraftStore.clear(.quickAsk(profileID: server.id))
                    AppLog.write(.ui, "ASK sent server=\(server.name)")
                    self.close()
                    return
                }
                self.asking = false
                self.editor.setSensitive(true)
                gtk_widget_set_sensitive(self.attach, 1)
                gtk_widget_set_sensitive(self.aimStrip, 1)
                self.refreshSend()
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

    func close() {
        stashDraft()
        DraftStore.flush()
        completion?.tearDown()
        completion = nil
        if let summonWatch { NotificationCenter.default.removeObserver(summonWatch) }
        summonWatch = nil
        gtk_window_destroy(ptr(window))
        Self.open = nil
    }
}
