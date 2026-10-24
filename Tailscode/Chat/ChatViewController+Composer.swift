import MidgarCore
import TailscodeCore
import CodingAgentKit
import PhotosUI
import UIKit

extension ChatViewController {
    /// Puts a waiting message in the composer to be rewritten. The entry stays in the queue and
    /// keeps its place; only sending replaces it.
    func editQueued(_ row: QueueRow) {
        guard row.canEdit else { return }
        let send = row.editable
        editingQueued = row.id
        composer.isEditingQueued = true
        composer.setDraft(send.text)
        composer.becomeFirstResponder()
        if !send.attachments.isEmpty {
            pendingAttachments = send.attachments
            composer.showsAttach = canAttachAnything
            updateAttachmentStrip()
        }
        Theme.Haptics.selection()
        renderPending()
    }

    /// ↑ in an empty composer takes back the last thing written — the one being reconsidered.
    /// Only from an empty box: in a half-typed paragraph that key is moving the caret, and taking
    /// it would be the worse bug.
    @objc func takeBackLastQueued() {
        let display = viewModel.queueDisplay
        guard
            QueueReading.upArrowOpensLast(composerText: composer.currentText, display: display),
            let last = display.last
        else { return }
        editQueued(last)
    }

    private func finishQueuedEdit(_ text: String) -> Bool {
        guard let id = editingQueued else { return false }
        editingQueued = nil
        let row = viewModel.queueDisplay.row(id: id)
        composer.isEditingQueued = false
        let attachments = pendingAttachments
        pendingAttachments = []
        composer.showsAttach = canAttachAnything
        updateAttachmentStrip()
        guard let row else {
            giveBackEditedWords(text, attachments: attachments)
            viewModel.onError?(QueueReading.alreadySent)
            return true
        }
        viewModel.replaceQueued(row, text: text, attachments: attachments) { [weak self] in
            self?.giveBackEditedWords(text, attachments: attachments)
        }
        DraftStore.clear(draftScope)
        return true
    }

    /// The words of a message the server started while it was being rewritten go back into the
    /// box, because the rewrite can no longer land and losing them would be the worse outcome.
    private func giveBackEditedWords(_ text: String, attachments: [PromptAttachment]) {
        composer.setDraft(text)
        guard !attachments.isEmpty else { return }
        pendingAttachments = attachments
        composer.showsAttach = canAttachAnything
        updateAttachmentStrip()
    }
}

extension ChatViewController: ComposerViewDelegate, PendingSendCellDelegate {
    /// A typed slash goes where the palette would have sent it — the person who types the whole
    /// command should not get different behaviour from the person who tapped the row. Anything
    /// the server has never heard of goes out as the words that were written: the server is the
    /// authority on its own grammar.
    func composerDidSend(_ text: String) {
        hideCommandPalette()
        if finishQueuedEdit(text) { return }
        switch SlashDispatch.decide(
            text: text, commands: viewModel.composerCommands,
            supportsCompaction: viewModel.supportsCompaction,
            resolvesFromPromptText: viewModel.resolvesCommandsFromPromptText,
            supportsDesign: viewModel.supportsDesign, supportsDelegate: viewModel.supportsDelegate)
        {
        case .compactPreflight(let instruction):
            DraftStore.clear(draftScope)
            SlashRecents.record("compact")
            presentCompactPreflight(instruction: instruction)
        case .designPreflight(let request):
            DraftStore.clear(draftScope)
            SlashRecents.record(SlashDispatch.designWord)
            composer.clear()
            presentDesignPreflight(request: request)
        case .delegatePreflight(let goal):
            DraftStore.clear(draftScope)
            SlashRecents.record(SlashDispatch.delegateWord)
            composer.clear()
            handOff(goal: goal)
        case .run(let command, let arguments):
            runServerCommand(command, arguments: arguments)
        case .plainText:
            sendDraft(text)
        }
    }

    /// - Parameter carrying: pictures and files that came with the words from somewhere other
    ///   than the composer — a quick ask handing its question over. The composer's own strip is
    ///   then left alone: what is clipped to a half-typed prompt belongs to that prompt.
    func sendDraft(
        _ text: String, model: ModelSelection? = nil, effort: String? = nil,
        attachments carrying: [PromptAttachment]? = nil
    ) {
        let attachments = carrying ?? pendingAttachments
        if carrying == nil {
            pendingAttachments = []
            composer.showsAttach = canAttachAnything
            updateAttachmentStrip()
        }
        userScrolledUp = false
        animateNextRender = true
        isHandingOffEmptyState = !emptyState.isHidden && emptyState.alpha > 0
        DraftStore.clear(draftScope)
        viewModel.send(text, model: model, effort: effort, attachments: attachments)
    }

    /// The one action a turn that said nothing offers: the same words, sent again the ordinary
    /// way. The pictures that went with them are bytes on the server rather than in this
    /// transcript, so they are deliberately not carried over — which is also the remedy when a
    /// picture is what the turn choked on.
    func askAgain(_ turn: AnswerlessTurn) {
        guard turn.offersRemedy, !viewModel.isBusy else { return }
        sendDraft(turn.prompt)
    }

    /// The same words again after a turn that stopped with an error, through the ordinary send.
    func retryFailed(_ turn: FailedTurn) {
        guard turn.offersRemedy, !viewModel.isBusy else { return }
        sendDraft(turn.prompt)
    }

    /// What a row that did not go offers. Sending again is the ordinary send — it keeps the row,
    /// so the words never move; editing hands them and whatever was clipped to them back to the
    /// composer and takes the row away, because two copies of the same message on screen is the
    /// confusion this row exists to prevent.
    func pendingSend(_ id: UUID, act: PendingSend.Act) {
        switch act {
        case .retry:
            Theme.Haptics.tap()
            announcedFailedSends.remove(id)
            userScrolledUp = false
            canvasForcedSend = id
            viewModel.retryPending(id: id)
        case .edit:
            guard let taken = viewModel.takeBackPending(id: id) else { return }
            announcedFailedSends.remove(id)
            composer.setDraft(CarriedText.typed(taken.text))
            composer.becomeFirstResponder()
            DraftStore.record(CarriedText.typed(taken.text), for: draftScope)
            if !taken.attachments.isEmpty {
                pendingAttachments = taken.attachments
                composer.showsAttach = canAttachAnything
                updateAttachmentStrip()
            }
            Theme.Haptics.selection()
        case .discard:
            announcedFailedSends.remove(id)
            viewModel.discardPending(id: id)
            Theme.Haptics.tap()
        }
    }

    /// What a message being held for a window offers. Sending now is the ordinary send; editing
    /// hands the words back to the composer and takes the row away; not waiting leaves the words
    /// exactly where they are as the ordinary not-sent row they were before the wait.
    func pendingSend(_ id: UUID, resume act: ResumeReading.Act) {
        switch act {
        case .sendNow:
            Theme.Haptics.tap()
            announcedFailedSends.remove(id)
            userScrolledUp = false
            canvasForcedSend = id
            _ = viewModel.actOnResume(id, .sendNow)
        case .edit:
            guard let taken = viewModel.actOnResume(id, .edit) else { return }
            announcedFailedSends.remove(id)
            composer.setDraft(CarriedText.typed(taken.text))
            composer.becomeFirstResponder()
            DraftStore.record(CarriedText.typed(taken.text), for: draftScope)
            if !taken.attachments.isEmpty {
                pendingAttachments = taken.attachments
                composer.showsAttach = canAttachAnything
                updateAttachmentStrip()
            }
            Theme.Haptics.selection()
        case .stopWaiting:
            _ = viewModel.actOnResume(id, .stopWaiting)
            Theme.Haptics.tap()
        }
    }

    func composerTextDidChange(_ text: String) {
        DraftStore.record(text, for: draftScope)
        updateCommandPalette(for: text)
        guard !isApplyingEnhancedPrompt else { return }
        enhancement.updateInput(text)
        enhanceOverlay?.requestDismiss()
    }

    /// Holding Send always raises the on-device enhancement deck for a non-empty
    /// draft; `requestNow` decides whether to generate, ask for a little more
    /// detail, or explain that Apple Intelligence is unavailable. Model/effort
    /// selection lives on the nav bar, never here.
    func composerDidLongPressSend(from view: UIView) {
        let text = composer.currentText
        guard !text.isEmpty else { return }
        MidgarLog.info(
            "enhance: long-press chars=\(text.count) available=\(enhancement.isAvailable) enhanceable=\(PromptEnhancementController.isEnhanceable(text))", category: .ui)
        enhancement.requestNow(for: text)
        presentEnhanceOverlay(original: text)
    }

    func composerDidPasteImage(_ data: Data, mime: String) {
        guard viewModel.canAttachImages else {
            presentToast(String(localized: "This model can't see images."))
            return
        }
        guard data.count <= Self.attachmentSizeLimit else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            presentToast(String(localized: "That picture is \(size) — attachments are capped at 8 MB."))
            return
        }
        pastedImageCount += 1
        pendingAttachments.append(
            PromptAttachment(
                mime: mime, filename: "pasted-\(pastedImageCount).png", data: data))
        composer.showsAttach = true
        updateAttachmentStrip()
        Theme.Haptics.success()
        presentToast(String(localized: "Picture attached — it'll be sent with your next message."))
    }

    func composerDidPasteLargeText(_ text: String) {
        guard viewModel.canAttachFiles else {
            composer.insertText(text)
            return
        }
        composer.deleteSelection()
        guard let data = text.data(using: .utf8) else { return }
        pendingAttachments.append(
            PromptAttachment(
                mime: "text/plain", filename: "pasted-\(UUID().uuidString.prefix(8)).txt",
                data: data))
        composer.showsAttach = true
        updateAttachmentStrip()
        Theme.Haptics.success()
        presentToast(
            String(
                localized:
                    "Attached \(text.count.formatted()) characters — sent with your next message."))
    }

    func composerDidTapStop() {
        Theme.Haptics.tap()
        viewModel.abort()
    }

    func composerDidBeginEditing() {
        enhancement.prewarm()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.canvasPromptIDs.isEmpty, !self.canvasRising else { return }
            self.scrollToBottom(animated: true)
        }
    }

    private func presentEnhanceOverlay(original: String) {
        hideCommandPalette()
        enhanceOverlay?.removeFromSuperview()
        let overlay = PromptEnhanceOverlay()
        overlay.delegate = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: composer.topAnchor),
        ])
        enhanceOverlay = overlay
        overlay.render(enhancement.status, original: original)
        view.layoutIfNeeded()
        let anchor = composer.sendControlAnchor
        let origin = anchor.convert(
            CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: overlay)
        overlay.animateIn(fromButtonCenter: origin)
        MidgarLog.info("enhance: overlay presented", category: .ui)
    }

    func handleEnhancementStatus(_ status: PromptEnhancementController.Status) {
        composer.setEnhanceHint(enhancement.hasFreshSuggestions)
        enhanceOverlay?.render(status, original: enhancement.latestInput)
    }

    /// Photos and files are different enough errands to be asked about rather
    /// than guessed at: an image goes to the model's vision input, a file lands
    /// on the server for the agent to open. Only the sources the current model
    /// can actually accept are offered.
    func composerAttachOptions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        if viewModel.canAttachImages {
            actions.append(
                UIAction(
                    title: String(localized: "Photo Library"),
                    image: UIImage(systemName: "photo.on.rectangle")
                ) { [weak self] _ in self?.presentPhotoPicker() })
        } else if viewModel.canAttachFiles {
            actions.append(
                UIAction(
                    title: String(localized: "Photo Library"),
                    subtitle: String(localized: "This model can't see images."),
                    image: UIImage(systemName: "photo.on.rectangle"), attributes: .disabled
                ) { _ in })
        }
        if viewModel.canAttachFiles {
            actions.append(
                UIAction(
                    title: String(localized: "Files"), image: UIImage(systemName: "folder")
                ) { [weak self] _ in
                    self?.presentDocumentPicker()
                })
        }
        return actions
    }

    /// A question with pictures usually has more than one of them, and going back through the sheet,
    /// the menu and the library for each is the same decision made four times. One pass takes as
    /// many as the send can carry.
    private func presentPhotoPicker() {
        Theme.Haptics.tap()
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = Self.attachmentCountLimit
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        Theme.Haptics.tap()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    /// The whole selection rides base64-encoded inside one send, so the number is capped as well as
    /// each file's size — a picker that let someone choose thirty pictures would be offering a turn
    /// that cannot leave the phone.
    static let attachmentCountLimit = 10
}
