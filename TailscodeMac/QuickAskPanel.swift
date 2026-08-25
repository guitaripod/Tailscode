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
///
/// It is a composer, so a slash means here what it means in a chat: the aimed machine's own
/// catalog, minus the commands that read a transcript the mint has yet to write, ranked and walked
/// the way the chat's box ranks and walks it — and what is typed leaves as the decision
/// `QuickAskSend` made rather than as the word it was typed as.
@MainActor
final class QuickAskPanel: NSPanel {
    @objc final class PickBox: NSObject {
        let pick: ModelPick
        init(pick: ModelPick) { self.pick = pick }
    }

    private(set) static weak var frontmost: QuickAskPanel?

    private let editor = PromptEditor(
        placeholder: Localized.text("Ask anything — no project, no setup"))
    private let serverChip = NSButton()
    private let modelButton = NSButton()
    private let effortButton = NSPopUpButton()
    private let attachButton = NSButton()
    private let chips = AttachmentChips()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let starters = NSStackView()
    private let completion = CompletionPopover()
    private let servers: [ConnectionProfile]
    private let recents: [SessionEntry]
    private var attachments: [PendingAttachment] = []
    private var offered: [QuickAskStarter] = []
    private var commands: [AgentCommand] = []
    private var completionMatches: [SlashMatch] = []
    private var completionCursor = 0
    private var pastedImageCount = 0
    private var asking = false
    private var draftProfileID: String?
    private var keyMonitor: Any?
    private var resizeScheduled = false
    private var modelSheet: ModelChooserSheet?
    private var catalogWatch: Task<Void, Never>?
    private var commandFetch: Task<Void, Never>?
    private let onAsk:
        (String, QuickAskSend, [PendingAttachment], @escaping @MainActor (NewChatFailure?) -> Void)
            -> Void
    private let onResume: (SessionEntry) -> Void

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

    private init(
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
        super.init(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = Localized.text("Quick ask")
        isFloatingPanel = true
        isReleasedWhenClosed = false

        editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
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
        serverChip.bezelStyle = .rounded
        serverChip.controlSize = .small
        serverChip.target = self
        serverChip.action = #selector(serverChipPicked)
        serverChip.isHidden = servers.count < 2
        serverChip.showsBorderOnlyWhileMouseInside = true

        modelButton.bezelStyle = .rounded
        modelButton.controlSize = .small
        modelButton.target = self
        modelButton.action = #selector(chooseModel)

        effortButton.controlSize = .small
        effortButton.target = self
        effortButton.action = #selector(effortChanged)

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
        starters.spacing = 2

        chips.onRemove = { [weak self] id in
            guard let self else { return }
            self.attachments.removeAll { $0.id == id }
            self.syncAttachments()
        }

        completion.hasProject = false
        completion.onPick = { [weak self] command in self?.accept(command) }

        let aim = NSStackView(views: [serverChip, modelButton, effortButton, attachButton])
        aim.orientation = .horizontal
        aim.spacing = 8
        let column = QuickAskDropView(views: [editor, completion, chips, aim, status, starters])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        column.onDrop = { [weak self] urls in self?.attach(paths: urls.map(\.path)) }
        column.onDropImage = { [weak self] data in self?.addPastedImage(data) }
        column.registerForDraggedTypes([.fileURL, .png, .tiff])
        contentView = column
        status.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        refreshAim()
        refreshCommands()
        installMonitor()
        resize()
    }

    override var canBecomeKey: Bool { true }

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
        commandFetch?.cancel()
        catalogWatch?.cancel()
        super.close()
    }

    /// The keys the box itself owes an answer to. Return is the send unless the settings say
    /// otherwise and shift always writes the line break — the same bargain the chat's own box
    /// makes — and vim, when it is on, is the same engine wearing the same modes, so escape
    /// leaves insert before it closes the panel.
    ///
    /// The list, while it is up, answers first. Outside insert mode the vim branch swallows every
    /// unmodified key, so a walk claimed after it would never see j or k — and escape has to close
    /// the list before it closes the panel, since a question is lost the moment nobody thought to
    /// keep it. Nothing is taken while the list is down.
    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self, !self.asking else { return event }
            let flags = event.modifierFlags
            let control = flags.contains(.control)
            let shift = flags.contains(.shift)
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if self.completion.isShowing, self.handleCompletionKey(event) { return nil }
            if PromptEditor.vimPreferred, self.editor.hasFocus {
                let key = PromptEditor.vimKey(for: event)
                let letter = event.charactersIgnoringModifiers?.lowercased()
                if self.editor.vim.mode == .insert {
                    if key.isEscape || (control && letter == "[") {
                        self.applyVim(VimKey(isEscape: true))
                        return nil
                    }
                } else if !key.isEscape, !control, !flags.contains(.command),
                    !flags.contains(.option)
                {
                    self.applyVim(key)
                    return nil
                }
            }
            if isReturn, !shift, PromptEditor.sendOnReturn || control {
                self.submit()
                return nil
            }
            return event
        }
    }

    private func applyVim(_ key: VimKey) {
        let outcome = editor.vim.handle(key, text: editor.text, cursor: editor.cursor)
        switch outcome {
        case .handled: editor.write(editor.vim.document, selection: editor.vim.selection)
        case .passThrough: break
        case .send: submit()
        }
        editor.refreshMode()
    }

    /// The walk, and only the walk: a key is taken while there are rows to move through, so past
    /// the command's name — where the list is showing one signature rather than a choice — enter
    /// still sends and tab still belongs to the panel. Escape closes whatever the list is showing,
    /// because the panel's own escape is the one that throws the question away.
    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard !flags.contains(.command), !flags.contains(.option) else { return false }
        if event.keyCode == 53 {
            dismissCompletion()
            return true
        }
        guard !completionMatches.isEmpty else { return false }
        switch event.keyCode {
        case 48:
            if flags.contains(.shift) { moveCompletion(by: -1) } else { acceptCompletion() }
            return true
        case 36, 76:
            acceptCompletion()
            return true
        case 125:
            moveCompletion(by: 1)
            return true
        case 126:
            moveCompletion(by: -1)
            return true
        default:
            break
        }
        guard flags.contains(.control), let letter = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        if letter == "n" {
            moveCompletion(by: 1)
            return true
        }
        if letter == "p" {
            moveCompletion(by: -1)
            return true
        }
        return false
    }

    /// The catalog this ask can offer: what the aimed machine last published, read from memory so
    /// the first keystroke is never blank, minus the commands that read a transcript — the chat
    /// this send mints has none — and nothing at all from a server whose agent has no commands.
    /// The fetch carries no directory, because a quick ask has no project.
    private func refreshCommands() {
        let server = targetServer
        commandFetch?.cancel()
        guard let backend = ServerDirectory.shared.backend(for: server),
            backend.capabilities.supportsCommands
        else {
            commands = []
            updateSlashCompletion()
            return
        }
        commands = CommandCatalogStore.forQuickAsk(CommandCatalogStore.cached(server.id))
        updateSlashCompletion()
        commandFetch = Task { [weak self] in
            let fetched = await CommandCatalogStore.refresh(profileID: server.id, backend: backend)
            guard let self, !Task.isCancelled, self.targetServer.id == server.id else { return }
            self.commands = CommandCatalogStore.forQuickAsk(fetched)
            self.updateSlashCompletion()
        }
    }

    /// Which row is highlighted is kept by which command it is, never by where it sat: a narrowing
    /// keystroke re-ranks and shortens the list, and an index would quietly move the highlight onto
    /// a different command — which is then the one Tab takes.
    private func updateSlashCompletion() {
        let typing = !PromptEditor.vimPreferred || editor.vim.mode == .insert
        guard typing, !asking else {
            dismissCompletion()
            return
        }
        let presentation = SlashPresentation.of(
            text: editor.text, commands: commands,
            recents: SlashRecents.surviving(in: commands))
        switch presentation {
        case .hidden:
            dismissCompletion()
        case .naming(let matches):
            let previous =
                completionMatches.indices.contains(completionCursor)
                ? completionMatches[completionCursor].command.id : nil
            completionMatches = matches
            completionCursor =
                previous.flatMap { id in matches.firstIndex { $0.command.id == id } } ?? 0
            completion.renderCompletion(presentation, cursor: completionCursor)
            resize()
        case .arguments, .noMatch:
            completionMatches = []
            completionCursor = 0
            completion.renderCompletion(presentation)
            resize()
        }
    }

    private func moveCompletion(by delta: Int) {
        let count = completionMatches.count
        guard count > 0 else { return }
        completionCursor = ((completionCursor + delta) % count + count) % count
        completion.renderCompletion(.naming(matches: completionMatches), cursor: completionCursor)
        resize()
    }

    private func acceptCompletion() {
        guard completionMatches.indices.contains(completionCursor) else { return }
        accept(completionMatches[completionCursor].command)
    }

    /// A command that takes arguments leaves the caret past its trailing space, ready for them;
    /// one that takes none is written whole, and the list gives way rather than offering the word
    /// it just wrote.
    private func accept(_ command: AgentCommand) {
        SlashRecents.record(command.name)
        let text = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
        editor.setText(text, caretAtEnd: true)
        editor.vim.reset(to: text, cursor: text.count, mode: .insert)
        editor.refreshMode()
        editor.focus()
    }

    private func dismissCompletion() {
        completionMatches = []
        completionCursor = 0
        guard completion.isShowing else { return }
        completion.hide()
        resize()
    }

    /// The powers are visibly on before the question is sent: the aim's own effort, or the word
    /// typed into the draft, lights the same rainbow the chat's box wears.
    private func refreshAura() {
        editor.setAura(
            editor.auraActive(
                effort: QuickAskDefaults.effort(forProfileID: targetServer.id), inFlight: false))
    }

    /// The clipboard, whatever it is holding: a screenshot or a file copied in the Finder becomes
    /// a chip, and words are handed back to AppKit so undo and selection stay the system's.
    private func takeClipboard() -> Bool {
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
        if let notice = plan.notices.first { setStatus(notice) }
        guard plan.text == nil else { return false }
        guard !plan.attachments.isEmpty else { return !plan.notices.isEmpty }
        attachments.append(contentsOf: plan.attachments)
        syncAttachments()
        return true
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
        pickStarter(at: digit - 1)
        return true
    }

    private var aimedServerID: String?
    private var modelMenu: NSMenu?

    private var targetServer: ConnectionProfile {
        servers.first { $0.id == aimedServerID } ?? servers[0]
    }

    @objc private func serverChipPicked(_ sender: NSButton) {
        popServerMenu()
    }

    /// Where the question goes, as a menu rather than a blind cycle: every server named with the
    /// agent that would answer, the aimed one ticked, the address a tooltip away.
    private func popServerMenu() {
        let menu = NSMenu()
        for server in servers {
            let item = NSMenuItem(
                title: "\(server.name) · \(ServerLabel.agent(server.backend))",
                action: #selector(serverMenuItemPicked(_:)), keyEquivalent: "")
            item.state = server.id == aimedServerID ? .on : .off
            item.representedObject = server.id
            item.toolTip = server.baseURL.absoluteString
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil, at: NSPoint(x: 0, y: serverChip.bounds.maxY + 4),
            in: serverChip)
    }

    @objc private func serverMenuItemPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        guard id != aimedServerID else { return }
        aimedServerID = id
        serverChanged()
    }

    @objc private func serverChanged() {
        refreshAim()
        retargetDraft()
        refreshAim()
        refreshCommands()
    }

    private var draftScope: DraftScope { .quickAsk(profileID: targetServer.id) }

    /// A question survives the surface it was being written in: the panel is opened by a chord
    /// pressed in the middle of something else and closed by the same reflex, so what is in the
    /// field is filed as it is typed and handed back the next time this machine is aimed at.
    private func stashDraft() {
        guard !asking else { return }
        DraftStore.record(editor.text, for: draftScope)
    }

    private func restoreDraft() {
        draftProfileID = targetServer.id
        let draft = DraftStore.text(for: draftScope)
        guard !draft.isEmpty else { return }
        editor.setText(draft, caretAtEnd: true)
        refreshStarterVisibility()
    }

    /// Moving the question to another machine leaves the words filed under the one being left and
    /// hands back whatever was last written for the one arrived at — a draft belongs to the
    /// machine it was written for, the way a chat's belongs to the chat.
    private func retargetDraft() {
        guard let previous = draftProfileID, previous != targetServer.id else {
            draftProfileID = targetServer.id
            return
        }
        DraftStore.record(editor.text, for: .quickAsk(profileID: previous))
        draftProfileID = targetServer.id
        editor.setText(DraftStore.text(for: draftScope), caretAtEnd: true)
        refreshStarterVisibility()
    }

    /// The whole catalog, from the fleet's own cache — a machine's models are a fact about that
    /// machine, so the chooser can name what another server runs without this ask ever having
    /// talked to it, and a pick landing there re-aims the question rather than moving a chat. The
    /// sheet is watched, not snapshot: a server that is restarting reads as restarting rather than
    /// as a machine with no models, and the list lands on the open sheet when it is back.
    @objc private func chooseModel() {
        popModelMenu()
    }

    /// What will answer, at menu length: the server's own default, your stars, what you reached
    /// for, the local floor — the same list the composer's pill shows — and the road to the full
    /// directory when none of the shortlist is the answer.
    private func popModelMenu() {
        let server = targetServer
        let selected = QuickAskDefaults.model(forProfileID: server.id)
        let menu = NSMenu()
        let auto = NSMenuItem(
            title: Localized.text("Server default"), action: #selector(modelMenuItemPicked(_:)),
            keyEquivalent: "")
        auto.state = selected == nil ? .on : .off
        auto.target = self
        menu.addItem(auto)
        menu.addItem(.separator())
        let sources = chooserSources(for: server)
        for candidate in ModelChooser.shortlist(sources: sources, selected: selected, limit: 8) {
            let star = candidate.offers.contains { ModelFavoritesStore.isFavorite($0.selection) }
                ? "★ " : ""
            let item = NSMenuItem(
                title: (selected == candidate.selection ? "✓ " : "") + star + candidate.name,
                action: #selector(modelMenuItemPicked(_:)), keyEquivalent: "")
            item.state = candidate.isElsewhere ? .off : (selected == candidate.selection ? .on : .off)
            item.toolTip =
                candidate.isElsewhere
                ? Localized.text("on %@ — the ask moves there", candidate.serverName)
                : candidate.primary.providerName
            item.representedObject = PickBox(
                pick: ModelPick(
                    profileID: candidate.profileID, selection: candidate.selection,
                    isElsewhere: candidate.isElsewhere,
                    serverName: candidate.serverName, modelName: candidate.name))
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(
            title: Localized.text("All models…"), action: #selector(openModelDirectoryNow),
            keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modelButton.bounds.maxY + 4), in: modelButton)
    }

    @objc private func modelMenuItemPicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? PickBox else { return }
        QuickAskDefaults.adopt(box.pick)
        aim(at: box.pick.profileID)
        refreshAim()
        editor.focus()
    }

    /// The catalog is asked once per aim, in the background: a server that has never been
    /// opened has an empty cache, and a model chip hidden for that read as "this server has
    /// no models" when the truth was only that nobody had asked yet.
    private func watchCatalog() {
        catalogWatch?.cancel()
        catalogWatch = Task { [weak self] in
            guard let self else { return }
            let server = self.targetServer
            guard let backend = await ServerDirectory.shared.backend(for: server) else { return }
            for await reading in ModelCatalogWatch.readings(
                profileID: server.id, backend: backend)
            {
                guard self.targetServer.id == server.id else { return }
                ModelCatalogStore.store(reading.models, for: server.id)
                await MainActor.run { self.refreshAim() }
            }
        }
    }

    @objc private func openModelDirectoryNow() {
        let server = targetServer
        catalogWatch?.cancel()
        catalogWatch = Task { [weak self] in
            guard let self else { return }
            guard let backend = ServerDirectory.shared.backend(for: server) else { return }
            for await reading in ModelCatalogWatch.readings(profileID: server.id, backend: backend)
            {
                guard self.targetServer.id == server.id else { return }
                self.modelSheet?.update(
                    sources: self.chooserSources(
                        for: server, models: reading.models, reachable: reading.reachable))
                self.refreshAim()
            }
        }
        modelSheet = ModelChooserSheet.present(
            on: self, sources: chooserSources(for: server),
            selected: QuickAskDefaults.model(forProfileID: server.id)
        ) { [weak self] pick in
            QuickAskDefaults.adopt(pick)
            self?.modelSheet = nil
            self?.aim(at: pick.profileID)
            self?.refreshAim()
        }
    }

    private func chooserSources(
        for server: ConnectionProfile, models: [ModelInfo]? = nil, reachable: Bool? = nil
    ) -> [ModelSource] {
        ModelChooserSheet.fleetSources(
            profiles: servers, current: server.id,
            currentModels: models ?? ModelCatalogStore.cached(server.id), backend: server.backend,
            allowsServerDefault: server.backend == .claudeCode, reachable: reachable)
    }

    private func aim(at profileID: String) {
        aimedServerID = profileID
        retargetDraft()
        refreshCommands()
    }

    /// How hard the machine is asked to think, which is half of what a question costs and the
    /// other half of the aim: the levels are the picked model's own where the catalog names them
    /// and the agent's otherwise, and a pick is the quick ask's own memory on that server rather
    /// than the machine's — the same bargain the model button strikes.
    private func effortOptions() -> [String] {
        let server = targetServer
        let agent = ServerDirectory.shared.backend(for: server)?.reasoningEffortOptions ?? []
        return ModelEffort.options(
            models: ModelCatalogStore.cached(server.id),
            selection: QuickAskDefaults.model(forProfileID: server.id), agentOptions: agent)
    }

    private func refreshEffort() {
        let server = targetServer
        let options = effortOptions()
        dropUnofferedEffort(on: server.id, options: options)
        effortButton.isHidden = !ModelEffort.isOffered(options: options)
        effortButton.removeAllItems()
        effortButton.addItem(withTitle: Localized.text("Server default"))
        for option in options {
            let isPower = option == Ultracode.effortLevel
            effortButton.addItem(withTitle: isPower ? "\(option) ✦" : option)
            if isPower { effortButton.lastItem?.toolTip = Ultracode.menuSubtitle }
        }
        let chosen = QuickAskDefaults.effort(forProfileID: server.id)
        let index = chosen.flatMap { options.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        effortButton.selectItem(at: min(index, effortButton.numberOfItems - 1))
    }

    /// A model whose levels are its own can make the level already picked unrunnable. The aim
    /// then hands the choice back to the machine rather than keeping a word the question could
    /// not be asked with — a control may never name a level the send would not carry.
    private func dropUnofferedEffort(on profileID: String, options: [String]) {
        guard let chosen = QuickAskDefaults.effort(forProfileID: profileID), !chosen.isEmpty,
            !options.contains(chosen)
        else { return }
        QuickAskDefaults.recordEffort(nil, forProfileID: profileID)
    }

    @objc private func effortChanged() {
        let options = effortOptions()
        let index = effortButton.indexOfSelectedItem - 1
        let level = options.indices.contains(index) ? options[index] : nil
        QuickAskDefaults.recordEffort(level, forProfileID: targetServer.id)
        refreshAim()
        editor.focus()
    }

    /// What the aim can be handed, re-read whenever either half of it moves. A picture already in
    /// the strip that the new model cannot read is dropped out loud rather than carried to a send
    /// the other machine would refuse.
    private var abilities: ModelAbilities {
        let server = targetServer
        let selection = QuickAskDefaults.model(forProfileID: server.id)
        let capabilities = selection.flatMap { pick in
            ModelCatalogStore.cached(server.id).first {
                $0.providerID == pick.providerID && $0.id == pick.modelID
            }?.capabilities
        }
        return ModelAbilities.resolve(supportsAttachments: true, model: capabilities)
    }

    /// The button names what the question will actually run on, and the line under it says how
    /// to send — with one server that line also names the machine, which the hidden popup no
    /// longer can.
    private func refreshAim() {
        let server = targetServer
        serverChip.title = server.name + " · " + ServerLabel.agent(server.backend)
        let picked = QuickAskDefaults.model(forProfileID: server.id)
        let starred = picked.map(ModelFavoritesStore.isFavorite) ?? false
        modelButton.title =
            (starred ? "★ " : "")
            + (picked == nil && ModelCatalogStore.cached(server.id).isEmpty
                ? Localized.text("Model…")
                : ModelBadge.label(model: picked, effort: nil))
        modelButton.isHidden = false
        watchCatalog()
        refreshEffort()
        let able = abilities
        attachButton.isHidden = !able.attachments
        refreshAura()
        let kept = attachments.filter { able.accepts(mime: $0.mime) }
        let dropped = attachments.count - kept.count
        attachments = kept
        syncAttachments()
        renderStarters()
        guard !asking else { return }
        setStatus(
            dropped > 0
                ? QuickAskComposition.droppedNotice(count: dropped)
                : (servers.count < 2
                    ? Localized.text("Asks %@ — enter sends, esc closes", server.name)
                    : Localized.text("Enter sends, esc closes")))
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
            row.font = MacTheme.Ramp.font(.panelFootnote)
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
            row.font = MacTheme.Ramp.font(.panelFootnote)
            starters.addArrangedSubview(row)
        }
    }

    /// The name of a group, set in the ramp's own answer for one — bold and tracked, against the
    /// plain footnote its rows are set in, so the panel reads as two named groups rather than one
    /// column of small grey text.
    private func sectionLabel(_ text: String) -> NSTextField {
        NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: text,
                attributes: MacTheme.Ramp.attributes(
                    .sectionLabel, color: MacTheme.Color.secondaryLabel)))
    }

    private func refreshStarterVisibility() {
        let empty =
            editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
        let hidden = !(empty && !asking)
        guard starters.isHidden != hidden else { return }
        starters.isHidden = hidden
        resize()
    }

    /// The box measures its own height one runloop pass after the keystroke that changed it, so
    /// the size read here is still the previous line count. The panel takes that size now — the
    /// first one is what places the window as it opens — and takes it again once the editor has
    /// answered, so a question that wraps onto a second line is not one keystroke behind the
    /// window holding it.
    private func resize() {
        guard let content = contentView else { return }
        setContentSize(content.fittingSize)
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            guard let content = self.contentView else { return }
            self.setContentSize(content.fittingSize)
        }
    }

    /// Everything the panel says about itself goes through here, because the sentence is sometimes
    /// a whole failure — what the other machine refused and why — and the panel has to grow to
    /// hold it rather than cut it off at the tail.
    private func setStatus(_ text: String) {
        status.stringValue = text
        resize()
    }

    /// A starter is the first half of a sentence, never a question the app asked on somebody's
    /// behalf: the words land in the field with the caret at their end, and a row that needs a
    /// file opens the chooser for it in the same gesture.
    private func pickStarter(at index: Int) {
        guard !asking, offered.indices.contains(index) else { return }
        let starter = offered[index]
        QuickAskStarterRecents.record(starter.id)
        if editor.text.isEmpty { editor.setText(starter.prompt, caretAtEnd: true) }
        editor.focus()
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
                    setStatus(Localized.text("This model can't read %@", attachment.name))
                    continue
                }
                attachments.append(attachment)
            case .failure(let refusal):
                setStatus(refusal.message)
            }
        }
        syncAttachments()
    }

    private func pasteImageAttachment() {
        guard abilities.vision else { return }
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .png) ?? pngFromTIFF(pasteboard) else {
            setStatus(Localized.text("The clipboard holds no picture."))
            return
        }
        addPastedImage(data)
    }

    private func addPastedImage(_ data: Data) {
        guard abilities.vision else { return }
        guard data.count <= AttachmentIntake.byteCap else {
            setStatus(
                Localized.text(
                    "That picture is %@ — the cap is 8 MB", AttachmentIntake.sizeText(data.count)))
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
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard QuickAskComposition.canSend(text: text, attachments: attachments.count) else { return }
        let server = targetServer
        let send = QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: ServerDirectory.shared.backend(for: server)?
                .resolvesCommandsFromPromptText == true)
        asking = true
        dismissCompletion()
        editor.isEditable = false
        serverChip.isEnabled = false
        modelButton.isEnabled = false
        effortButton.isEnabled = false
        attachButton.isEnabled = false
        refreshStarterVisibility()
        setStatus(QuickAskComposition.waitingTitle(server: server.name))
        onAsk(server.id, send, attachments) { [weak self] failure in
            guard let self else { return }
            guard let failure else {
                QuickAskDefaults.record(profileID: server.id)
                DraftStore.clear(.quickAsk(profileID: server.id))
                self.close()
                return
            }
            self.asking = false
            self.editor.isEditable = true
            self.serverChip.isEnabled = true
            self.modelButton.isEnabled = true
            self.effortButton.isEnabled = true
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
