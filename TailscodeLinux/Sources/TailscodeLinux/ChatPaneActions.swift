import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// Whether a board could be read back at all. The brief is only worth spending a turn on where
    /// this server can hand files over — otherwise the mocks would be written somewhere no client
    /// could ever open them.
    var supportsDesign: Bool { backend?.capabilities.supportsFileBrowsing == true }

    /// A chat whose machine is known by name can hand a task to that machine's dispatcher.
    var supportsDelegate: Bool { entry.map { !$0.host.isEmpty } ?? false }

    /// The catalog a composer offers here: the server's own, plus the words this app answers.
    var composerCommands: [AgentCommand] {
        CommandCatalogStore.forComposer(commands, supportsDesign: supportsDesign, supportsDelegate: supportsDelegate)
    }

    /// Opens the packet composer on this chat's machine, with the words as the goal and the chat's
    /// own directory as the repository.
    func handOff(goal: String) {
        guard let entry else { return }
        let handoff = DelegateHandoff(
            host: entry.host, serverName: entry.profileName, goal: goal, repo: entry.session.directory ?? "")
        AppLog.write(.session, "delegate handoff from session \(entry.session.id) to \(entry.host)")
        host?.presentDelegate(handoff: handoff)
    }

    /// What a board turned out to be, so its card names it rather than its folder. Asked once per
    /// directory: a card that only ever names a folder makes the reader open a board to find out
    /// whether it is worth opening.
    func readDesignBoard(_ directory: String) {
        guard let files = backend as? any FileBrowsingBackend,
            context.designBoards[directory] == nil,
            inFlightDesignBoards.insert(directory).inserted
        else { return }
        let path = DesignPaths.manifest(in: directory)
        Task { [weak self] in
            let text = try? await files.fileContent(path: path)
            Gtk.onMain { [weak self] in
                guard let self, let text, let manifest = DesignManifest.parse(text) else { return }
                self.context.designBoards[directory] = manifest
                self.replaceRows { row in
                    guard case .designBoard(let sighting) = row.kind else { return false }
                    return sighting.source == .board(directory: directory)
                }
            }
        }
    }

    func openDesign(_ source: DesignSource) {
        switch source {
        case .board(let directory):
            DesignBoardWindow.present(
                directory: directory, backend: backend, parent: host?.windowWidget,
                send: { [weak self] prompt in
                    Gtk.onMain { [weak self] in self?.sendComposed(prompt) }
                },
                notice: { [weak self] text in
                    Gtk.onMain { [weak self] in self?.setNotice(text) }
                })
        case .artifact(let url):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
            process.arguments = [url]
            try? process.run()
        }
    }

    /// Continues a turn the server's machine stopped in the middle of. The work resumes on that
    /// machine, so nothing is sent from here and the card comes down on the server's answer.
    ///
    /// The press is worn by the card before the request goes out, and a refusal is reported in the
    /// server's own sentence rather than a substitute — the Kit has already re-read the record by
    /// then, so the card either corrects itself or comes down in the same redraw.
    func resumeInterruptedTurn() {
        guard let conversation else { return }
        beginInterruptedPress(.pickUp)
        Task {
            do {
                try await conversation.resumeInterruptedTurn()
                Gtk.onMain { [weak self] in self?.endInterruptedPress() }
            } catch {
                let said = Self.refusalText(error)
                Gtk.onMain { [weak self] in
                    self?.endInterruptedPress()
                    self?.setNotice(said)
                }
            }
        }
    }

    /// Sets the cut-off turn aside. A server that no longer holds the record has nothing to refuse:
    /// the press asked for it gone and it is gone, so the card comes down without a word.
    func dismissInterruptedTurn() {
        guard let conversation else { return }
        beginInterruptedPress(.letGo)
        Task {
            do {
                try await conversation.dismissInterruptedTurn()
                Gtk.onMain { [weak self] in self?.endInterruptedPress() }
            } catch {
                let said = Self.refusalText(error)
                Gtk.onMain { [weak self] in
                    self?.endInterruptedPress()
                    self?.setNotice(said)
                }
            }
        }
    }

    /// The card as this device must draw it: the server's record, wearing a press this device is
    /// still waiting on the answer to. The press is dropped the instant the server's own account
    /// says something — which is what stops a button sitting in flight forever.
    func interruptedCard(_ state: ConversationState) -> InterruptedTurn? {
        guard let card = InterruptedTurnReading.read(state.interruption) else {
            interruptedPress = nil
            return nil
        }
        guard let press = interruptedPress, !card.isResumed else {
            interruptedPress = nil
            return card
        }
        return InterruptedTurnReading.pressed(card, press)
    }

    /// Acknowledges a press where it happened. The card is redrawn from what this device holds
    /// before the request leaves, so nobody presses twice wondering whether the first one landed.
    func beginInterruptedPress(_ press: InterruptedTurnPress) {
        interruptedPress = press
        redrawPending()
    }

    func endInterruptedPress() {
        interruptedPress = nil
        redrawPending()
    }

    /// The row key carries the card's state so a press is a row the diff rebuilds rather than one
    /// it recognises by key and leaves exactly as it was.
    static func cardKey(_ state: InterruptedTurn.State) -> String {
        switch state {
        case .waiting: return "waiting"
        case .pickingUp: return "pickingup"
        case .lettingGo: return "lettinggo"
        case .resumed: return "resumed"
        }
    }

    /// What to say about a press the server would not take.
    ///
    /// A conflict is the only refusal this side has already acted on — the record was re-read and
    /// the card redrawn — so it is the only one that may carry Core's promise that the card is now
    /// right. Every other failure is reported in the words it arrived with, which are the server's
    /// or the transport's; this client writes neither.
    static func refusalText(_ error: Error) -> String {
        guard case AgentError.http(let status, let body) = error else {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        let named = InterruptedTurnReading.conflict(body: body) != .unstated
        guard status == 409 || (status == 404 && named) else {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        return InterruptedTurnReading.refusal(body: body)
    }

    /// The name this client already shows for a model, for a transcript note to write instead of
    /// the model's bare id. Read straight from the server's own remembered catalog rather than the
    /// live `models` field, which starts empty until the catalog watch's first hop lands and would
    /// leave the very first note of a freshly opened chat naming an id it need not have.
    func noteModelName(_ selection: ModelSelection) -> String? {
        guard let profileID = entry?.profileID else { return nil }
        return ModelCatalogStore.cached(profileID).first { $0.selection == selection }?.name
    }

    /// The right-click on a user message's own row: Undo from here, where the backend can revert
    /// and the row is a real message in the conversation this device holds (never a queued send,
    /// which carries no server id yet), and Copy. The row claims the press before its selectable
    /// label can, so Copy stands in for the label's own copy menu on every backend.
    func presentMessageMenu(messageID: String, widgetBits: UInt, x: Double, y: Double) {
        guard let raw = UnsafeMutableRawPointer(bitPattern: widgetBits),
            let message = lastState?.messages.first(where: { $0.id == messageID })
        else { return }
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
        if let capabilities = backend?.capabilities,
            RevertReading.offersUndo(on: message, capabilities: capabilities)
        {
            rows.append(
                (RevertReading.actionTitle, nil,
                 { [weak self] in
                     Gtk.onMain { [weak self] in self?.confirmUndo(messageID: messageID) }
                 }))
        }
        let words = message.parts.compactMap(\.text).joined(separator: "\n")
        if !words.isEmpty {
            rows.append(
                (Localized.text("Copy"), nil, { Gtk.onMain { Gtk.copyToClipboard(words) } }))
        }
        Gtk.contextMenu(on: ptr(raw), x: x, y: y, rows: rows)
    }

    /// The confirmation states what the press does before anything happens, because winding a
    /// conversation back is not something a mis-click should be able to do quietly.
    func confirmUndo(messageID: String) {
        guard !revertUndoInFlight else { return }
        Dialogs.confirm(
            title: RevertReading.confirmTitle,
            body: RevertReading.confirmMessage(stopping: lastState?.status == .running),
            confirmLabel: RevertReading.confirmAction, destructive: true, parent: host?.windowWidget
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.performUndo(messageID: messageID) }
        }
    }

    func performUndo(messageID: String) {
        guard let conversation, !revertUndoInFlight else { return }
        revertUndoInFlight = true
        setNotice(RevertReading.undoingTitle)
        Task { [weak self] in
            do {
                try await conversation.revert(to: messageID)
                let state = await conversation.state
                Gtk.onMain { [weak self] in self?.finishUndo(state) }
            } catch {
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.revertUndoInFlight = false
                    self.setNotice(RevertReading.failure(restoring: false, error))
                }
            }
        }
    }

    /// The composer only ever receives the wound-back words when it was empty to begin with (a
    /// draft in progress is never overwritten), and the exact words are kept so a later Restore
    /// knows whether it may clear them again or whether the person has since made them their own.
    func finishUndo(_ state: ConversationState) {
        revertUndoInFlight = false
        revertComposerFill = nil
        retireUndoNotice()
        guard editor.text.isEmpty, let words = RevertReading.prompt(in: state.revertedMessages)
        else { return }
        fillComposerForRevert(words)
        revertComposerFill = words
    }

    /// Takes "Winding back…" down once the banner has landed: the banner is the news now, and the
    /// notice left standing over it would claim the wait was still open when the card beneath it
    /// already says it is not.
    func retireUndoNotice() {
        if notice == RevertReading.undoingTitle { notice = nil }
        updateStatus()
    }

    func pressRestoreRevert() {
        guard let conversation, !revertRestoring else { return }
        revertRestoring = true
        redrawPending()
        Task { [weak self] in
            do {
                try await conversation.restoreRevert()
                Gtk.onMain { [weak self] in self?.finishRestoreRevert() }
            } catch {
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.revertRestoring = false
                    self.setNotice(RevertReading.failure(restoring: true, error))
                    self.redrawPending()
                }
            }
        }
    }

    /// Restoring brings the set-aside messages back rather than sending anything, so the banner
    /// simply comes down on the next state; what is left to do here is put the composer back the
    /// way it was, and only when it still holds exactly the words the undo put there.
    func finishRestoreRevert() {
        revertRestoring = false
        if let fill = revertComposerFill, editor.text == fill {
            clearComposer()
        }
        revertComposerFill = nil
    }

    /// Puts the wound-back prompt in the composer as if it were being edited: the same buffer,
    /// vim-document and mode sync a queued send's own Edit action uses, so a person can send it
    /// again unchanged or rework it before they do.
    func fillComposerForRevert(_ text: String) {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), text, -1)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        updateVimBadge()
    }

    func attachRows() -> [(String, String?, @Sendable () -> Void)] {
        let able = abilities
        let supported = backend?.capabilities.supportsAttachments != false
        if let reason = able.unavailableReason(supportsAttachments: supported) {
            return [(reason, nil, {})]
        }
        var rows: [(String, String?, @Sendable () -> Void)] = [
            (Localized.text("Attach files…"), Localized.text("Up to 8 MB each"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pickAttachments() } })
        ]
        guard able.vision else { return rows }
        rows.append(
            (Localized.text("Paste image"), Localized.text("From the clipboard, as PNG"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pasteImageAttachment() } }))
        return rows
    }

    func pickAttachments() {
        Gtk.openFiles(parent: host?.windowWidget) { [weak self] paths in
            self?.attach(paths: paths)
        }
    }

    func attach(paths: [String]) {
        for path in paths {
            switch AttachmentIntake.read(path: path) {
            case .success(let attachment):
                attachments.append(attachment)
            case .failure(let refusal):
                setNotice(refusal.message)
            }
        }
        renderAttachments()
    }

    func pasteImageAttachment() {
        Gtk.readClipboardImage { [weak self] data in
            guard let self else { return }
            guard let data else {
                self.setNotice(
                            Localized.text("The clipboard holds no picture."))
                return
            }
            guard data.count <= AttachmentIntake.byteCap else {
                self.setNotice(
                            Localized.text(
                        "That picture is %@ — the cap is 8 MB",
                        AttachmentIntake.sizeText(data.count)))
                return
            }
            self.pastedImageCount += 1
            self.attachments.append(
                PendingAttachment(
                    name: "pasted-\(self.pastedImageCount).png", mime: "image/png", data: data))
            self.renderAttachments()
        }
    }

    func renderAttachments() {
        Gtk.removeChildren(of: attachmentsBox)
        gtk_widget_set_visible(attachmentsBox, attachments.isEmpty ? 0 : 1)
        if let attachButton {
            gtk_menu_button_set_label(
                op(attachButton), attachments.isEmpty ? "📎" : "📎 \(attachments.count)")
        }
        for attachment in attachments {
            let title = "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))"
            let id = attachment.id
            let chip = ChatChips.control(
                glyph: "✕", word: title, tone: .quiet,
                label: Localized.text("Remove %@", attachment.name)
            ) { [weak self] in
                guard let self else { return }
                self.attachments.removeAll { $0.id == id }
                self.renderAttachments()
            }
            gtk_widget_set_margin_end(chip.button, 6)
            gtk_box_append(ptr(attachmentsBox), chip.button)
        }
    }
}
