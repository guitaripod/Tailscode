import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The quick-ask surface, drawn: one field, the aim it remembered, and what the aim can be
/// handed. Enter is the whole ceremony — the words and anything attached to them go out as a new
/// conversation with no project directory on the server named in the popup, and the panel stays
/// up only long enough for that server to answer, so a failed mint keeps the question in hand
/// rather than swallowing it. The aim is both halves and both are the quick ask's own:
/// `QuickAskDefaults` remembers where the last ask went and which model answered it, per server
/// and beside the composer's memory rather than inside it.
///
/// Owing no form is not the same as being able to do nothing. A file is attached from the button,
/// the pasteboard's picture with ⌘⇧V, and anything dropped on the panel lands in the strip —
/// offered only where the aim can read it. The empty panel argues for itself with
/// `QuickAskStarters` (⌘1…⌘9, or a click) and hands back the last few questions asked on this
/// machine, so the blank field is a way into everything the agent can do instead of a text box.
@MainActor
final class QuickAskPanel: NSPanel {
    private(set) static weak var frontmost: QuickAskPanel?

    private let field = NSTextField()
    private let serverPopup = NSPopUpButton()
    private let modelButton = NSButton()
    private let attachButton = NSButton()
    private let chips = AttachmentChips()
    private let status = NSTextField(labelWithString: "")
    private let starters = NSStackView()
    private let servers: [ConnectionProfile]
    private let recents: [SessionEntry]
    private var attachments: [PendingAttachment] = []
    private var offered: [QuickAskStarter] = []
    private var pastedImageCount = 0
    private var asking = false
    private let onAsk:
        (String, String, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void) ->
            Void
    private let onResume: (SessionEntry) -> Void

    static func present(
        over window: NSWindow?, servers: [ConnectionProfile], preferredServer: String?,
        recents: [SessionEntry],
        onAsk: @escaping (
            String, String, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping (SessionEntry) -> Void
    ) {
        guard !servers.isEmpty else { return }
        frontmost?.close()
        let panel = QuickAskPanel(
            servers: servers, preferredServer: preferredServer, recents: recents, onAsk: onAsk,
            onResume: onResume)
        if let frame = window?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.field)
        frontmost = panel
    }

    private init(
        servers: [ConnectionProfile], preferredServer: String?, recents: [SessionEntry],
        onAsk: @escaping (
            String, String, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping (SessionEntry) -> Void
    ) {
        self.servers = servers
        self.recents = recents
        self.onAsk = onAsk
        self.onResume = onResume
        super.init(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = Localized.text("Quick ask")
        isFloatingPanel = true
        isReleasedWhenClosed = false

        field.placeholderString = Localized.text("Ask anything — no project, no setup")
        field.font = .systemFont(ofSize: 14)
        field.target = self
        field.action = #selector(submit)
        field.delegate = self
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true

        let aimed = QuickAskDefaults.target(
            among: servers.map(\.id), fallback: preferredServer)
        for server in servers { serverPopup.addItem(withTitle: server.name) }
        if let index = servers.firstIndex(where: { $0.id == aimed }) {
            serverPopup.selectItem(at: index)
        }
        serverPopup.isHidden = servers.count < 2
        serverPopup.target = self
        serverPopup.action = #selector(serverChanged)

        modelButton.bezelStyle = .rounded
        modelButton.controlSize = .small
        modelButton.target = self
        modelButton.action = #selector(chooseModel)

        attachButton.bezelStyle = .rounded
        attachButton.controlSize = .small
        attachButton.title = Localized.text("Attach…")
        attachButton.target = self
        attachButton.action = #selector(pickAttachments)

        status.font = .systemFont(ofSize: 11)
        status.textColor = MacTheme.Color.secondaryLabel
        status.lineBreakMode = .byTruncatingTail

        starters.orientation = .vertical
        starters.alignment = .leading
        starters.spacing = 2

        chips.onRemove = { [weak self] id in
            guard let self else { return }
            self.attachments.removeAll { $0.id == id }
            self.syncAttachments()
        }

        let aim = NSStackView(views: [serverPopup, modelButton, attachButton])
        aim.orientation = .horizontal
        aim.spacing = 8
        let column = QuickAskDropView(views: [field, chips, aim, status, starters])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        column.onDrop = { [weak self] urls in self?.attach(paths: urls.map(\.path)) }
        column.onDropImage = { [weak self] data in self?.addPastedImage(data) }
        column.registerForDraggedTypes([.fileURL, .png, .tiff])
        contentView = column
        refreshAim()
        resize()
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// The panel's own chords: a number picks the errand under it, ⌘⇧V takes the pasteboard's
    /// picture. Everything else belongs to the field, which is where the question is.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !asking, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteImageAttachment()
            return true
        }
        guard let characters = event.charactersIgnoringModifiers,
            let digit = Int(characters), digit > 0
        else { return super.performKeyEquivalent(with: event) }
        pickStarter(at: digit - 1)
        return true
    }

    private var targetServer: ConnectionProfile {
        servers[min(max(0, serverPopup.indexOfSelectedItem), servers.count - 1)]
    }

    @objc private func serverChanged() {
        refreshAim()
    }

    /// The whole catalog, from the fleet's own cache — a machine's models are a fact about that
    /// machine, so the chooser can name what another server runs without this ask ever having
    /// talked to it, and a pick landing there re-aims the question rather than moving a chat.
    @objc private func chooseModel() {
        let server = targetServer
        ModelChooserSheet.present(
            on: self, models: ModelCatalogStore.cached(server.id),
            selected: QuickAskDefaults.model(forProfileID: server.id),
            allowsServerDefault: server.backend == .claudeCode
        ) { [weak self] selection in
            QuickAskDefaults.recordModel(selection, forProfileID: server.id)
            self?.refreshAim()
        }
    }

    /// What the aim can be handed, re-read whenever either half of it moves. A picture already in
    /// the strip that the new model cannot read is dropped out loud rather than carried to a send
    /// the other machine would refuse.
    private var abilities: QuickAskAbilities {
        let server = targetServer
        let selection = QuickAskDefaults.model(forProfileID: server.id)
        let capabilities = selection.flatMap { pick in
            ModelCatalogStore.cached(server.id).first {
                $0.providerID == pick.providerID && $0.id == pick.modelID
            }?.capabilities
        }
        return QuickAskAbilities.resolve(supportsAttachments: true, model: capabilities)
    }

    /// The button names what the question will actually run on, and the line under it says how
    /// to send — with one server that line also names the machine, which the hidden popup no
    /// longer can.
    private func refreshAim() {
        let server = targetServer
        modelButton.title = ModelBadge.label(
            model: QuickAskDefaults.model(forProfileID: server.id),
            effort: QuickAskDefaults.effort(forProfileID: server.id))
        modelButton.isHidden = ModelCatalogStore.cached(server.id).isEmpty
        let able = abilities
        attachButton.isHidden = !able.attachments
        let kept = attachments.filter { able.accepts(mime: $0.mime) }
        let dropped = attachments.count - kept.count
        attachments = kept
        syncAttachments()
        renderStarters()
        guard !asking else { return }
        status.stringValue =
            dropped > 0
            ? QuickAskComposition.droppedNotice(count: dropped)
            : (servers.count < 2
                ? Localized.text("Asks %@ — enter sends, esc closes", server.name)
                : Localized.text("Enter sends, esc closes"))
    }

    /// The empty panel's argument for itself: what this thing can be asked to do, offered against
    /// what the aim can take, and the last few questions asked here. It gets out of the way the
    /// moment there is a question and comes back if the field is emptied again.
    private func renderStarters() {
        starters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        offered = QuickAskStarters.offered(for: abilities)
        starters.addArrangedSubview(sectionLabel(Localized.text("Try")))
        for (index, starter) in offered.enumerated() {
            let shortcut = index < 9 ? "   ⌘\(index + 1)" : ""
            let row = RowKit.ActionButton(
                title: "\(starter.title) — \(starter.detail)\(shortcut)"
            ) { [weak self] in
                self?.pickStarter(at: index)
            }
            row.bezelStyle = .inline
            row.controlSize = .small
            row.font = MacTheme.Font.caption()
            starters.addArrangedSubview(row)
        }
        let asked = QuickAskRecents.asks(among: recents, profileID: targetServer.id)
        guard !asked.isEmpty else { return }
        starters.addArrangedSubview(sectionLabel(Localized.text("Asked here")))
        for entry in asked {
            let title = AgentSession.isPlaceholderTitle(entry.session.title)
                ? Localized.text("Untitled question") : entry.session.title
            let row = RowKit.ActionButton(title: "↻  \(title)") { [weak self] in
                self?.resume(entry)
            }
            row.bezelStyle = .inline
            row.controlSize = .small
            row.font = MacTheme.Font.caption()
            starters.addArrangedSubview(row)
        }
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Font.caption()
        label.textColor = MacTheme.Color.secondaryLabel
        return label
    }

    private func refreshStarterVisibility() {
        let empty =
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
        let hidden = !(empty && !asking)
        guard starters.isHidden != hidden else { return }
        starters.isHidden = hidden
        resize()
    }

    private func resize() {
        guard let content = contentView else { return }
        setContentSize(content.fittingSize)
    }

    /// A starter is the first half of a sentence, never a question the app asked on somebody's
    /// behalf: the words land in the field with the caret at their end, and a row that needs a
    /// file opens the chooser for it in the same gesture.
    private func pickStarter(at index: Int) {
        guard !asking, offered.indices.contains(index) else { return }
        let starter = offered[index]
        QuickAskStarterRecents.record(starter.id)
        if field.stringValue.isEmpty {
            field.stringValue = starter.prompt
            field.currentEditor()?.selectedRange = NSRange(
                location: starter.prompt.count, length: 0)
        }
        makeFirstResponder(field)
        refreshStarterVisibility()
        switch starter.opens {
        case .files, .photos: pickAttachments()
        case .camera, .none: break
        }
    }

    private func resume(_ entry: SessionEntry) {
        guard !asking else { return }
        let onResume = onResume
        close()
        onResume(entry)
    }

    @objc private func pickAttachments() {
        guard !asking, abilities.attachments else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(paths: panel.urls.map(\.path))
        }
    }

    /// Read fully at pick time, so a file edited or deleted between picking and sending still
    /// sends the bytes that were chosen; a refusal names its reason instead of shrinking a file.
    private func attach(paths: [String]) {
        let able = abilities
        for path in paths {
            switch AttachmentIntake.read(path: path) {
            case .success(let attachment):
                guard able.accepts(mime: attachment.mime) else {
                    status.stringValue = Localized.text(
                        "This model can't read %@", attachment.name)
                    continue
                }
                attachments.append(attachment)
            case .failure(let refusal):
                status.stringValue = refusal.message
            }
        }
        syncAttachments()
    }

    private func pasteImageAttachment() {
        guard abilities.vision else { return }
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .png) ?? pngFromTIFF(pasteboard) else {
            status.stringValue = Localized.text("The clipboard holds no picture.")
            return
        }
        addPastedImage(data)
    }

    private func addPastedImage(_ data: Data) {
        guard abilities.vision else { return }
        guard data.count <= AttachmentIntake.byteCap else {
            status.stringValue = Localized.text(
                "That picture is %@ — the cap is 8 MB", AttachmentIntake.sizeText(data.count))
            return
        }
        pastedImageCount += 1
        attachments.append(
            PendingAttachment(
                name: "pasted-\(pastedImageCount).png", mime: "image/png", data: data))
        syncAttachments()
    }

    private func pngFromTIFF(_ pasteboard: NSPasteboard) -> Data? {
        guard let tiff = pasteboard.data(forType: .tiff),
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func syncAttachments() {
        chips.set(attachments)
        attachButton.title =
            attachments.isEmpty
            ? Localized.text("Attach…")
            : Localized.text("Attach… (%@)", "\(attachments.count)")
        refreshStarterVisibility()
        resize()
    }

    /// The panel outlives Enter the way the new-chat sheet outlives Start: the mint happens on
    /// another machine, and a surface that vanished the instant a request went out could never
    /// say it failed. Success closes it; failure names itself and gives the words — and the
    /// pictures — back.
    @objc private func submit() {
        guard !asking else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickAskComposition.canSend(text: text, attachments: attachments.count) else { return }
        let server = targetServer
        asking = true
        field.isEnabled = false
        serverPopup.isEnabled = false
        modelButton.isEnabled = false
        attachButton.isEnabled = false
        refreshStarterVisibility()
        status.stringValue = QuickAskComposition.waitingTitle(server: server.name)
        onAsk(server.id, text, attachments) { [weak self] failure in
            guard let self else { return }
            guard let failure else {
                QuickAskDefaults.record(profileID: server.id)
                self.close()
                return
            }
            self.asking = false
            self.field.isEnabled = true
            self.serverPopup.isEnabled = true
            self.modelButton.isEnabled = true
            self.attachButton.isEnabled = true
            self.status.stringValue = "\(failure.title) — \(failure.detail)"
            self.refreshStarterVisibility()
            self.makeFirstResponder(self.field)
        }
    }
}

extension QuickAskPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refreshStarterVisibility()
    }
}

/// The panel's body, which is also where a picture lands. A drop is taken anywhere on the surface
/// rather than on a button: something dragged from a browser or the Finder is a question about
/// that thing, and aiming it at a small target is not a gesture anybody should have to make.
@MainActor
final class QuickAskDropView: NSStackView {
    var onDrop: (([URL]) -> Void)?
    var onDropImage: ((Data) -> Void)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            onDrop?(urls)
            return true
        }
        if let data = pasteboard.data(forType: .png) {
            onDropImage?(data)
            return true
        }
        guard let tiff = pasteboard.data(forType: .tiff),
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        onDropImage?(png)
        return true
    }
}
