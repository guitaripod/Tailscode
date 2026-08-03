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
    var onRunCommand: ((AgentCommand, String?) -> Void)?
    var onCompactRequested: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onToast: ((String) -> Void)?
    /// The attachments-in-waiting changed — the status band counts them.
    var onAttachmentsChanged: (() -> Void)?

    let completion = CompletionPopover()

    var attachmentCount: Int { attachments.count }

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let fieldContainer = NSView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton()
    private let chips = AttachmentChips()
    private let pills = PillsRow()
    private let vim = VimEngine()
    private var fieldHeight: NSLayoutConstraint?
    private var isMeasuring = false

    private var entry: SessionEntry?
    private var backend: (any CodingAgentBackend)?
    private var lastState: ConversationState?
    private var running = false
    private var attachments: [PendingAttachment] = []
    private var pastedImageCount = 0
    private var models: [ModelInfo] = []
    private var commands: [AgentCommand] = []
    private var modelsByProfile: [String: [ModelInfo]] = [:]
    private var commandsBySession: [String: [AgentCommand]] = [:]
    private var chosenModel: ModelSelection?
    private var chosenEffort: String?
    private var completionMatches: [AgentCommand] = []
    private var completionCursor = 0

    static var sendOnReturn: Bool {
        UserDefaults.standard.object(forKey: "tailscode.sendOnReturn") as? Bool ?? true
    }

    static var vimPreferred: Bool {
        UserDefaults.standard.bool(forKey: "tailscode.vimComposer")
    }

    private static var composerLines: Int {
        let stored = UserDefaults.standard.integer(forKey: "tailscode.composerLines")
        return stored == 0 ? 12 : min(20, max(1, stored))
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configureEditor()
        configureLayout()
        wirePills()
        registerForDraggedTypes([.fileURL, .png, .tiff])
        updateVimUI()
        scheduleMeasure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var editorHasFocus: Bool {
        window?.firstResponder === textView
    }

    var vimEnabled: Bool { Self.vimPreferred }
    var vimMode: VimMode { vim.mode }
    var vimAwaitsMore: Bool { vim.awaitsMore }
    var completionVisible: Bool { completion.isShowing }

    func takeFocus() {
        window?.makeFirstResponder(textView)
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
        chosenModel = ModelPreferenceStore.model(forKey: key)
        chosenEffort = EffortPreferenceStore.effort(forKey: key)
        models = modelsByProfile[entry.profileID] ?? []
        commands = commandsBySession[entry.session.id] ?? []
        dismissCompletion()
        sendButton.title = Localized.text("Send")
        pills.setStopShown(false)
        restoreDraft(for: entry.session.id)
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
    }

    /// The send path: trim, keep nothing the draft store would resurrect, let a typed slash
    /// command go where the palette would send it, and only then hand the prompt out. The
    /// attachments ride only with a real prompt — a slash command consumes none of them.
    func sendNow() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = attachments
        guard !text.isEmpty || !outgoing.isEmpty else { return }
        setEditorText("", caretAtEnd: true)
        if let entry {
            UserDefaults.standard.removeObject(forKey: "tailscode.draft.\(entry.session.id)")
        }
        vim.reset(to: "", cursor: 0, mode: .insert)
        updateVimUI()
        dismissCompletion()
        if handleSlashCommand(text) { return }
        attachments = []
        syncChips()
        onSubmitPrompt?(text, chosenModel, chosenEffort, outgoing.map(\.prompt))
    }

    func insertText(_ text: String) {
        setEditorText(textView.string + text, caretAtEnd: true)
        takeFocus()
    }

    func openCommandPalette() {
        guard !isHidden else { return }
        pills.popUpCommandMenu()
    }

    func stashDraft() {
        guard let entry else { return }
        let key = "tailscode.draft.\(entry.session.id)"
        let text = textView.string
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(text, forKey: key)
        }
    }

    func applyVim(_ key: VimKey) {
        let outcome = vim.handle(key, text: textView.string, cursor: characterCursor())
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
        let range = textView.selectedRange()
        guard range.length > 0 else { return false }
        RowKit.copyToClipboard((textView.string as NSString).substring(with: range))
        return true
    }

    func moveCompletion(by delta: Int) {
        let count = completionMatches.count
        guard count > 0 else { return }
        completionCursor = ((completionCursor + delta) % count + count) % count
        completion.render(matches: completionMatches, cursor: completionCursor)
    }

    func acceptCompletion() {
        acceptCompletion(at: completionCursor)
    }

    func dismissCompletion() {
        completionMatches = []
        completionCursor = 0
        completion.hide()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateVimUI()
    }

    override func layout() {
        super.layout()
        scheduleMeasure()
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
        textView.isRichText = false
        textView.font = MacTheme.Font.mono(13)
        textView.textContainerInset = NSSize(width: MacTheme.Spacing.s, height: MacTheme.Spacing.s)
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.stringValue = Localized.text("Message… (/ for commands)")
        placeholderLabel.font = MacTheme.Font.mono(13)
        placeholderLabel.textColor = MacTheme.Color.tertiaryLabel
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        fieldContainer.wantsLayer = true
        fieldContainer.layer?.cornerRadius = MacTheme.Radius.control
        fieldContainer.layer?.borderWidth = 1
        fieldContainer.layer?.borderColor = MacTheme.Color.separator.cgColor
        fieldContainer.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.addSubview(scrollView)
        fieldContainer.addSubview(placeholderLabel)

        sendButton.title = Localized.text("Send")
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureLayout() {
        let height = fieldContainer.heightAnchor.constraint(equalToConstant: 34)
        fieldHeight = height

        let editorRow = NSStackView(views: [fieldContainer, sendButton])
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
            height,
            scrollView.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: fieldContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: fieldContainer.leadingAnchor, constant: MacTheme.Spacing.s + 5),
            placeholderLabel.topAnchor.constraint(
                equalTo: fieldContainer.topAnchor, constant: MacTheme.Spacing.s),
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
        completion.onPick = { [weak self] index in
            self?.acceptCompletion(at: index)
        }
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
        pills.setAttachShown(attachmentsSupported)
        updateVimUI()
    }

    /// What the chat is actually being answered by, which is not always what the session record
    /// says: a `/model` typed into the CLI changes the model for every later turn without the
    /// server's stored session ever hearing about it. The transcript is the authority — the last
    /// assistant message names the model that wrote it — and the session record is the fallback
    /// for a chat that has no answer in it yet.
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
        let active = chosenModel?.modelID ?? observedModelID() ?? entry?.session.model
        if let active, let variants = models.first(where: { $0.id == active })?.variants,
            !variants.isEmpty
        {
            return variants
        }
        return backend?.reasoningEffortOptions ?? []
    }

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
        for model in models {
            let selection = model.selection
            rows.append(
                PillsRow.MenuRow(
                    model.name, subtitle: model.providerID, checked: chosenModel == selection
                ) { [weak self] in
                    self?.setModel(selection)
                })
        }
        return rows
    }

    private func setModel(_ selection: ModelSelection?) {
        chosenModel = selection
        if let entry {
            ModelPreferenceStore.setModel(selection, forKey: Self.preferenceKey(entry))
        }
        if let selection { RecentModelsStore.record(selection) }
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
            rows.append(
                PillsRow.MenuRow(option, checked: chosenEffort == option) { [weak self] in
                    self?.setEffort(option)
                })
        }
        return rows
    }

    private func setEffort(_ level: String?) {
        chosenEffort = level
        if let entry {
            EffortPreferenceStore.setEffort(level, forKey: Self.preferenceKey(entry))
        }
        refreshPills()
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

    /// A typed slash command goes where the palette would send it: `/compact` to its preflight,
    /// a known server command to the command route when the server wants one, and anything
    /// unknown out as plain text — the server is the authority on its own grammar.
    private func handleSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let name = String(text.dropFirst().prefix(while: { !$0.isWhitespace }))
        let arguments = String(text.dropFirst(1 + name.count)).trimmingCharacters(
            in: .whitespaces)
        if name == "compact" {
            onCompactRequested?(arguments)
            return true
        }
        guard let command = commands.first(where: { $0.name == name }) else { return false }
        if backend?.resolvesCommandsFromPromptText == true { return false }
        onRunCommand?(command, arguments.isEmpty ? nil : arguments)
        return true
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
        guard vimEnabled else {
            textView.insertionPointColor = .textInsertionPointColor
            pills.setVim(nil)
            fieldContainer.layer?.borderColor = MacTheme.Color.separator.cgColor
            return
        }
        textView.insertionPointColor = vim.mode == .insert ? .textInsertionPointColor : .clear
        pills.setVim(vim.mode)
        let border: NSColor =
            switch vim.mode {
            case .insert: MacTheme.Color.separator
            case .normal: MacTheme.Color.accent
            case .visual, .visualLine: MacTheme.Color.warning
            }
        fieldContainer.layer?.borderColor = border.cgColor
    }

    /// The engine's own cursor is the truth while a visual selection is painted — the text
    /// view's insertion point sits at the selection's edge, which is not where vim is standing.
    private func characterCursor() -> Int {
        if vimEnabled, vim.mode == .visual || vim.mode == .visualLine {
            return vim.document.cursor
        }
        let text = textView.string
        return Self.characterOffset(fromUTF16: textView.selectedRange().location, in: text)
    }

    private func writeEditor(_ document: VimDocument, selection: Range<Int>?) {
        let text = document.text
        if textView.string != text {
            textView.string = text
        }
        if let selection {
            let lower = Self.utf16Offset(fromCharacter: selection.lowerBound, in: text)
            let upper = Self.utf16Offset(fromCharacter: selection.upperBound, in: text)
            textView.setSelectedRange(NSRange(location: lower, length: upper - lower))
        } else {
            let caret = Self.utf16Offset(fromCharacter: document.cursor, in: text)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
        textView.scrollRangeToVisible(textView.selectedRange())
        editorContentChanged()
    }

    private static func characterOffset(fromUTF16 location: Int, in text: String) -> Int {
        guard
            let range = Range(NSRange(location: location, length: 0), in: text)
        else { return text.count }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    private static func utf16Offset(fromCharacter offset: Int, in text: String) -> Int {
        let index = text.index(text.startIndex, offsetBy: min(max(0, offset), text.count))
        return NSRange(index..<index, in: text).location
    }

    private func setEditorText(_ text: String, caretAtEnd: Bool) {
        textView.string = text
        if caretAtEnd {
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        editorContentChanged()
    }

    private func editorContentChanged() {
        placeholderLabel.isHidden = !textView.string.isEmpty
        scheduleMeasure()
        updateSlashCompletion()
    }

    /// The prompt box is as tall as what is in it: one line when empty, taller as the text wraps
    /// or a paragraph is pasted, and it stops growing at `tailscode.composerLines` — after which
    /// it scrolls, so the transcript is never squeezed off the screen. Measured on the next
    /// runloop pass, never inline: a text view that was just emptied still reports the height it
    /// had until the next layout.
    private func scheduleMeasure() {
        guard !isMeasuring else { return }
        isMeasuring = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isMeasuring = false
            self.measureField()
        }
    }

    private func measureField() {
        guard let font = textView.font else { return }
        let line = ceil(font.ascender - font.descender + font.leading)
        let inset = textView.textContainerInset.height * 2 + 2
        let floor = line + inset
        let ceiling = line * CGFloat(Self.composerLines) + inset
        var wanted = floor
        if !textView.string.isEmpty {
            var used = floor
            if let layout = textView.textLayoutManager {
                layout.ensureLayout(for: layout.documentRange)
                used = layout.usageBoundsForTextContainer.height + inset
            } else if let manager = textView.layoutManager, let container = textView.textContainer {
                manager.ensureLayout(for: container)
                used = manager.usedRect(for: container).height + inset
            }
            wanted = max(floor, min(ceiling, ceil(used)))
        }
        guard let fieldHeight, abs(fieldHeight.constant - wanted) > 0.5 else { return }
        fieldHeight.constant = wanted
    }

    private func updateSlashCompletion() {
        let typing = !vimEnabled || vim.mode == .insert
        guard typing, let query = SlashCompletion.query(in: textView.string) else {
            dismissCompletion()
            return
        }
        var matches = SlashCompletion.matches(commands, query: query)
        if matches.count == 1, matches[0].name.lowercased() == query.lowercased() {
            matches = []
        }
        completionMatches = matches
        completionCursor = 0
        guard !matches.isEmpty else {
            dismissCompletion()
            return
        }
        completion.render(matches: matches, cursor: completionCursor)
    }

    private func acceptCompletion(at index: Int) {
        guard index < completionMatches.count else { return }
        let command = completionMatches[index]
        let text = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
        setEditorText(text, caretAtEnd: true)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        updateVimUI()
        takeFocus()
    }

    private func restoreDraft(for sessionID: String) {
        let draft = UserDefaults.standard.string(forKey: "tailscode.draft.\(sessionID)") ?? ""
        setEditorText(draft, caretAtEnd: true)
        vim.reset(to: draft, cursor: draft.count, mode: .insert)
        updateVimUI()
    }

    @objc private func sendTapped() {
        sendNow()
    }
}

extension ComposerView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        editorContentChanged()
    }
}
