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
/// Something newly copied leads the empty panel as a card of its own (`QuickAskClipboard`),
/// because a question summoned from anywhere is most often about the thing just copied.
///
/// Which machine answers is the first thing on the panel rather than a chip found by hovering:
/// every server is a segment of one strip, named and wearing its agent's symbol, the aimed one
/// selected, and a click or Tab — the key the Linux window spends on the same move — re-aims the
/// question without a menu in between. A fleet too wide for segments becomes one popup, still a
/// single click to the list.
///
/// It is a composer, so a slash means here what it means in a chat: the aimed machine's own
/// catalog, minus the commands that read a transcript the mint has yet to write, ranked and walked
/// the way the chat's box ranks and walks it — and what is typed leaves as the decision
/// `QuickAskSend` made rather than as the word it was typed as.
///
/// Model and effort are one decision here as they are in the chat's box, so the aim's second
/// half is the composer's own dial: one `DialPill` wearing the model's word and the level's heat,
/// the wheel over it and ⌃⌥↑↓ stepping the level without opening anything. A press opens the
/// party (`PartyPopover`, the very six slots the chat's pill opens — one party, this device's, not
/// a copy), and a slot taken aims the question at that model, that level and that machine as one
/// decision; ⌃⌥1-6 and the ring do the same without opening it. ⌥-press or ⌥M/⌥E opens
/// `ModelDialPopover` — the shortlist beside the ladder — over the quick ask's own memory rather
/// than the server's.
@MainActor
final class QuickAskPanel: NSPanel {
    private(set) static weak var frontmost: QuickAskPanel?

    let editor = PromptEditor(
        placeholder: Localized.text("Ask anything — no project, no setup"))
    let aimStrip: QuickAskAimStrip
    let dialPill = DialPill()
    let attachButton = NSButton()
    let chips = AttachmentChips()
    let status = NSTextField(wrappingLabelWithString: "")
    let starters = NSStackView()
    let completion = CompletionPopover()
    let servers: [ConnectionProfile]
    let recents: [SessionEntry]
    var attachments: [PendingAttachment] = []
    var offered: [QuickAskStarter] = []
    /// What the pasteboard was last seen holding, as far as it could be told without reading it,
    /// and the change count that names it.
    var clipboard: (holding: QuickAskClipboardHolding, fingerprint: String)?
    var copied: QuickAskCopied?
    var picks: [Pick] = []
    var commands: [AgentCommand] = []
    var completionMatches: [SlashMatch] = []
    var completionCursor = 0
    var pastedImageCount = 0
    var asking = false
    var draftProfileID: String?
    var keyMonitor: Any?
    var resizeScheduled = false
    var modelSheet: ModelChooserSheet?
    var dialPopover: ModelDialPopover?
    var dialClosedAt: Date?
    var partyPopover: PartyPopover?
    var makeRoomPopover: PartyPopover?
    var partyClosedAt: Date?
    var shortcuts = ShortcutSet.load()
    var catalogWatch: Task<Void, Never>?
    var watchedServerID: String?
    var commandFetch: Task<Void, Never>?
    private let onAsk:
        (String, QuickAskSend, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void)
            -> Void
    let onResume: (SessionEntry) -> Void

    static func present(
        over window: NSWindow?, servers: [ConnectionProfile], preferredServer: String?,
        recents: [SessionEntry],
        onAsk: @escaping (
            String, QuickAskSend, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void
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
        panel.restoreDraft()
        panel.makeKeyAndOrderFront(nil)
        panel.editor.focus()
        frontmost = panel
    }

    init(
        servers: [ConnectionProfile], preferredServer: String?, recents: [SessionEntry],
        onAsk: @escaping (
            String, QuickAskSend, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping (SessionEntry) -> Void
    ) {
        self.servers = servers
        self.recents = recents
        self.onAsk = onAsk
        self.onResume = onResume
        self.aimStrip = QuickAskAimStrip(servers: servers)
        super.init(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = Localized.text("Quick ask")
        isFloatingPanel = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
        editor.onChanged = { [weak self] in
            self?.stashDraft()
            self?.refreshStarterVisibility()
            self?.updateSlashCompletion()
            self?.refreshAura()
            self?.resize()
        }
        editor.onPaste = { [weak self] in self?.takeClipboard() ?? false }

        aimedServerID = QuickAskDefaults.target(
            among: servers.map(\.id), fallback: preferredServer)
        aimStrip.isHidden = servers.count < 2
        aimStrip.onPick = { [weak self] id in
            guard let self, id != self.aimedServerID else { return }
            self.aim(at: id)
            self.refreshAim()
            self.editor.focus()
        }

        dialPill.onPress = { [weak self] in self?.pressModelPill() }
        dialPill.onStep = { [weak self] delta in self?.stepEffort(by: delta) }
        dialPill.usage = Localized.text(
            "The model the question runs on and how hard it thinks — scroll to step the effort")

        attachButton.bezelStyle = .rounded
        attachButton.controlSize = .small
        attachButton.title = Localized.text("Attach…")
        attachButton.target = self
        attachButton.action = #selector(pickAttachments)

        status.font = MacTheme.Ramp.font(.panelFootnote)
        status.textColor = MacTheme.Color.secondaryLabel
        status.isSelectable = false
        status.maximumNumberOfLines = 0

        starters.orientation = .vertical
        starters.alignment = .leading
        starters.spacing = QuickAskTiles.spacing

        chips.onRemove = { [weak self] id in
            guard let self else { return }
            self.attachments.removeAll { $0.id == id }
            self.syncAttachments()
        }

        completion.hasProject = false
        completion.onPick = { [weak self] command in self?.accept(command) }

        let slack = NSView()
        slack.setContentHuggingPriority(.init(1), for: .horizontal)
        slack.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let aim = NSStackView(views: [dialPill, attachButton, slack])
        aim.orientation = .horizontal
        aim.distribution = .fill
        aim.spacing = 8
        let column = QuickAskDropView(views: [
            aimStrip, editor, completion, chips, aim, status, starters,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        column.onDrop = { [weak self] urls in self?.attach(paths: urls.map(\.path)) }
        column.onDropImage = { [weak self] data in self?.addPastedImage(data) }
        column.registerForDraggedTypes([.fileURL, .png, .tiff])
        contentView = column
        status.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        clipboard = Self.detectClipboard()
        refreshAim()
        refreshCommands()
        installMonitor()
        resize()
    }

    override var canBecomeKey: Bool { true }

    /// The pasteboard is looked at again whenever the panel comes back to the front, since the
    /// thing a person copies is often copied with the panel already open behind them.
    override func becomeKey() {
        super.becomeKey()
        readCopied()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// A question is only ever lost in the moment nobody thought to save it, and a panel dismissed
    /// with escape is exactly that moment.
    override func close() {
        stashDraft()
        DraftStore.flush()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        dialPopover?.close()
        partyPopover?.close()
        makeRoomPopover?.close()
        commandFetch?.cancel()
        catalogWatch?.cancel()
        super.close()
    }

    /// The powers are visibly on before the question is sent: the aim's own effort, or the word
    /// typed into the draft, lights the same rainbow the chat's box wears.
    func refreshAura() {
        editor.setAura(
            editor.auraActive(
                effort: QuickAskDefaults.effort(forProfileID: targetServer.id), inFlight: false))
    }

    /// The clipboard, whatever it is holding: a screenshot or a file copied in the Finder becomes
    /// a chip, and words are handed back to AppKit so undo and selection stay the system's.
    private func takeClipboard() -> Bool {
        let plan = PasteIntake.plan(
            for: pasteboardOffer(), abilities: abilities, alreadyNamed: pastedImageCount)
        pastedImageCount = plan.named
        if let notice = plan.notices.first { setStatus(notice) }
        guard plan.text == nil else { return false }
        guard !plan.attachments.isEmpty else { return !plan.notices.isEmpty }
        attachments.append(contentsOf: plan.attachments)
        syncAttachments()
        return true
    }

    /// The pasteboard whole, in the one shape a paste is decided against: copied files first, then
    /// a picture, then words, the order a person means them in.
    func pasteboardOffer() -> ClipboardOffer {
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
        return offer
    }

    /// The panel's own chords: a number picks the errand under it, ⌘⇧V takes the pasteboard's
    /// picture. Everything else belongs to the field, which is where the question is. A number is
    /// claimed exactly while its list is on screen — with a question already typed there is no row
    /// under ⌘4 to pick, and taking the chord anyway would open a file chooser over a panel with
    /// nothing on it to say what asked.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !asking, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteImageAttachment()
            return true
        }
        guard !starters.isHidden, let characters = event.charactersIgnoringModifiers,
            let digit = Int(characters), digit > 0
        else { return super.performKeyEquivalent(with: event) }
        pick(at: digit - 1)
        return true
    }

    var aimedServerID: String?

    var draftScope: DraftScope { .quickAsk(profileID: targetServer.id) }

    /// The panel outlives Enter the way the new-chat sheet outlives Start: the mint happens on
    /// another machine, and a surface that vanished the instant a request went out could never
    /// say it failed. Success closes it; failure names itself and gives the words — and the
    /// pictures — back.
    @objc func submit() {
        guard !asking else { return }
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickAskComposition.canSend(text: text, attachments: attachments.count) else { return }
        let server = targetServer
        let onOffer = copied?.fingerprint
        let send = QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: ServerDirectory.shared.backend(for: server)?
                .resolvesCommandsFromPromptText == true)
        asking = true
        dismissCompletion()
        editor.isEditable = false
        aimStrip.isEnabled = false
        dialPopover?.close()
        partyPopover?.close()
        makeRoomPopover?.close()
        dialPill.isEnabled = false
        attachButton.isEnabled = false
        refreshStarterVisibility()
        setStatus(QuickAskComposition.waitingTitle(server: server.name))
        onAsk(server.id, send, attachments) { [weak self] failure in
            guard let self else { return }
            guard let failure else {
                QuickAskDefaults.record(profileID: server.id)
                if let onOffer { QuickAskClipboardMemory.settle(onOffer) }
                DraftStore.clear(.quickAsk(profileID: server.id))
                self.close()
                return
            }
            self.asking = false
            self.editor.isEditable = true
            self.aimStrip.isEnabled = true
            self.dialPill.isEnabled = true
            self.attachButton.isEnabled = true
            self.setStatus("\(failure.title) — \(failure.detail)")
            self.refreshStarterVisibility()
            self.editor.focus()
        }
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
