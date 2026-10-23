import TailscodeCore
import CodingAgentKit
import PhotosUI
import UIKit

/// The ask lane's own furniture: what it offers while it is empty, what it can be handed, and what
/// it says when the machine on the other end refuses to mint a conversation.
extension HomeViewController {
    /// The strip is the lane's empty state and nothing more: the moment there is a question — or
    /// something in hand, or a command being named — it gets out of the way, and it comes back if
    /// the box is emptied again.
    private var wantsSuggestions: Bool {
        askLane == .ask && !composerBar.isHidden && composerBar.currentText.isEmpty
            && attachments.isEmpty && commandPalette.isHidden
    }

    func updateSuggestions() {
        setAccessory(videoChips, visible: askLane == .video && !composerBar.isHidden)
        setAccessory(imageChips, visible: askLane == .image && !composerBar.isHidden)
        guard wantsSuggestions else { return setAccessory(suggestions, visible: false) }
        if let aim = composerAim {
            suggestions.update(
                starters: QuickAskStarters.offered(for: abilities),
                recents: QuickAskRecents.asks(among: viewModel.entries, profileID: aim.profile.id),
                note: nil)
        } else {
            suggestions.update(starters: [], recents: [], note: QuickAskWords.noServers)
        }
        setAccessory(suggestions, visible: true)
    }

    /// A starter is the first half of a sentence, never a question the app asked on somebody's
    /// behalf: the words land in the box with the caret at their end, and a row that needs a
    /// picture or a file opens the picker for it in the same touch.
    func pickStarter(_ starter: QuickAskStarter) {
        Theme.Haptics.tap()
        QuickAskStarterRecents.record(starter.id)
        if composerBar.currentText.isEmpty {
            composerBar.setDraft(starter.prompt, focus: true)
        } else {
            composerBar.focus()
        }
        switch starter.opens {
        case .none: break
        case .photos: presentPhotoPicker()
        case .camera: presentCamera()
        case .files: presentDocumentPicker()
        }
    }

    private func setAccessory(_ view: UIView, visible: Bool) {
        guard view.isHidden == visible else { return }
        UIView.animate(withDuration: 0.2) {
            view.isHidden = !visible
            view.alpha = visible ? 1 : 0
            self.accessories.layoutIfNeeded()
        }
    }

    /// What the aim can be handed, re-read whenever either half of it moves. A picture already in
    /// the strip that the new model cannot read is dropped out loud rather than carried to a send
    /// the other machine would refuse.
    func refreshAbilities(for aim: ComposerAim) {
        let backend = viewModel.backend(forProfileID: aim.profile.id)
        abilities = ModelAbilities.resolve(
            supportsAttachments: backend?.capabilities.supportsAttachments ?? false,
            model: modelCapabilities(for: aim),
            camera: UIImagePickerController.isSourceTypeAvailable(.camera))
        composerBar.showsAttach = abilities.attachments
        let kept = attachments.filter { abilities.accepts(mime: $0.mime) }
        let dropped = attachments.count - kept.count
        if dropped > 0 {
            attachments = kept
            toast(QuickAskComposition.droppedNotice(count: dropped))
        }
        refreshAttachments()
    }

    private func modelCapabilities(for aim: ComposerAim) -> ModelCapabilities? {
        guard let selection = modelChoices[aim.memoryKey]?.model else { return nil }
        return ModelCatalog.cached(for: aim.profile.id).first {
            $0.providerID == selection.providerID && $0.id == selection.modelID
        }?.capabilities
    }

    func refreshAttachments() {
        attachmentStrip.update(attachments)
        composerBar.carriesAttachments = !attachments.isEmpty
        setAccessory(attachmentStrip, visible: !attachments.isEmpty)
        updateSuggestions()
    }

    func attach(_ attachment: PendingAttachment) {
        guard abilities.accepts(mime: attachment.mime) else {
            toast(String(localized: "This model can't read \(attachment.name)."))
            return
        }
        attachments.append(attachment)
        Theme.Haptics.success()
        refreshAttachments()
    }

    func attach(data: Data, name: String, mime: String) {
        guard data.count <= AttachmentIntake.byteCap else {
            toast(
                String(
                    localized:
                        "\(name) is \(AttachmentIntake.sizeText(data.count)) — the cap is 8 MB."))
            return
        }
        attach(PendingAttachment(name: name, mime: mime, data: data))
    }

    func presentPhotoPicker() {
        Theme.Haptics.tap()
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 5
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        Theme.Haptics.tap()
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        present(picker, animated: true)
    }

    func presentDocumentPicker() {
        Theme.Haptics.tap()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    /// The pasteboard, taken for what it is holding: a picture becomes an attachment, words go
    /// into the box where the caret is.
    func pasteFromClipboard() {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, abilities.vision {
            guard let image = pasteboard.image, let data = image.pngData() else {
                toast(String(localized: "The clipboard holds no picture."))
                return
            }
            pastedImageCount += 1
            attach(data: data, name: "pasted-\(pastedImageCount).png", mime: "image/png")
            return
        }
        guard let text = pasteboard.string, !text.isEmpty else {
            toast(String(localized: "The clipboard holds nothing to send."))
            return
        }
        composerBar.insertText(text)
    }

    func toast(_ message: String) {
        ToastView(message: message).flash(in: view, above: composerBar.topAnchor)
    }

    func showFailure(_ failure: NewChatFailure) {
        lastFailure = failure
        failureCard.show(failure)
        setAccessory(failureCard, visible: true)
        UIAccessibility.post(notification: .announcement, argument: failure.spoken)
    }

    func dismissFailure() {
        guard lastFailure != nil else { return }
        lastFailure = nil
        setAccessory(failureCard, visible: false)
    }

    /// The remedy, applied and the send retried on the spot — somebody who tapped "Use :4098"
    /// asked for an answer, not for a settings screen.
    func applyFix() {
        guard let failure = lastFailure else { return }
        Theme.Haptics.tap()
        dismissFailure()
        switch failure.fix {
        case .none:
            break
        case .retry:
            guard let attempt = lastAttempt else { return }
            mint(aim: attempt.aim, send: attempt.send)
        case .editServer(let profileID):
            guard let profile = viewModel.servers.first(where: { $0.id == profileID }) else {
                return
            }
            let editor = ServerEditViewController(profile: profile)
            editor.onSaved = { [weak self] _ in
                guard let self else { return }
                self.viewModel.refreshSources()
                self.dismiss(animated: true) { self.retryLastAttempt() }
            }
            present(UINavigationController(rootViewController: editor), animated: true)
        case .repoint(let profileID, let url, _):
            guard var profile = viewModel.servers.first(where: { $0.id == profileID }) else {
                return
            }
            let password = ConnectionController.shared.password(for: profile.id)
            profile.baseURL = url
            do {
                try ConnectionController.shared.save(profile, password: password)
                viewModel.refreshSources()
                retryLastAttempt()
            } catch {
                showFailure(
                    NewChatDiagnosis.failure(
                        server: NewChatServer(
                            profileID: profile.id, name: profile.name, backend: profile.backend,
                            address: ServerLabel.address(profile)),
                        directory: nil, error: AgentErrorText.readable(error), witness: .unknown))
            }
        }
    }

    /// The aim is re-read rather than replayed: a fix that changed the server changed the profile
    /// the attempt was holding, and minting against the stale one would fail the same way twice.
    private func retryLastAttempt() {
        guard let attempt = lastAttempt, let aim = composerAim else { return }
        mint(aim: aim, send: attempt.send)
    }

    func presentEnhanceOverlay(original: String) {
        enhanceOverlay?.removeFromSuperview()
        let overlay = PromptEnhanceOverlay()
        overlay.delegate = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: composerBar.topAnchor),
        ])
        enhanceOverlay = overlay
        overlay.render(enhancement.status, original: original)
        view.layoutIfNeeded()
        let anchor = composerBar.sendControlAnchor
        let origin = anchor.convert(
            CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: overlay)
        overlay.animateIn(fromButtonCenter: origin)
    }

    func handleEnhancementStatus(_ status: PromptEnhancementController.Status) {
        composerBar.setEnhanceHint(enhancement.hasFreshSuggestions)
        enhanceOverlay?.render(status, original: enhancement.latestInput)
    }
}

extension HomeViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        Theme.Haptics.success()
        composerBar.setDraft(prompt.text, focus: true)
        if enhancement.mode == .image { ImageStudio.shared.followWriter(aspect: prompt.aspect) }
        overlay.requestDismiss()
    }

    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt) {
        UIPasteboard.general.string = prompt.text
        Theme.Haptics.success()
        toast(String(localized: "Enhanced prompt copied."))
    }

    func enhanceOverlayDidRequestRetry(_ overlay: PromptEnhanceOverlay) {
        Theme.Haptics.tap()
        enhancement.retry()
    }

    func enhanceOverlayDidDismiss(_ overlay: PromptEnhanceOverlay) {
        if enhanceOverlay === overlay { enhanceOverlay = nil }
        composerBar.setEnhanceHint(enhancement.hasFreshSuggestions)
    }
}

extension HomeViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let provider = result.itemProvider
            let name = provider.suggestedName
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                [weak self] data, _ in
                guard let data else { return }
                let kind = ImageBytes.kind(of: data)
                Task { @MainActor in
                    self?.attach(
                        data: data,
                        name: "\(name ?? "image-\(UUID().uuidString.prefix(8))").\(kind.ext)",
                        mime: kind.mime)
                }
            }
        }
    }
}

extension HomeViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
            let data = image.jpegData(compressionQuality: 0.9)
        else { return }
        pastedImageCount += 1
        attach(data: data, name: "photo-\(pastedImageCount).jpg", mime: "image/jpeg")
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension HomeViewController: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        for url in urls {
            switch AttachmentIntake.read(path: url.path) {
            case .success(let attachment): attach(attachment)
            case .failure(let refusal): toast(refusal.message)
            }
        }
    }
}

/// A picture dragged onto the front door is a question about that picture: the drop is taken where
/// it lands, on any part of the screen, because aiming at a 32-point paperclip with something held
/// in the other hand is not a gesture anybody should have to make.
extension HomeViewController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool
    {
        abilities.attachments && !composerBar.isHidden
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        for item in session.items {
            let provider = item.itemProvider
            let name = provider.suggestedName ?? String(localized: "attachment")
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                    [weak self] data, _ in
                    guard let data else { return }
                    let kind = ImageBytes.kind(of: data)
                    Task { @MainActor in
                        self?.attach(data: data, name: "\(name).\(kind.ext)", mime: kind.mime)
                    }
                }
                continue
            }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) {
                [weak self] url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                let filename = url.lastPathComponent
                let mime = AttachmentIntake.mime(forExtension: url.pathExtension)
                Task { @MainActor in
                    self?.attach(data: data, name: filename, mime: mime)
                }
            }
        }
    }
}
