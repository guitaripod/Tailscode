import MidgarCore
import TailscodeCore
import CodingAgentKit
import PhotosUI
import UIKit

extension ChatViewController {
    /// A model that takes no images can still take files — the agent opens those
    /// on the server — so the affordance survives a switch to a text-only model.
    var canAttachAnything: Bool {
        viewModel.canAttachImages || viewModel.canAttachFiles
    }

    /// Keeps the attach affordance in sync with what the selected model can
    /// actually see: hides the picker for text-only models and drops pending
    /// image attachments that a model switch made unsendable.
    func refreshAttachmentGating() {
        let able = viewModel.abilities
        let kept = pendingAttachments.filter { able.accepts(mime: $0.mime) }
        if kept.count != pendingAttachments.count {
            let dropped = pendingAttachments.count - kept.count
            pendingAttachments = kept
            updateAttachmentStrip()
            presentToast(ModelAbilities.dropped(dropped))
        }
        composer.showsAttach = canAttachAnything
    }
}

extension ChatViewController: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        let taken = urls.prefix(room(for: urls.count))
        let attached = taken.filter { attachFile(at: $0, quiet: true) }
        guard !attached.isEmpty else { return }
        Theme.Haptics.success()
        updateAttachmentStrip()
        presentToast(Self.attachedNote(names: attached.map(\.lastPathComponent)))
    }

    /// How many more this send can carry, said once rather than discovered one refusal at a time.
    func room(for asked: Int) -> Int {
        let free = max(0, Self.attachmentCountLimit - pendingAttachments.count)
        if asked > free {
            presentToast(
                String(
                    localized:
                        "A message carries \(Self.attachmentCountLimit) attachments — the rest were left out."
                ))
        }
        return free
    }

    private static func attachedNote(names: [String]) -> String {
        guard names.count > 1 else {
            return String(localized: "\(names[0]) attached — it'll be sent with your next message.")
        }
        return String(
            localized: "\(names.count) attached — they'll be sent with your next message.")
    }

    /// The whole payload rides base64-encoded inside the send, whose timeout
    /// scales with its size — so an oversized file is refused up front instead
    /// of failing halfway into a turn.
    static let attachmentSizeLimit = 8 * 1024 * 1024

    /// Answers whether the file made it, so a selection of several can say what happened once
    /// instead of stacking a toast per file over the composer.
    @discardableResult
    private func attachFile(at url: URL, quiet: Bool = false) -> Bool {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            presentToast(String(localized: "Couldn't read \(name)."))
            return false
        }
        guard data.count <= Self.attachmentSizeLimit else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            presentToast(String(localized: "\(name) is \(size) — attachments are capped at 8 MB."))
            return false
        }
        let mime =
            UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        guard viewModel.abilities.accepts(mime: mime) else {
            presentToast(
                mime.hasPrefix("image/")
                    ? String(localized: "This model can't see images.")
                    : String(localized: "This model can't read \(name)."))
            return false
        }
        pendingAttachments.append(PromptAttachment(mime: mime, filename: name, data: data))
        guard !quiet else { return true }
        Theme.Haptics.success()
        updateAttachmentStrip()
        presentToast(String(localized: "\(name) attached — it'll be sent with your next message."))
        return true
    }
}

extension ChatViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        MidgarLog.info(
            "enhance: chose card \"\(prompt.label)\" (\(prompt.text.count) chars)", category: .ui)
        Theme.Haptics.success()
        isApplyingEnhancedPrompt = true
        composer.setDraft(prompt.text, focus: true)
        isApplyingEnhancedPrompt = false
        flushDraft()
        overlay.requestDismiss()
    }

    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt) {
        UIPasteboard.general.string = prompt.text
        Theme.Haptics.success()
        presentToast(String(localized: "Enhanced prompt copied."))
    }

    func enhanceOverlayDidRequestRetry(_ overlay: PromptEnhanceOverlay) {
        Theme.Haptics.tap()
        enhancement.retry()
    }

    func enhanceOverlayDidDismiss(_ overlay: PromptEnhanceOverlay) {
        if enhanceOverlay === overlay { enhanceOverlay = nil }
        composer.setEnhanceHint(enhancement.hasFreshSuggestions)
    }
}

extension ChatViewController: PHPickerViewControllerDelegate {
    /// A whole selection, kept in the order it was chosen. The pictures arrive from the library one
    /// callback at a time and in no particular order, so each lands in the slot it was picked into
    /// and the strip only grows once they are all in — a row that reshuffles itself while somebody
    /// watches is a row they have to re-read.
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let taken = Array(results.prefix(room(for: results.count)))
        guard !taken.isEmpty else { return }
        Task { @MainActor [weak self] in
            var attachments: [PromptAttachment] = []
            for result in taken {
                guard let data = await Self.imageData(from: result.itemProvider) else { continue }
                let (mime, ext) = ImageBytes.kind(of: data)
                attachments.append(
                    PromptAttachment(
                        mime: mime, filename: "image-\(UUID().uuidString.prefix(8)).\(ext)",
                        data: data))
            }
            guard let self else { return }
            guard !attachments.isEmpty else {
                self.presentToast(String(localized: "Couldn't read that picture."))
                return
            }
            self.pendingAttachments.append(contentsOf: attachments)
            self.presentAttachmentToast(count: attachments.count)
        }
    }

    @MainActor
    private static func imageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func presentAttachmentToast(count: Int = 1) {
        Theme.Haptics.success()
        updateAttachmentStrip()
        presentToast(
            count > 1
                ? String(localized: "\(count) images attached — they'll ride your next message.")
                : String(localized: "Image attached — it'll be sent with your next message."))
    }

    func updateAttachmentStrip() {
        attachmentStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, attachment) in pendingAttachments.enumerated() {
            let image = attachment.mime.hasPrefix("image/") && attachment.data != nil
                ? UIImage(data: attachment.data!) : nil
            let chip = AttachmentChip(
                label: attachment.filename ?? attachment.mime, image: image
            ) { [weak self] in
                guard let self, self.pendingAttachments.indices.contains(index) else { return }
                self.pendingAttachments.remove(at: index)
                self.updateAttachmentStrip()
                if self.pendingAttachments.isEmpty {
                    self.composer.showsAttach = self.canAttachAnything
                }
            }
            attachmentStrip.addArrangedSubview(chip)
        }
        attachmentStrip.isHidden = pendingAttachments.isEmpty
        composer.carriesAttachments = !pendingAttachments.isEmpty
        view.setNeedsLayout()
    }
}
