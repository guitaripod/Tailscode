import AppKit
import CodingAgentKit
import TailscodeCore

extension ComposerView {
    var attachmentsSupported: Bool {
        backend?.capabilities.supportsAttachments != false
    }

    func attachMenuRows() -> [PillsRow.MenuRow] {
        let able = abilities
        if let reason = able.unavailableReason(supportsAttachments: attachmentsSupported) {
            return [PillsRow.MenuRow(reason)]
        }
        var rows = [
            PillsRow.MenuRow(
                Localized.text("Attach files…"), subtitle: Localized.text("Up to 8 MB each")
            ) { [weak self] in
                self?.pickAttachments()
            }
        ]
        guard able.vision else { return rows }
        rows.append(
            PillsRow.MenuRow(
                Localized.text("Paste image"),
                subtitle: Localized.text("From the clipboard, as PNG")
            ) { [weak self] in
                self?.pasteImageAttachment()
            })
        return rows
    }

    private func pickAttachments() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(paths: panel.urls.map(\.path))
        }
    }

    /// Read fully at pick time, so a file edited or deleted between picking and sending still
    /// sends the bytes that were chosen; a refusal names its reason instead of shrinking a file.
    func attach(paths: [String]) {
        for path in paths {
            switch AttachmentIntake.read(path: path) {
            case .success(let attachment):
                attachments.append(attachment)
            case .failure(let refusal):
                onToast?(refusal.message)
            }
        }
        syncChips()
    }

    func syncChips() {
        chips.set(attachments)
        onAttachmentsChanged?()
    }

    private func pasteImageAttachment() {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .png) ?? pngFromTIFF(pasteboard) else {
            onToast?(Localized.text("The clipboard holds no picture."))
            return
        }
        addPastedImage(data)
    }

    /// ⌘V is an attach as much as a paste. What the clipboard is holding is read into the shape
    /// Core decides against, and only a paste that is words is handed back to the text view — so
    /// the ordinary case keeps AppKit's own undo, selection and smart-quote behaviour, and a
    /// screenshot or a file copied in the Finder becomes a chip instead of nothing at all.
    func takeClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        var offer = ClipboardOffer()
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            offer.paths = urls.filter(\.isFileURL).map(\.path)
        }
        if offer.paths.isEmpty, let data = pasteboard.data(forType: .png) ?? pngFromTIFF(pasteboard)
        {
            offer.image = data
        }
        if offer.paths.isEmpty, offer.image == nil {
            offer.text = pasteboard.string(forType: .string)
        }
        let plan = PasteIntake.plan(
            for: offer, abilities: abilities, alreadyNamed: pastedImageCount)
        pastedImageCount = plan.named
        if let notice = plan.notices.first { onToast?(notice) }
        guard plan.text == nil else { return false }
        guard !plan.attachments.isEmpty else { return !plan.notices.isEmpty }
        attachments.append(contentsOf: plan.attachments)
        syncChips()
        return true
    }

    func addPastedImage(_ data: Data) {
        guard data.count <= AttachmentIntake.byteCap else {
            onToast?(
                Localized.text(
                    "That picture is %@ — the cap is 8 MB",
                    AttachmentIntake.sizeText(data.count)))
            return
        }
        pastedImageCount += 1
        attachments.append(
            PendingAttachment(
                name: "pasted-\(pastedImageCount).png", mime: "image/png", data: data))
        syncChips()
    }

    func pngFromTIFF(_ pasteboard: NSPasteboard) -> Data? {
        guard let tiff = pasteboard.data(forType: .tiff),
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
