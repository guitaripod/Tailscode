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
    var onDesignRequested: ((String) -> Void)?
    /// `/delegate`, with the words after it as the goal: the pane hands the task to its machine's
    /// dispatcher.
    var onDelegateRequested: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onCall: (() -> Void)?
    var onLane: ((QuickAskLane) -> Void)?
    /// ↑ from an empty box: the pane takes its last waiting message back for rewriting, and says
    /// whether it did — the key belongs to the text view otherwise.
    var onTakeBackQueued: (() -> Bool)?
    /// Whether the pane is holding a waiting message open in this box.
    var isEditingQueued: (() -> Bool)?
    var onToast: ((String) -> Void)?
    /// A toast that answers a control turned in quick steps — the wheel, a preset chord — where
    /// each step's sentence replaces the last rather than queueing behind it.
    var onDialToast: ((String) -> Void)?
    /// The attachments-in-waiting changed — the status band counts them.
    var onAttachmentsChanged: (() -> Void)?
    /// A model picked on another machine, move confirmed: the hub opens a new chat there.
    var onMoveToServer: ((String, CarryPlan?) -> Void)?

    let completion = CompletionPopover()

    var attachmentCount: Int { attachments.count }
    var availableCommands: [AgentCommand] {
        CommandCatalogStore.forComposer(
            commands, supportsDesign: supportsDesign, supportsDelegate: supportsDelegate)
    }

    /// Whether a design board could be read back at all. The brief is only worth spending a turn on
    /// where this server hands files over — otherwise the mocks would be written somewhere no
    /// client could ever open them.
    var supportsDesign: Bool { backend?.capabilities.supportsFileBrowsing == true }

    /// A chat whose machine is known by name can hand a task to that machine's dispatcher.
    var supportsDelegate: Bool { entry.map { !$0.host.isEmpty } ?? false }

    let editor = PromptEditor(placeholder: Localized.text("Message… (/ for commands)"))
    let sendButton = NSButton()
    let chips = AttachmentChips()
    let pills = PillsRow()
    var vim: VimEngine { editor.vim }

    var entry: SessionEntry?
    var backend: (any CodingAgentBackend)?
    var lastState: ConversationState?
    private var running = false
    /// The text this composer last handed the draft store. Two panes can hold the same chat, and
    /// so the same scope, over two independent text views — only the one whose box has moved since
    /// it last recorded has anything left to say about that draft.
    var lastRecordedDraft = ""
    var attachments: [PendingAttachment] = []
    var pastedImageCount = 0
    /// The conversation this chat was carried from, waiting to ride in its first message. It is
    /// the chat's own — kept on the shelf by the chat, so a switch to another and back finds it —
    /// and goes when the message is sent or the person says to start fresh.
    var carry: ConversationBrief? {
        didSet {
            guard carry != oldValue else { return }
            if let entry {
                CarryShelf.hold(carry, profileID: entry.profileID, sessionID: entry.session.id)
            }
            chips.set(attachments, carry: carry)
        }
    }
    var models: [ModelInfo] = []
    /// The server's catalog as this composer last heard it, for surfaces that read a model's
    /// limits rather than pick one.
    var catalog: [ModelInfo] { models }
    var commands: [AgentCommand] = []
    /// Whether the last ask for this server's models failed rather than came back empty. Saying a
    /// server lists no models is a claim about that server, and a timeout is not that claim.
    var modelsByProfile: [String: [ModelInfo]] = [:]
    var reachableByProfile: [String: Bool] = [:]
    var commandsBySession: [String: [AgentCommand]] = [:]
    var chosenModel: ModelSelection?
    var chosenEffort: String?
    var modelSheet: ModelChooserSheet?
    var dialPopover: ModelDialPopover?
    /// When the dial last closed. A transient popover closes on the mouse-down that lands on its
    /// own pill, and the pill's action then arrives on the mouse-up — so a press meant to close
    /// the dial would reopen it, and the moment of the close is what tells the two apart.
    var dialClosedAt: Date?
    var partyPopover: PartyPopover?
    var makeRoomPopover: PartyPopover?
    var partyClosedAt: Date?
    var catalogWatch: Task<Void, Never>?

    /// What a prompt sent outside the text box should travel with — the same model and effort
    /// the next Enter in this composer would use.
    var promptChoice: (model: ModelSelection?, effort: String?) {
        (chosenModel, ModelEffort.surviving(chosenEffort, options: effortOptions()))
    }
    var pickedModel: ModelSelection? { chosenModel }
    /// The model a send from here would run on, with the door it runs through — the pick, else
    /// the transcript's own record, else the session's, resolved against the catalog before the
    /// door is given up. Every quota reading bills against this.
    var activeSelection: ModelSelection? {
        ActiveModel.selection(
            picked: chosenModel, messages: lastState?.messages ?? [], session: entry?.session,
            catalog: models)
    }
    /// The model or effort in the composer changed by a pick rather than by the transcript.
    var onModelChanged: (() -> Void)?
    /// The effort a send from this composer would carry, surviving what the model actually offers.
    var activeEffort: String? { ModelEffort.surviving(chosenEffort, options: effortOptions()) }
    /// The level the dial shows right now, and the levels the model it shows takes: what the
    /// brain's heads wear for a turn whose own messages recorded no effort, so a head and the
    /// pill never say two things.
    var shownEffort: String? { displayedEffort() }
    var shownEffortOptions: [String] { effortOptions() }
    /// The used-up windows on this server's account, for marking a model spent where it is picked.
    var quotasForModels: (() -> [UsageQuota])?

    var completionMatches: [SlashMatch] = []
    var completionCursor = 0
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

    func refreshAura() {
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
        setAccessibilityRole(.group)
        setAccessibilityLabel(editor.placeholder)
        updateVimUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var promptEditor: PromptEditor { editor }
    var editorHasFocus: Bool { editor.hasFocus }
    var editorIsComposing: Bool { editor.isComposing }

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
        pills.restyle()
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
        carry = CarryShelf.brief(profileID: entry.profileID, sessionID: entry.session.id)
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
        completion.hasProject = entry.session.directory != nil
        dismissCompletion()
        sendButton.title = Localized.text("Send")
        pills.setStopShown(false)
        restoreDraft(for: entry)
        refreshPills()
        loadSessionExtras(entry: entry, backend: backend)
    }

    /// The listing says something new about this chat — the name a server gave it, or the model
    /// and level a turn from another machine ran. This device's own pick still wins, but the
    /// fallback behind it is the listing's, so a chat driven elsewhere keeps one face here.
    func adopt(_ entry: SessionEntry) {
        self.entry = entry
        let key = Self.preferenceKey(entry)
        chosenModel = ModelPreferenceStore.initialModel(
            sessionKey: key, contextID: entry.profileID, sessionModel: entry.session.model,
            sessionModelProviderID: entry.session.modelProviderID)
        chosenEffort = EffortPreferenceStore.initialEffort(
            sessionKey: key, contextID: entry.profileID,
            sessionEffort: entry.session.reasoningEffort)
        refreshPills()
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
        // Emptying the box is how a message being rewritten is taken back, so a send with nothing
        // in it is a real action while one is open — and nothing at all otherwise.
        guard !text.isEmpty || !outgoing.isEmpty || isEditingQueued?() == true else { return }
        setEditorText("", caretAtEnd: true)
        if let draftScope { DraftStore.clear(draftScope) }
        vim.reset(to: "", cursor: 0, mode: .insert)
        updateVimUI()
        dismissCompletion()
        if handleSlashCommand(text) { return }
        let words = carry?.wrapped(with: text) ?? text
        attachments = []
        carry = nil
        syncChips()
        let effort = ModelEffort.surviving(chosenEffort, options: effortOptions())
        if Ultracode.invokes(text) || effort == Ultracode.effortLevel {
            ultracodeInFlight = true
        }
        refreshAura()
        onSubmitPrompt?(words, chosenModel, effort, outgoing.map(\.prompt))
    }

    /// What is in the box, for a caller deciding whether a key means something else.
    var currentText: String { editor.text }

    func takeBackQueued() -> Bool { onTakeBackQueued?() ?? false }

    /// Takes a waiting message into the box to be rewritten. Refuses while something is half
    /// typed: a rewrite may not throw away a sentence somebody is in the middle of.
    func adoptForEditing(_ send: QueuedSend) -> Bool {
        guard editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        setEditorText(send.text, caretAtEnd: true)
        editor.focus()
        attachments = send.attachments.map {
            PendingAttachment(
                name: $0.filename ?? "attachment", mime: $0.mime, data: $0.data ?? Data())
        }
        syncChips()
        return true
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
        editor.insertAtCaret(text)
        takeFocus()
    }

    /// What an undone message offers the box: its own words, ready to edit, but never over a
    /// sentence somebody is already in the middle of. Returns whether it landed, so a caller can
    /// remember exactly what it put there.
    @discardableResult
    func fillIfEmpty(_ text: String) -> Bool {
        guard editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        setEditorText(text, caretAtEnd: true)
        return true
    }

    /// Takes back words this composer offered, but only if they are still exactly what was put
    /// there: a person who kept typing after the offer landed keeps every word they added.
    func clearIfUnchanged(from text: String) {
        guard editor.text == text else { return }
        setEditorText("", caretAtEnd: true)
    }

    /// The completion panel is a sibling of the composer rather than a child — it hangs above the
    /// prompt box in the transcript's own container — so hiding the composer would otherwise leave
    /// a list of slash commands floating over a pane with nothing to type into.
    override func viewDidHide() {
        super.viewDidHide()
        dismissCompletion()
    }

    func openCommandPalette() {
        guard !isHidden else { return }
        pills.popUpCommandMenu()
    }

    /// Which conversation the words in the box belong to. A draft follows its chat rather than the
    /// pane it was typed in, and the same session id on two servers is two different chats.
    var draftScope: DraftScope? {
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

    /// A closing pane stops asking its server for models. The watch retries for as long as the
    /// server is down, so a pane closed on an unreachable machine would otherwise keep knocking
    /// every thirty seconds for the rest of the session.
    func stopWatching() {
        catalogWatch?.cancel()
        catalogWatch = nil
    }

    /// The pane's word on whether the call's control is drawn, and how.
    func setCallEntry(_ entry: CallEntry?) {
        pills.setCall(entry)
    }

    /// A pane hidden from the reader stops the pill's rainbow and the aura's laps.
    func setParked(_ parked: Bool) {
        pills.setParked(parked)
        editor.setAuraParked(parked)
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
        completion.renderCompletion(
            .naming(matches: completionMatches), cursor: completionCursor)
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
        abilities.attachments ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        abilities.attachments ? .copy : []
    }

    /// Dropping files on the prompt box attaches them, which is how a file gets from Finder into
    /// a conversation without a dialog in between; an image dragged out of another app arrives
    /// as a pasted picture.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard abilities.attachments else { return false }
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
}

/// The conversations new chats were carried from, held by the chat they will ride in. A chat is
/// opened in a pane that shows another chat's composer a moment later and again on every switch,
/// so the brief waits here rather than on a composer, and leaves when it is sent or put aside.
@MainActor
enum CarryShelf {
    private static var held: [String: ConversationBrief] = [:]

    private static func key(_ profileID: String, _ sessionID: String) -> String {
        "\(profileID)/\(sessionID)"
    }

    static func hold(_ brief: ConversationBrief?, profileID: String, sessionID: String) {
        held[key(profileID, sessionID)] = brief
    }

    static func brief(profileID: String, sessionID: String) -> ConversationBrief? {
        held[key(profileID, sessionID)]
    }
}
