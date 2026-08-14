import AppKit
import CodingAgentKit
import TailscodeCore

/// The writing surface: chips for what rides along, the prompt box that grows with the draft,
/// and the pill row that says where the words go and how. Composition lives here — vim, slash
/// completion, drafts, attachments, the model and effort choice — and execution goes out through
/// closures the conversation owner wires, so this view never touches a socket.
@MainActor
final class ComposerView: NSView {
    var onSubmitPrompt: ((String, ModelSelection?, String?, [PromptAttachment]) -> Void)?
    var onRunCommand: ((AgentCommand, String?, ModelSelection?, String?) -> Void)?
    var onCompactRequested: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onToast: ((String) -> Void)?
    /// The attachments-in-waiting changed — the status band counts them.
    var onAttachmentsChanged: (() -> Void)?

    let completion = CompletionPopover()

    var attachmentCount: Int { attachments.count }
    var availableCommands: [AgentCommand] { commands }

    private let editor = PromptEditor(placeholder: Localized.text("Message… (/ for commands)"))
    private let sendButton = NSButton()
    private let chips = AttachmentChips()
    private let pills = PillsRow()
    private var vim: VimEngine { editor.vim }

    private var entry: SessionEntry?
    private var backend: (any CodingAgentBackend)?
    private var lastState: ConversationState?
    private var running = false
    /// The text this composer last handed the draft store. Two panes can hold the same chat, and
    /// so the same scope, over two independent text views — only the one whose box has moved since
    /// it last recorded has anything left to say about that draft.
    private var lastRecordedDraft = ""
    private var attachments: [PendingAttachment] = []
    private var pastedImageCount = 0
    private var models: [ModelInfo] = []
    private var commands: [AgentCommand] = []
    private var modelsByProfile: [String: [ModelInfo]] = [:]
    private var commandsBySession: [String: [AgentCommand]] = [:]
    private var chosenModel: ModelSelection?
    private var chosenEffort: String?

    /// What a prompt sent outside the text box should travel with — the same model and effort
    /// the next Enter in this composer would use.
    var promptChoice: (model: ModelSelection?, effort: String?) { (chosenModel, chosenEffort) }
    var pickedModel: ModelSelection? { chosenModel }
    /// The used-up windows on this server's account, for marking a model spent where it is picked.
    var quotasForModels: (() -> [UsageQuota])?

    private var completionMatches: [AgentCommand] = []
    private var completionCursor = 0
    /// Opens the browsable catalog — the chat owner owns the window chrome.
    var onBrowseCommands: (() -> Void)?
    private var ultracodeInFlight = false

    /// Whether the powers are visibly on. The transcript reads it too: while the aura burns around
    /// the prompt box, the stream cascade leads with the same rainbow rather than the accent, so
    /// ultracode is legible in the writing and not only in the chrome.
    var auraActive: Bool {
        editor.auraActive(effort: chosenEffort, inFlight: ultracodeInFlight)
    }

    /// The hub hears the flip so the presence orb wears the same rainbow the moment the word is
    /// typed — a 10-second listing poll is no clock for a power turning on under the caret.
    var onAuraChanged: (() -> Void)?
    private var auraWasActive = false

    private func refreshAura() {
        let active = auraActive
        editor.setAura(active)
        if active != auraWasActive {
            auraWasActive = active
            onAuraChanged?()
        }
    }

    static var sendOnReturn: Bool { PromptEditor.sendOnReturn }

    static var vimPreferred: Bool { PromptEditor.vimPreferred }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configureEditor()
        configureLayout()
        wirePills()
        registerForDraggedTypes([.fileURL, .png, .tiff])
        updateVimUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var editorHasFocus: Bool { editor.hasFocus }

    var vimEnabled: Bool { Self.vimPreferred }
    var vimMode: VimMode { vim.mode }
    var vimAwaitsMore: Bool { vim.awaitsMore }

    func vimClaims(_ key: VimKey, plain: Bool, chordPending: Bool) -> Bool {
        vim.claims(key, plain: plain, chordPending: chordPending)
    }

    var completionVisible: Bool { completion.isShowing }

    func takeFocus() {
        editor.focus()
    }

    /// Settings changed underneath a live composer: a vim toggle must move the caret, the badge
    /// and the border to the truth right now — leaving normal mode when the engine is switched
    /// off, so no draft ends up trapped behind a hidden caret — and a new height ceiling
    /// re-measures the field.
    func applyPreferences() {
        editor.applyPreferences()
        pills.setVim(vimEnabled ? vim.mode : nil)
    }

    /// Half-typed prompts follow their conversation, not the window: switching chats stashes
    /// what was in the composer and restores whatever was stashed for the chat being opened —
    /// along with that chat's own model choice, effort, commands and attachments-in-waiting.
    func prepare(for entry: SessionEntry, backend: any CodingAgentBackend) {
        stashDraft()
        self.entry = entry
        self.backend = backend
        lastState = nil
        running = false
        attachments = []
        pastedImageCount = 0
        syncChips()
        let key = Self.preferenceKey(entry)
        chosenModel = ModelPreferenceStore.initialModel(
            sessionKey: key, contextID: entry.profileID, sessionModel: entry.session.model,
            sessionModelProviderID: entry.session.modelProviderID)
        chosenEffort = EffortPreferenceStore.initialEffort(
            sessionKey: key, contextID: entry.profileID,
            sessionEffort: entry.session.reasoningEffort)
        ultracodeInFlight = false
        refreshAura()
        models = modelsByProfile[entry.profileID] ?? []
        commands = commandsBySession[entry.session.id] ?? []
        dismissCompletion()
        sendButton.title = Localized.text("Send")
        pills.setStopShown(false)
        restoreDraft(for: entry)
        refreshPills()
        loadSessionExtras(entry: entry, backend: backend)
    }

    /// Every state the stream delivers, echoed here so the pills can tell the truth the
    /// transcript already knows: which model actually answered last, and whether a turn is
    /// running — which is when Send means Queue and Stop appears at all.
    func noteState(_ state: ConversationState) {
        lastState = state
        running = state.status == .running || state.compaction?.isRunning == true
        sendButton.title = running ? Localized.text("Queue") : Localized.text("Send")
        pills.setStopShown(running)
        refreshPills()
        if ultracodeInFlight, !running, state.hasLoadedTranscript {
            ultracodeInFlight = false
            refreshAura()
        }
        if Ultracode.turnInvoked(state), !ultracodeInFlight {
            ultracodeInFlight = true
            refreshAura()
        }
    }

    /// The send path: trim, keep nothing the draft store would resurrect, let a typed slash
    /// command go where the palette would send it, and only then hand the prompt out. The
    /// attachments ride only with a real prompt — a slash command consumes none of them.
    func sendNow() {
        let text = editor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = attachments
        guard !text.isEmpty || !outgoing.isEmpty else { return }
        setEditorText("", caretAtEnd: true)
        if let draftScope { DraftStore.clear(draftScope) }
        vim.reset(to: "", cursor: 0, mode: .insert)
        updateVimUI()
        dismissCompletion()
        if handleSlashCommand(text) { return }
        attachments = []
        syncChips()
        if Ultracode.invokes(text) || chosenEffort == Ultracode.effortLevel {
            ultracodeInFlight = true
        }
        refreshAura()
        onSubmitPrompt?(text, chosenModel, chosenEffort, outgoing.map(\.prompt))
    }

    /// Words handed to the composer from the transcript — the one action a turn that said
    /// nothing offers — sent the ordinary way. Anything half-typed keeps the box: a retry may
    /// not throw away a sentence somebody is in the middle of.
    func sendAgain(_ words: String) -> Bool {
        guard editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        setEditorText(words, caretAtEnd: true)
        sendNow()
        return true
    }

    func insertText(_ text: String) {
        setEditorText(editor.text + text, caretAtEnd: true)
        takeFocus()
    }

    func openCommandPalette() {
        guard !isHidden else { return }
        pills.popUpCommandMenu()
    }

    /// Which conversation the words in the box belong to. A draft follows its chat rather than the
    /// pane it was typed in, and the same session id on two servers is two different chats.
    private var draftScope: DraftScope? {
        entry.map { DraftScope.chat(profileID: $0.profileID, sessionID: $0.session.id) }
    }

    /// Writes what is in the box out now rather than on the store's next quiet moment: this is
    /// called where the composer is about to stop being asked — a chat switch, a closing pane, a
    /// quit — and the coalescing window is longer than any of them. Every keystroke already
    /// records, so there is a draft to contribute only when this box has moved since; a pane
    /// sitting on text another pane has since edited leaves the newer draft alone and merely
    /// puts it on disk.
    func stashDraft() {
        let text = editor.text
        if let draftScope, text != lastRecordedDraft {
            DraftStore.record(text, for: draftScope)
            lastRecordedDraft = text
        }
        DraftStore.flush()
    }

    func applyVim(_ key: VimKey) {
        let outcome = vim.handle(key, text: editor.text, cursor: editor.cursor)
        switch outcome {
        case .handled:
            writeEditor(vim.document, selection: vim.selection)
        case .passThrough:
            break
        case .send:
            sendNow()
        }
        updateVimUI()
    }

    func copySelectionToPasteboard() -> Bool {
        guard let selection = editor.selectedText() else { return false }
        RowKit.copyToClipboard(selection)
        return true
    }

    func moveCompletion(by delta: Int) {
        let count = completionMatches.count
        guard count > 0 else { return }
        completionCursor = ((completionCursor + delta) % count + count) % count
        let ranked = completionMatches.map {
            SlashMatch(command: $0, kind: .prefix, highlight: [])
        }
        completion.renderCompletion(.naming(matches: ranked), cursor: completionCursor)
    }

    func acceptCompletion() {
        if let command = completion.selectedCommand {
            accept(command)
            return
        }
        acceptCompletion(at: completionCursor)
    }

    func dismissCompletion() {
        completionMatches = []
        completionCursor = 0
        completion.hide()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        attachmentsSupported ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        attachmentsSupported ? .copy : []
    }

    /// Dropping files on the prompt box attaches them, which is how a file gets from Finder into
    /// a conversation without a dialog in between; an image dragged out of another app arrives
    /// as a pasted picture.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard attachmentsSupported else { return false }
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            attach(paths: urls.map(\.path))
            return true
        }
        if let data = pasteboard.data(forType: .png) ?? pngFromTIFF(pasteboard) {
            addPastedImage(data)
            return true
        }
        return false
    }

    private func configureEditor() {
        editor.onPaste = { [weak self] in self?.takeClipboard() ?? false }
        editor.onChanged = { [weak self] in self?.editorContentChanged() }

        sendButton.title = Localized.text("Send")
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureLayout() {
        let editorRow = NSStackView(views: [editor, sendButton])
        editorRow.orientation = .horizontal
        editorRow.alignment = .bottom
        editorRow.spacing = MacTheme.Spacing.s
        editorRow.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [chips, editorRow, pills])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = MacTheme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        chips.onRemove = { [weak self] id in
            guard let self else { return }
            self.attachments.removeAll { $0.id == id }
            self.syncChips()
        }
        completion.onPick = { [weak self] command in
            self?.accept(command)
        }
        completion.onBrowse = { [weak self] in self?.onBrowseCommands?() }
    }

    private func wirePills() {
        pills.modelRows = { [weak self] in self?.modelMenuRows() ?? [] }
        pills.effortRows = { [weak self] in self?.effortMenuRows() ?? [] }
        pills.commandRows = { [weak self] in self?.commandMenuRows() ?? [] }
        pills.attachRows = { [weak self] in self?.attachMenuRows() ?? [] }
        pills.onStop = { [weak self] in self?.onStop?() }
    }

    /// Everything worth knowing about the session besides its transcript, fetched once per open
    /// and remembered: the models the server offers and the commands it resolves. A stale answer
    /// for a chat that was left is dropped on landing.
    private func loadSessionExtras(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        let profileID = entry.profileID
        let directory = entry.session.directory
        Task { [weak self] in
            let models = (try? await backend.availableModels()) ?? []
            let commands = (try? await backend.availableCommands(directory: directory)) ?? []
            guard let self else { return }
            self.modelsByProfile[profileID] = models
            self.commandsBySession[sessionID] = commands
            guard self.entry?.session.id == sessionID else { return }
            self.models = models
            self.commands = commands
            self.refreshPills()
        }
    }

    private static func preferenceKey(_ entry: SessionEntry) -> String {
        "\(entry.profileID)/\(entry.session.id)"
    }

    private func refreshPills() {
        let destination = [
            entry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) },
            entry?.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
        ].compactMap { $0 }.joined(separator: " · ")
        pills.setDestination(destination)
        pills.setModelTitle(modelPillText())
        pills.setEffortTitle(effortPillText())
        let activeModel = activeModelID
        pills.setModelTint(
            activeModel.flatMap { ModelBadge.chip(model: $0, effort: nil) }
                .map(MacTheme.Color.modelIdentity))
        let effortWord = effortPillText()
        if effortWord.lowercased() == Ultracode.effortLevel {
            pills.setEffortTint(nil)
            pills.setEffortRainbow(effortWord)
        } else {
            pills.setEffortTint(MacTheme.Color.modelEffort(effortWord))
        }
        pills.setAttachShown(attachmentsSupported)
        updateVimUI()
    }

    /// What the chat is actually being answered by, which is not always what the session record
    /// says: a `/model` typed into the CLI changes the model for every later turn without the
    /// server's stored session ever hearing about it. The transcript is the authority — the last
    /// assistant message names the model that wrote it — and the session record is the fallback
    /// for a chat that has no answer in it yet.
    var activeModelID: String? {
        chosenModel?.modelID ?? observedModelID() ?? entry?.session.model
    }

    private func modelPillText() -> String {
        if let chosenModel { return ModelBadge.label(model: chosenModel, effort: nil) }
        if let observed = observedModelID() {
            return ModelBadge.label(
                model: ModelSelection(providerID: "server", modelID: observed), effort: nil)
        }
        if let stored = entry?.session.model {
            return ModelBadge.label(
                model: ModelSelection(providerID: "server", modelID: stored), effort: nil)
        }
        return Localized.text("model")
    }

    private func observedModelID() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let id = message.modelID, !id.isEmpty { return id }
        }
        return nil
    }

    private func effortPillText() -> String {
        if let chosenEffort { return chosenEffort }
        if let stored = entry?.session.reasoningEffort, !stored.isEmpty { return stored }
        if let observed = observedEffort() { return observed }
        guard !effortOptions().isEmpty else { return Localized.text("no effort control") }
        return Localized.text("server effort")
    }

    private func observedEffort() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let effort = message.reasoningEffort, !effort.isEmpty { return effort }
        }
        return nil
    }

    /// Effort is a property of the model on servers whose catalog says so (opencode's variants
    /// differ per model); the backend-wide list is the fallback for agents like Claude Code
    /// where every model takes the same levels.
    private func effortOptions() -> [String] {
        let active = activeModelID
        if let active, let variants = models.first(where: { $0.id == active })?.variants,
            !variants.isEmpty
        {
            return variants
        }
        return backend?.reasoningEffortOptions ?? []
    }

    /// The pill offers what this person actually works with — the shared shortlist — and hands the
    /// rest to the chooser, the only surface that can hold a catalog of two hundred and still be
    /// read. The two are the same list at two lengths.
    private func modelMenuRows() -> [PillsRow.MenuRow] {
        guard !models.isEmpty else {
            return [PillsRow.MenuRow(Localized.text("This server lists no models"))]
        }
        var rows = [
            PillsRow.MenuRow(
                Localized.text("Server default"), checked: chosenModel == nil
            ) { [weak self] in
                self?.setModel(nil)
            }
        ]
        let quotas = quotasForModels?() ?? []
        for candidate in ModelChooser.shortlist(models, selected: chosenModel) {
            let selection = candidate.selection
            let providers = candidate.providerNames.joined(separator: " · ")
            let wall = ModelChooser.wall(for: candidate, quotas: quotas)
            rows.append(
                PillsRow.MenuRow(
                    candidate.name,
                    subtitle: wall.map { "\(QuotaSurface.rowNote($0)) · \(providers)" }
                        ?? providers,
                    checked: candidate.carries(chosenModel)
                ) { [weak self] in
                    self?.setModel(selection)
                })
        }
        rows.append(
            PillsRow.MenuRow(
                Localized.text("All models…"),
                subtitle: ModelChooser(models: models, selected: chosenModel, quotas: quotas)
                    .summary
            ) { [weak self] in
                self?.openModelChooser()
            })
        return rows
    }

    private func openModelChooser() {
        guard let host = window else { return }
        ModelChooserSheet.present(
            on: host, models: models, selected: chosenModel, allowsServerDefault: true,
            quotas: quotasForModels?() ?? []
        ) { [weak self] selection in
            self?.setModel(selection)
        }
    }

    private func setModel(_ selection: ModelSelection?) {
        chosenModel = selection
        if let entry {
            ModelPreferenceStore.recordPick(
                selection, sessionKey: Self.preferenceKey(entry), contextID: entry.profileID)
        }
        refreshPills()
    }

    private func effortMenuRows() -> [PillsRow.MenuRow] {
        let options = effortOptions()
        guard !options.isEmpty else {
            return [PillsRow.MenuRow(Localized.text("This agent has no effort control"))]
        }
        var rows = [
            PillsRow.MenuRow(
                Localized.text("Server default"), checked: chosenEffort == nil
            ) { [weak self] in
                self?.setEffort(nil)
            }
        ]
        for option in options {
            let isPower = option == Ultracode.effortLevel
            rows.append(
                PillsRow.MenuRow(
                    isPower ? "\(option) ✦" : option,
                    subtitle: isPower ? Ultracode.menuSubtitle : nil,
                    checked: chosenEffort == option
                ) { [weak self] in
                    self?.setEffort(option)
                })
        }
        return rows
    }

    private func setEffort(_ level: String?) {
        chosenEffort = level
        if let entry {
            EffortPreferenceStore.recordPick(
                level, sessionKey: Self.preferenceKey(entry), contextID: entry.profileID)
        }
        refreshPills()
        refreshAura()
    }

    /// On the server first — what this machine will actually resolve — then what the app itself
    /// can do. Picking one drops it into the composer so arguments can follow; `/compact` keeps
    /// its preflight.
    private func commandMenuRows() -> [PillsRow.MenuRow] {
        var rows = [
            PillsRow.MenuRow(
                "/compact",
                subtitle: Localized.text("Trade the transcript for a summary — with a preflight")
            ) { [weak self] in
                self?.onCompactRequested?("")
            },
            PillsRow.MenuRow(
                "/goal", subtitle: Localized.text("Set a standing goal the agent pursues")
            ) { [weak self] in
                self?.insertText("/goal ")
            },
        ]
        for command in commands where command.name != "compact" && command.name != "goal" {
            let insertion = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
            rows.append(
                PillsRow.MenuRow(
                    "/\(command.name)",
                    subtitle: command.details.isEmpty ? command.source.rawValue : command.details
                ) { [weak self] in
                    self?.insertText(insertion)
                })
        }
        return rows
    }

    /// A typed slash command goes where the completion list would send it. The decision is the
    /// shared one so all three clients answer a typed command the same way; false means the words
    /// go out as an ordinary prompt.
    private func handleSlashCommand(_ text: String) -> Bool {
        switch SlashDispatch.decide(
            text: text, commands: commands,
            supportsCompaction: backend?.capabilities.supportsCompaction != false,
            resolvesFromPromptText: backend?.resolvesCommandsFromPromptText == true)
        {
        case .compactPreflight(let instruction):
            onCompactRequested?(instruction)
            return true
        case .run(let command, let arguments):
            SlashRecents.record(command.name)
            onRunCommand?(command, arguments, chosenModel, chosenEffort)
            return true
        case .plainText:
            return false
        }
    }

    private var attachmentsSupported: Bool {
        backend?.capabilities.supportsAttachments != false
    }

    private func attachMenuRows() -> [PillsRow.MenuRow] {
        guard attachmentsSupported else {
            return [PillsRow.MenuRow(Localized.text("This server does not take attachments"))]
        }
        return [
            PillsRow.MenuRow(
                Localized.text("Attach files…"), subtitle: Localized.text("Up to 8 MB each")
            ) { [weak self] in
                self?.pickAttachments()
            },
            PillsRow.MenuRow(
                Localized.text("Paste image"),
                subtitle: Localized.text("From the clipboard, as PNG")
            ) { [weak self] in
                self?.pasteImageAttachment()
            },
        ]
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
    private func attach(paths: [String]) {
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

    private func syncChips() {
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
            for: offer, abilities: pasteAbilities, alreadyNamed: pastedImageCount)
        pastedImageCount = plan.named
        if let notice = plan.notices.first { onToast?(notice) }
        guard plan.text == nil else { return false }
        guard !plan.attachments.isEmpty else { return !plan.notices.isEmpty }
        attachments.append(contentsOf: plan.attachments)
        syncChips()
        return true
    }

    private var pasteAbilities: QuickAskAbilities {
        QuickAskAbilities.resolve(
            supportsAttachments: attachmentsSupported,
            model: chosenModel.flatMap { pick in
                models.first { $0.providerID == pick.providerID && $0.id == pick.modelID }?
                    .capabilities
            })
    }

    private func addPastedImage(_ data: Data) {
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

    private func pngFromTIFF(_ pasteboard: NSPasteboard) -> Data? {
        guard let tiff = pasteboard.data(forType: .tiff),
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Alongside the badge, the caret itself says which mode this is: it blinks only in insert.
    /// In normal and visual it is hidden — the letters belong to commands, and a blinking beam
    /// would promise typing the composer will not do. The field's border carries the mode too.
    private func updateVimUI() {
        editor.refreshMode()
        pills.setVim(vimEnabled ? vim.mode : nil)
    }

    private func writeEditor(_ document: VimDocument, selection: Range<Int>?) {
        editor.write(document, selection: selection)
    }

    private func setEditorText(_ text: String, caretAtEnd: Bool) {
        editor.setText(text, caretAtEnd: caretAtEnd)
    }

    /// Every path that changes what is in the box lands here — a keystroke, a vim edit, a
    /// completion accepted — so it is also where the draft is recorded. Recording is a dictionary
    /// write and the store coalesces the file write itself, so nothing here is throttled.
    private func editorContentChanged() {
        if let draftScope {
            let text = editor.text
            DraftStore.record(text, for: draftScope)
            lastRecordedDraft = text
        }
        updateSlashCompletion()
        refreshAura()
    }

    private func updateSlashCompletion() {
        let typing = !vimEnabled || vim.mode == .insert
        guard typing else {
            dismissCompletion()
            return
        }
        completion.onPick = { [weak self] command in self?.accept(command) }
        completion.onBrowse = { [weak self] in self?.onBrowseCommands?() }
        let presentation = SlashPresentation.of(
            text: editor.text, commands: commands,
            recents: SlashRecents.surviving(in: commands))
        switch presentation {
        case .hidden:
            dismissCompletion()
        case .naming(let matches):
            completionMatches = matches.map(\.command)
            completionCursor = min(completionCursor, max(0, matches.count - 1))
            completion.renderCompletion(presentation, cursor: completionCursor)
        case .arguments, .noMatch:
            completionMatches = []
            completionCursor = 0
            completion.renderCompletion(presentation)
        }
    }

    private func acceptCompletion(at index: Int) {
        guard index < completionMatches.count else { return }
        accept(completionMatches[index])
    }

    private func accept(_ command: AgentCommand) {
        SlashRecents.record(command.name)
        let text = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
        setEditorText(text, caretAtEnd: true)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        updateVimUI()
        takeFocus()
        if !command.takesArguments {
            updateSlashCompletion()
        }
    }

    /// A pick from the browsable catalog — same landing as accepting a completion row.
    func acceptCatalogCommand(_ command: AgentCommand) {
        accept(command)
    }

    private func restoreDraft(for entry: SessionEntry) {
        let draft = DraftStore.text(
            for: .chat(profileID: entry.profileID, sessionID: entry.session.id))
        setEditorText(draft, caretAtEnd: true)
        lastRecordedDraft = draft
        vim.reset(to: draft, cursor: draft.count, mode: .insert)
        updateVimUI()
    }

    @objc private func sendTapped() {
        sendNow()
    }
}
