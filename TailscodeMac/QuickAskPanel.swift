import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The quick-ask surface, drawn as a palette: a borderless sheet of glass that arrives over whatever
/// was in front, the question as its largest thing, and everything else in the order a hand
/// reaches for it. Under the question one row of pills names where it goes — the machine, the
/// model at its level, what can be handed over — and changes any of it in one press; under that,
/// the list (`QuickAskMenu`): what was just copied with its errands, the person's actions, what is
/// waiting for later and what was asked here, walked with ↑↓ and run with Return, the first nine
/// on ⌘1…⌘9. Typing turns the list into the verbs for the words typed — ↓ from the last line steps
/// into them, ⌘1… picks one — and the foot says in one line of keys what the keys do for the box
/// as it is now. The panel is the person's to size and move: it opens under the pointer, the head
/// of the question box where the pointer is, at the size it was last given
/// (`QuickAskPlacementStore`), and the list takes whatever height the question and the foot leave
/// it.
/// Return is still the whole ceremony: the words and anything attached go out as a new
/// conversation with no project on the machine named in the pill, and the panel stays only long
/// enough for that machine to answer, so a failed mint keeps the question in hand. The aim is the
/// quick ask's own: `QuickAskDefaults` remembers where the last ask went and which model answered,
/// per server and beside the composer's memory rather than inside it.
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
///
/// The panel is built once and kept: closing puts it away (`standby`) and the next summon brings it
/// back with what that summon knows (`arrive`), so a chord costs placing and showing a panel rather
/// than building one.
@MainActor
final class QuickAskPanel: NSPanel {
    private(set) static weak var frontmost: QuickAskPanel?
    /// The panel while it is put away, built and laid out, waiting for the next summon.
    private static var standby: QuickAskPanel?

    let editor = PromptEditor(placeholder: Localized.text("Ask anything…"))
    /// The mark at the head of the question box: the point of the panel the pointer lands on.
    let spark = NSImageView(
        image: NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) ?? NSImage())
    let machinePill: QuickAskMachinePill
    let dialPill = DialPill()
    let attachButton = NSButton()
    let screenButton = NSButton()
    let sendButton = NSButton()
    let chips = AttachmentChips()
    let status = NSTextField(wrappingLabelWithString: "")
    let starters = NSStackView()
    let listScroll = NSScrollView()
    let listRule = NSBox()
    let footKeys = NSStackView()
    let chordLabel = NSTextField(labelWithString: "")
    /// The card inside the glass, pinned to it edge to edge, so the panel's size is the card's and
    /// what the card needs at least is what the panel can be made no smaller than.
    var card: NSView?
    var menuItems: [QuickAskMenuItem] = []
    var menuRows: [QuickAskRowView] = []
    /// The list as drawn for each state of the box on each machine, kept so going back to one costs
    /// nothing.
    var starterPages: [QuickAskStarterPage.Key: QuickAskStarterPage] = [:]
    /// The keys the foot was last drawn with, so a redraw that says the same thing builds nothing.
    var footShown: [QuickAskFooter.Key] = []
    var menuCursor = QuickAskMenuCursor()
    /// Whether the list was last drawn for a typed box, so it is redrawn as the verbs or as
    /// everything only when that flips.
    var typingShown: Bool?
    let completion = CompletionPopover()
    var servers: [ConnectionProfile]
    var recents: [SessionEntry]
    var attachments: [PendingAttachment] = []
    var offered: [QuickAskStarter] = []
    /// What the pasteboard was last seen holding, as far as it could be told without reading it,
    /// and the change count that names it.
    var clipboard: (holding: QuickAskClipboardHolding, fingerprint: String)?
    var copied: QuickAskCopied?
    var picks: [QuickAskMenuItem] = []
    var commands: [AgentCommand] = []
    var completionMatches: [SlashMatch] = []
    var completionCursor = 0
    var pastedImageCount = 0
    var asking = false
    var draftProfileID: String?
    var keyMonitor: Any?
    /// Set once the panel has been put under the pointer, so a panel that never stood on a screen —
    /// one a self-test made — never overwrites the size the person keeps it at.
    var isPlaced = false
    var chosenSize: NSSize?
    var roomScheduled = false
    var liveResizeObserver: NSObjectProtocol?
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
    private var onAsk:
        (String, QuickAskSend, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void)
            -> Void
    var onResume: (SessionEntry) -> Void
    var onAskParty: (QuickAskPartySend, @escaping @MainActor (NewChatFailure?) -> Void) -> Void
    /// Which summon the panel is serving. A mint answers long after its Return, and the panel it
    /// answers may by then have been put away and brought back for another question.
    var visit = 0
    /// The aim an action moved for one question, put back once the question has left.
    var hold: QuickAskAimHold?
    /// An action part way through fetching what its template names.
    var gathering: QuickAskGathering?
    var actionsObserver: NSObjectProtocol?
    var laterObserver: NSObjectProtocol?
    var actionSheet: QuickAskActionSheet?

    static func present(
        over window: NSWindow?, servers: [ConnectionProfile], preferredServer: String?,
        recents: [SessionEntry],
        onAsk: @escaping (
            String, QuickAskSend, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping (SessionEntry) -> Void,
        onAskParty: @escaping (QuickAskPartySend, @escaping @MainActor (NewChatFailure?) -> Void)
            -> Void
    ) {
        guard !servers.isEmpty else { return }
        if let frontmost, frontmost.isVisible { frontmost.close() }
        let panel =
            standby
            ?? QuickAskPanel(
                servers: servers, preferredServer: preferredServer, recents: recents, onAsk: onAsk,
                onResume: onResume, onAskParty: onAskParty)
        standby = nil
        panel.arrive(
            servers: servers, preferredServer: preferredServer, recents: recents, onAsk: onAsk,
            onResume: onResume, onAskParty: onAskParty)
        panel.place(at: NSEvent.mouseLocation, near: window)
        panel.makeKeyAndOrderFront(nil)
        panel.editor.focus()
        frontmost = panel
    }

    /// Builds the panel ahead of the first summon and keeps it out of sight.
    static func prepare(
        over window: NSWindow?, servers: [ConnectionProfile], preferredServer: String?,
        recents: [SessionEntry],
        onAsk: @escaping (
            String, QuickAskSend, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping (SessionEntry) -> Void,
        onAskParty: @escaping (QuickAskPartySend, @escaping @MainActor (NewChatFailure?) -> Void)
            -> Void
    ) {
        guard frontmost == nil, standby == nil, !servers.isEmpty else { return }
        let panel = QuickAskPanel(
            servers: servers, preferredServer: preferredServer, recents: recents, onAsk: onAsk,
            onResume: onResume, onAskParty: onAskParty)
        panel.unwatch()
        panel.commandFetch?.cancel()
        panel.catalogWatch?.cancel()
        standby = panel
    }

    /// Brings the panel up for one summon, with what that summon knows: the machines, the chats it
    /// can reopen, what sending does, the draft filed under the machine it aims at, and whatever
    /// the pasteboard holds now.
    private func arrive(
        servers: [ConnectionProfile], preferredServer: String?, recents: [SessionEntry],
        onAsk: @escaping (
            String, QuickAskSend, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping (SessionEntry) -> Void,
        onAskParty: @escaping (QuickAskPartySend, @escaping @MainActor (NewChatFailure?) -> Void)
            -> Void
    ) {
        visit += 1
        self.servers = servers
        self.recents = recents
        self.onAsk = onAsk
        self.onResume = onResume
        self.onAskParty = onAskParty
        aimedServerID = QuickAskDefaults.target(
            among: servers.map(\.id), fallback: preferredServer)
        machinePill.reload(servers: servers)
        shortcuts = ShortcutSet.load()
        watch()
        restoreDraft()
        clipboard = Self.detectClipboard()
        refreshAim()
        refreshCommands()
    }

    init(
        servers: [ConnectionProfile], preferredServer: String?, recents: [SessionEntry],
        onAsk: @escaping (
            String, QuickAskSend, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void
        ) -> Void,
        onResume: @escaping (SessionEntry) -> Void,
        onAskParty: @escaping (QuickAskPartySend, @escaping @MainActor (NewChatFailure?) -> Void)
            -> Void
    ) {
        self.servers = servers
        self.recents = recents
        self.onAsk = onAsk
        self.onResume = onResume
        self.onAskParty = onAskParty
        self.machinePill = QuickAskMachinePill(servers: servers)
        super.init(
            contentRect: NSRect(
                x: 0, y: 0, width: QuickAskGeometry.defaultWidth,
                height: QuickAskGeometry.defaultHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        title = Localized.text("Quick ask")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        contentMinSize = NSSize(
            width: QuickAskGeometry.minimumWidth, height: QuickAskGeometry.minimumHeight)

        editor.isBare = true
        editor.onChanged = { [weak self] in
            if let self, !self.asking, !self.status.isHidden { self.setStatus("") }
            self?.releaseHoldIfEmptied()
            self?.stashDraft()
            self?.refreshStarterVisibility()
            self?.updateSlashCompletion()
            self?.refreshAura()
            self?.renderTyping()
            self?.refreshSend()
            self?.makeRoom()
        }
        editor.onPaste = { [weak self] in self?.takeClipboard() ?? false }

        aimedServerID = QuickAskDefaults.target(
            among: servers.map(\.id), fallback: preferredServer)
        machinePill.onPick = { [weak self] id in
            guard let self, id != self.aimedServerID else { return }
            self.aim(at: id)
            self.refreshAim()
            self.editor.focus()
        }

        dialPill.onPress = { [weak self] in self?.pressModelPill() }
        dialPill.onStep = { [weak self] delta in self?.stepEffort(by: delta) }
        dialPill.usage = Localized.text(
            "The model the question runs on and how hard it thinks — scroll to step the effort")

        for (button, title, symbol, action) in [
            (attachButton, Localized.text("Attach"), "paperclip", #selector(pickAttachments)),
            (screenButton, Localized.text("Screen"), "rectangle.dashed", #selector(grabScreenPressed)),
        ] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = MacTheme.Ramp.font(.control)
            button.title = title
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            button.imagePosition = .imageLeading
            button.target = self
            button.action = action
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        screenButton.toolTip = Localized.text("Drag over part of the screen — ⌘⇧S")

        sendButton.bezelStyle = .circular
        sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: Localized.text("Send"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
        sendButton.imagePosition = .imageOnly
        sendButton.target = self
        sendButton.action = #selector(submit)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)

        status.font = MacTheme.Ramp.font(.panelFootnote)
        status.textColor = MacTheme.Color.accent
        status.isSelectable = false
        status.maximumNumberOfLines = 0
        status.isHidden = true

        starters.orientation = .vertical
        starters.alignment = .leading
        starters.spacing = 1
        starters.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)
        starters.translatesAutoresizingMaskIntoConstraints = false
        listScroll.contentView = QuickAskTopClip()
        listScroll.documentView = starters
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            starters.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
            starters.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor),
            starters.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
        ])
        listScroll.setContentHuggingPriority(.init(1), for: .vertical)
        listScroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true

        chips.onRemove = { [weak self] id in
            guard let self else { return }
            self.attachments.removeAll { $0.id == id }
            self.syncAttachments()
        }

        completion.hasProject = false
        completion.onPick = { [weak self] command in self?.accept(command) }

        spark.symbolConfiguration = .init(pointSize: 17, weight: .semibold)
        spark.contentTintColor = MacTheme.Color.accent
        spark.setContentHuggingPriority(.required, for: .horizontal)
        let field = NSStackView(views: [spark, editor, sendButton])
        field.orientation = .horizontal
        field.alignment = .top
        field.spacing = 10

        let slack = NSView()
        slack.setContentHuggingPriority(.init(1), for: .horizontal)
        slack.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let aim = NSStackView(views: [machinePill, dialPill, attachButton, screenButton, slack])
        aim.orientation = .horizontal
        aim.spacing = 6

        let head = NSStackView(views: [field, completion, aim, chips, status])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 10
        head.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)

        listRule.boxType = .separator
        let footRule = NSBox()
        footRule.boxType = .separator
        footKeys.orientation = .horizontal
        footKeys.spacing = 12
        chordLabel.font = MacTheme.Ramp.font(.panelFootnote)
        chordLabel.textColor = MacTheme.Color.tertiaryLabel
        let footSlack = NSView()
        footSlack.setContentHuggingPriority(.init(1), for: .horizontal)
        let foot = NSStackView(views: [footKeys, footSlack, chordLabel])
        foot.orientation = .horizontal
        foot.edgeInsets = NSEdgeInsets(top: 9, left: 18, bottom: 11, right: 18)

        let column = QuickAskDropView(views: [head, listRule, listScroll, footRule, foot])
        column.orientation = .vertical
        column.alignment = .leading
        column.distribution = .fill
        column.spacing = 0
        for view in [head, listRule, footRule, foot] {
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        column.onDrop = { [weak self] urls in self?.attach(paths: urls.map(\.path)) }
        column.onDropImage = { [weak self] data in self?.addPastedImage(data) }
        column.registerForDraggedTypes([.fileURL, .png, .tiff])
        for view in [head, listRule, listScroll, footRule, foot] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        for view in [field, aim, status] {
            view.widthAnchor.constraint(equalTo: head.widthAnchor, constant: -36).isActive = true
        }
        starters.widthAnchor.constraint(equalTo: listScroll.widthAnchor).isActive = true
        card = column
        let glass = MacTheme.glass(around: column, cornerRadius: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            column.topAnchor.constraint(equalTo: glass.topAnchor),
            column.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        contentView = glass
        clipboard = Self.detectClipboard()
        refreshAim()
        refreshCommands()
        watch()
    }

    /// What reaches into the panel while it is up: its keys, the person's actions and waiting
    /// questions changing elsewhere, and a resize by hand finishing.
    private func watch() {
        unwatch()
        installMonitor()
        actionsObserver = NotificationCenter.default.addObserver(
            forName: QuickAskActions.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderStarters() }
        }
        liveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sizeChosen() }
        }
        laterObserver = NotificationCenter.default.addObserver(
            forName: QuickAskLaterStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.asking else { return }
                self.renderStarters()
            }
        }
    }

    override var canBecomeKey: Bool { true }

    /// The pasteboard is looked at again whenever the panel comes back to the front, since the
    /// thing a person copies is often copied with the panel already open behind them.
    override func becomeKey() {
        super.becomeKey()
        readCopied()
    }

    override func cancelOperation(_ sender: Any?) {
        if menuCursor.index != nil {
            clearSelection()
            return
        }
        if gathering != nil {
            cancelGathering()
            return
        }
        close()
    }

    @objc func grabScreenPressed() {
        grabScreen()
    }

    private func unwatch() {
        if let actionsObserver { NotificationCenter.default.removeObserver(actionsObserver) }
        actionsObserver = nil
        if let laterObserver { NotificationCenter.default.removeObserver(laterObserver) }
        laterObserver = nil
        if let liveResizeObserver { NotificationCenter.default.removeObserver(liveResizeObserver) }
        liveResizeObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// A question is only ever lost in the moment nobody thought to save it, and a panel dismissed
    /// with escape is exactly that moment. The panel a summon showed is then put away for the next
    /// one rather than let go: what was typed is filed under its machine, and what was in hand,
    /// what was copied, the line picked and a notice are let go, so it comes back the way a new one
    /// would.
    override func close() {
        remember()
        super.close()
        releaseHold(retargeting: false)
        gathering = nil
        actionSheet?.dismiss()
        unwatch()
        stashDraft()
        DraftStore.flush()
        dialPopover?.close()
        partyPopover?.close()
        makeRoomPopover?.close()
        dismissCompletion()
        commandFetch?.cancel()
        catalogWatch?.cancel()
        if asking { unlock() }
        clipboard = nil
        copied = nil
        attachments = []
        pastedImageCount = 0
        syncAttachments()
        setStatus("")
        menuCursor.clear()
        paintSelection()
        if Self.frontmost === self { Self.standby = self }
    }

    /// Whether an answer that arrives now belongs to the question on screen: the one asked on this
    /// visit, with the panel still up for it.
    func isServing(_ visit: Int) -> Bool {
        Self.frontmost === self && isVisible && self.visit == visit
    }

    /// The box is the person's again after a send that did not go out, or one the panel was put
    /// away in the middle of.
    func unlock() {
        asking = false
        editor.isEditable = true
        machinePill.isEnabled = true
        dialPill.isEnabled = true
        attachButton.isEnabled = true
        screenButton.isEnabled = true
        refreshSend()
    }

    /// What a question that went out leaves behind, whether or not the panel is still up for it,
    /// since it may have been put away while the machine was minting: what was copied is set
    /// aside, and the words stop being a draft unless something new was written over them since.
    static func sent(_ text: String, on profileID: String, settling offer: String?) {
        if let offer { QuickAskClipboardMemory.settle(offer) }
        let scope = DraftScope.quickAsk(profileID: profileID)
        let filed = DraftStore.text(for: scope).trimmingCharacters(in: .whitespacesAndNewlines)
        guard filed == text else { return }
        DraftStore.clear(scope)
        guard let open = frontmost, open.isVisible, open.targetServer.id == profileID,
            open.editor.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
        else { return }
        open.editor.setText("", caretAtEnd: true)
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

    /// The panel's own chords: a number picks the line wearing it — an errand or an action for an
    /// empty box, a verb for a typed one — and ⌘⇧V takes the pasteboard's picture. Everything else
    /// belongs to the field, which is where the question is. A number past the lines on show is
    /// left alone rather than reaching for an action nobody can see.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !asking, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.contains(.shift), event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteImageAttachment()
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "l",
            !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control),
            !event.modifierFlags.contains(.shift)
        {
            offerLater()
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "s",
            !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control)
        {
            if event.modifierFlags.contains(.shift) { grabScreen() } else { saveAsAction() }
            return true
        }
        guard let characters = event.charactersIgnoringModifiers, let digit = Int(characters),
            digit > 0, digit <= picks.count
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
        machinePill.isEnabled = false
        dialPopover?.close()
        partyPopover?.close()
        makeRoomPopover?.close()
        dialPill.isEnabled = false
        attachButton.isEnabled = false
        screenButton.isEnabled = false
        sendButton.isEnabled = false
        refreshStarterVisibility()
        setStatus(QuickAskComposition.waitingTitle(server: server.name))
        let visit = visit
        onAsk(server.id, send, attachments) { [weak self] failure in
            guard let self else { return }
            if failure == nil {
                QuickAskDefaults.record(profileID: server.id)
                Self.sent(text, on: server.id, settling: onOffer)
            }
            guard self.isServing(visit) else { return }
            guard let failure else {
                self.releaseHold(retargeting: false)
                self.close()
                return
            }
            self.unlock()
            self.setStatus("\(failure.title) — \(failure.detail)")
            self.refreshStarterVisibility()
            self.editor.focus()
        }
    }
}


/// The list's clip, flipped so the list reads from its top: an unflipped clip shows the bottom of a
/// list taller than the panel lets it be.
@MainActor
final class QuickAskTopClip: NSClipView {
    override var isFlipped: Bool { true }
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
