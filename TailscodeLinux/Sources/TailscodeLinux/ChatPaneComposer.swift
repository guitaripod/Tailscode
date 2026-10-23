import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// On the server first — what this machine will actually resolve — then what the app itself
    /// can do. Picking one drops it into the composer so arguments can follow.
    func commandRows() -> [(String, String?, @Sendable () -> Void)] {
        var rows: [(String, String?, @Sendable () -> Void)] = []
        rows.append(
            ("/compact", Localized.text("Trade the transcript for a summary — with a preflight"),
             { [weak self] in Gtk.onMain { [weak self] in
                 guard let self else { return }
                 self.host?.presentCompactPreflight(for: self)
             } }))
        rows.append(
            ("/goal", Localized.text("Set a standing goal the agent pursues"),
             { [weak self] in Gtk.onMain { [weak self] in self?.insertIntoComposer("/goal ") } }))
        if supportsDesign {
            rows.append(
                ("/design", CommandCatalogStore.designCommand.details,
                 { [weak self] in Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.host?.presentDesignPreflight(for: self, request: "")
                 } }))
        }
        if supportsDelegate {
            rows.append(
                ("/delegate", CommandCatalogStore.delegateCommand.details,
                 { [weak self] in Gtk.onMain { [weak self] in self?.handOff(goal: "") } }))
        }
        for command in commands
        where command.name != "compact" && command.name != "goal"
            && !(supportsDesign && command.name == SlashDispatch.designWord)
            && !(supportsDelegate && command.name == SlashDispatch.delegateWord)
        {
            let insertion = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
            rows.append(
                ("/\(command.name)", command.details.isEmpty ? command.source.rawValue : command.details,
                 { [weak self] in Gtk.onMain { [weak self] in self?.insertIntoComposer(insertion) } }))
        }
        return rows
    }

    func actionRows() -> [(String, String?, @Sendable () -> Void)] {
        guard let entry else { return [] }
        let capabilities = backend?.capabilities
        var rows: [(String, String?, @Sendable () -> Void)] = []

        let saved = SavedChatStore.contains(entry)
        rows.append(
            (saved ? Localized.text("Unsave") : Localized.text("Save"),
             Localized.text("A saved chat lists itself even when its server is unreachable"),
             { [weak self] in Gtk.onMain { [weak self] in self?.host?.toggleSaved(entry) } }))

        if capabilities?.supportsRenaming == true, let backend {
            rows.append(
                (Localized.text("Rename…"), nil,
                 { [weak self] in Gtk.onMain { [weak self] in
                     self?.host?.presentRename(entry: entry, backend: backend)
                 } }))
        }
        if capabilities?.supportsForking == true, let backend {
            rows.append(
                (Localized.text("Fork"),
                 Localized.text("A new session with this history, for a different direction"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     self?.host?.fork(entry: entry, backend: backend)
                 } }))
        }
        if capabilities?.supportsCompaction == true {
            rows.append(
                (Localized.text("Compact…"),
                 Localized.text("Irreversible, takes minutes"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.host?.presentCompactPreflight(for: self)
                 } }))
        }
        if supportsDelegate {
            rows.append(
                (DelegateHandoff.menuTitle, DelegateHandoff.details,
                 { [weak self] in Gtk.onMain { [weak self] in self?.handOff(goal: "") } }))
        }
        if !commands.isEmpty {
            rows.append(
                (Localized.text("All commands…"),
                 Localized.text("Browse every command this server offers"),
                 { [weak self] in Gtk.onMain { [weak self] in self?.presentCommandCatalog() } }))
        }
        if capabilities?.supportsClearing == true, let backend {
            rows.append(
                (Localized.text("Clear…"), Localized.text("Empty the conversation in place"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     self?.host?.presentClear(entry: entry, backend: backend)
                 } }))
        }
        if let backend {
            rows.append(
                (Localized.text("Delete…"), Localized.text("Remove the session from its server"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     self?.host?.presentDelete(entry: entry, backend: backend)
                 } }))
        }
        return rows
    }

    /// Alongside the badge, the caret itself says which mode this is: it blinks only in insert.
    func updateVimBadge() {
        editor.refreshMode()
        guard Preferences.vimComposer else {
            gtk_widget_set_visible(vimBadge, 0)
            return
        }
        gtk_widget_set_visible(vimBadge, 1)
        gtk_label_set_text(op(vimBadge), vim.mode.label)
        gtk_widget_remove_css_class(vimBadge, "vim-badge-visual")
        gtk_widget_remove_css_class(vimBadge, "vim-badge-insert")
        switch vim.mode {
        case .insert: Gtk.addClass(vimBadge, "vim-badge-insert")
        case .visual, .visualLine: Gtk.addClass(vimBadge, "vim-badge-visual")
        case .normal: break
        }
    }

    func composerHasFocus() -> Bool {
        guard let window = host?.windowWidget, let focused = tailscode_focused_widget(window)
        else { return false }
        return focused == entryView
    }

    /// The prompt box's own key handling: vim first when it is on, then Return-to-send. `nil`
    /// means this pane's composer does not have focus and the window should keep looking.
    func handleComposerKey(keyval: UInt32, state: UInt32) -> Bool? {
        guard composerHasFocus() else { return nil }
        let control = state & Keymap.control != 0
        let shift = state & Keymap.shift != 0

        if completionShown {
            switch keyval {
            case Keymap.tab:
                if let command = completion.selected { acceptSlashCommand(command) }
                return true
            case Keymap.shiftTab: completion.move(by: -1); return true
            case Keymap.down: completion.move(by: 1); return true
            case Keymap.up: completion.move(by: -1); return true
            case Keymap.escape: completion.dismiss(); return true
            default:
                if control, Keymap.scalar(keyval) == "n" { completion.move(by: 1); return true }
                if control, Keymap.scalar(keyval) == "p" { completion.move(by: -1); return true }
            }
        }

        if Preferences.vimComposer {
            let key = VimKey(
                character: Keymap.scalar(keyval),
                isEscape: keyval == Keymap.escape,
                isEnter: keyval == Keymap.enter || keyval == Keymap.keypadEnter,
                isBackspace: keyval == 0xFF08,
                control: control)
            if vim.mode == .insert, key.isEscape || (control && Keymap.scalar(keyval) == "[") {
                applyVim(vim.handle(VimKey(isEscape: true), text: composerText(), cursor: composerCursor()))
                return true
            }
            if vim.mode != .insert {
                return composerNormalKey(key, keyval: keyval, state: state)
            }
        }

        if control, !shift, Keymap.scalar(keyval) == "v" {
            pasteIntoComposer()
            return true
        }

        // ↑ in an empty box takes the last thing written back for rewriting. Only from an empty
        // box: in a half-typed paragraph that key is moving the caret, and taking it would be the
        // worse bug by far.
        if keyval == Keymap.up || keyval == 0xFF97, !control, !shift, takeBackLastQueued() {
            return true
        }

        let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
        if isReturn, !shift, Preferences.sendOnReturn || control {
            sendFromComposer()
            return true
        }
        if isReturn, shift || !Preferences.sendOnReturn { return false }
        return nil
    }

    /// The composer's normal mode is the app's normal mode: every key answers to the shortcut
    /// table first while vim keeps what makes it vim — and a chord sequence in flight outranks
    /// both, so `ctrl+w v` splits rather than entering visual mode. A key neither side binds goes
    /// back to vim rather than to the text view, so no stray letter types itself into the draft.
    func composerNormalKey(
        _ key: VimKey, keyval: UInt32, state: UInt32
    ) -> Bool? {
        guard let host else { return nil }
        if key.control, Keymap.scalar(keyval) == "c", copyComposerSelection() { return true }
        guard let chord = KeyChord.canonical(keyval: keyval, state: state) else { return nil }
        let awaiting = !(lastState?.pendingPermissions.isEmpty ?? true)
        if awaiting, !chord.control, !chord.alt, host.pendingChords.isEmpty,
            let action = host.shortcuts.approval[chord.token]
        {
            host.pendingChords = []
            return host.perform(action)
        }
        if key.isEnter, chord.control {
            host.pendingChords = []
            sendFromComposer()
            return true
        }
        let plain = !chord.control && !chord.alt
        if vim.claims(key, plain: plain, chordPending: !host.pendingChords.isEmpty) {
            host.pendingChords = []
            applyVim(vim.handle(key, text: composerText(), cursor: composerCursor()))
            return true
        }
        let resolution = host.shortcuts.resolve(
            chord, context: .normal, pending: host.pendingChords, awaitingApproval: false)
        switch resolution {
        case .run(let action):
            host.pendingChords = []
            return host.perform(action)
        case .pending(let chords):
            host.pendingChords = chords
            return true
        case .unbound:
            host.pendingChords = []
            applyVim(vim.handle(key, text: composerText(), cursor: composerCursor()))
            return true
        }
    }

    func copyComposerSelection() -> Bool {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        guard gtk_text_buffer_get_selection_bounds(buffer, &start, &end) != 0,
            let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0)
        else { return false }
        Gtk.copyToClipboard(String(cString: raw))
        g_free(raw)
        host?.toast(Localized.text("Copied"))
        return true
    }

    func applyVim(_ outcome: VimOutcome) {
        switch outcome {
        case .passThrough, .handled:
            if case .handled = outcome { editor.write(vim.document, selection: vim.selection) }
        case .send:
            sendFromComposer()
        }
        updateVimBadge()
    }

    /// What the transcript is actually made of, for the driver: a message's role, the head of its
    /// id and how many characters it is carrying. A count alone says the transcript grew and never
    /// says whether the same answer arrived twice under two names, which is exactly the question a
    /// duplicate asks.
    static func driverCensus(of messages: [ChatMessage]) -> String {
        let census = messages.map { message -> String in
            let text = message.parts.reduce(into: 0) { total, part in
                if case .text(let value) = part.kind { total += value.count }
            }
            return "\(message.role.rawValue.prefix(1)):\(message.id.prefix(8))/\(text)"
        }
        return "[" + census.joined(separator: " ") + "]"
    }

    func composerCursor() -> Int { editor.cursor }

    /// Typing `/word` offers what it could become, right above the prompt box, through the same
    /// popover the quick ask paints — one list, so neither composer can learn something the other
    /// does not.
    var completionShown: Bool { completion.isShown }

    func updateSlashCompletion() {
        let typing = !Preferences.vimComposer || vim.mode == .insert
        guard typing else {
            completion.dismiss()
            return
        }
        completion.hasProject = entry?.session.directory?.isEmpty == false
        let offered = composerCommands
        completion.catalogSize = offered.count
        completion.renderCompletion(
            SlashPresentation.of(
                text: composerText(), commands: offered,
                recents: SlashRecents.surviving(in: offered)),
            cursor: completion.cursor)
    }

    func acceptSlashCommand(_ command: AgentCommand) {
        SlashRecents.record(command.name)
        let text = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        gtk_text_buffer_set_text(buffer, text, -1)
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_place_cursor(buffer, &end)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        updateVimBadge()
        gtk_widget_grab_focus(entryView)
        if !command.takesArguments { updateSlashCompletion() }
    }

    func dismissCompletion() {
        completion.dismiss()
    }

    /// The greppable catalog surface for Linux — every command this server offers.
    func presentCommandCatalog() {
        dismissCompletion()
        CommandCatalog.present(parent: root, commands: composerCommands) { [weak self] command in
            Gtk.onMain { [weak self] in self?.acceptSlashCommand(command) }
        }
    }

    /// A paste is an attach as much as a paste, so the composer takes the clipboard rather than
    /// letting the text widget take it: files and pictures become chips where they would otherwise
    /// have to be saved to disk and picked back up, and only words go in as words. What this model
    /// cannot be handed is refused by name in the notice line rather than dropped.
    func pasteIntoComposer() {
        let able = abilities
        let named = pastedImageCount
        Gtk.readClipboard { offer in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                let plan = PasteIntake.plan(for: offer, abilities: able, alreadyNamed: named)
                self.pastedImageCount = plan.named
                if let text = plan.text, !text.isEmpty { self.insertAtCaret(text) }
                if !plan.attachments.isEmpty {
                    self.attachments.append(contentsOf: plan.attachments)
                    self.renderAttachments()
                }
                if let notice = plan.notices.first { self.setNotice(notice) }
            }
        }
    }

    /// Where a paste actually lands, which is at the caret and never at the end: the composer is a
    /// document a person moves around in, and vim's shadow of it has to be told what was written
    /// or the next normal-mode key would edit a string that no longer exists.
    func insertAtCaret(_ text: String) {
        editor.insertAtCaret(text)
    }

    func insertIntoComposer(_ text: String) {
        editor.insertAtEnd(text)
    }

    func composerText() -> String { editor.text }

    /// Empties the prompt box and the vim document that shadows it, without touching any stored
    /// draft: called where the pane has already let go of the conversation the text belonged to.
    func clearComposer() {
        editor.clear()
        lastRecordedDraft = ""
        updateVimBadge()
    }

    /// What is in the composer right now, recorded as it is typed. The store is built to be told
    /// on every keystroke, so nothing here throttles it a second time.
    func recordDraft() {
        guard let draftScope else { return }
        let text = composerText()
        lastRecordedDraft = text
        DraftStore.record(text, for: draftScope)
    }

    /// Half-typed prompts follow their conversation, not the pane: switching chats stashes what
    /// was in the composer and restores whatever was stashed for the chat being opened. Called
    /// where the pane is about to stop being asked, so the write happens now rather than on the
    /// next quiet moment that may never come.
    ///
    /// Two panes can hold the same chat, and a scope is the conversation's rather than the pane's,
    /// so a pane that has not been typed into since it last recorded has nothing to say about that
    /// draft: it writes only when its own buffer has moved, and the pane still being typed into
    /// keeps the text. The flush is unconditional — someone else's newer edit is still owed a disk.
    func stashDraft() {
        if composerText() != lastRecordedDraft { recordDraft() }
        DraftStore.flush()
    }

    func restoreDraft(for entry: SessionEntry) {
        let draft = DraftStore.text(
            for: .chat(profileID: entry.profileID, sessionID: entry.session.id))
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), draft, -1)
        lastRecordedDraft = draft
        vim.reset(to: draft, cursor: draft.count, mode: .insert)
        updateVimBadge()
    }

    /// The prompt is on screen before the server has heard of it: a busy bridge can take seconds
    /// to answer, and a composer that empties into silence reads as a hang.
    func sendFromComposer() {
        let text = composerText().trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = attachments
        // Emptying the box is how a message being rewritten is taken back, so a send with nothing
        // in it is a real action while one is open — and nothing at all otherwise.
        guard !text.isEmpty || !outgoing.isEmpty || editingQueued != nil, let conversation
        else { return }
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        gtk_text_buffer_set_text(buffer, "", 0)
        if let draftScope { DraftStore.clear(draftScope) }
        vim.reset(to: "", cursor: 0, mode: .insert)
        updateVimBadge()
        if let id = editingQueued {
            editingQueued = nil
            if let draftScope { DraftStore.clear(draftScope) }
            attachments = []
            renderAttachments()
            if let queue, let row = queueDisplay.row(id: id) {
                queue.edit(
                    row, text: text, attachments: outgoing.map(\.prompt), through: conversation
                ) { [weak self] outcome in
                    Gtk.onMain { [weak self] in
                        if outcome == .alreadyStarted { self?.addWordsToComposer(text, announcing: false) }
                        self?.report(outcome)
                    }
                }
            } else {
                addWordsToComposer(text, announcing: false)
                setNotice(QueueReading.alreadySent)
            }
            if let state = lastState { apply(state: state, rows: lastFullRows) }
            return
        }
        if handleSlashCommand(text) { return }
        attachments = []
        renderAttachments()
        let send = QueuedSend(
            text: text, model: chosenModel,
            effort: ModelEffort.surviving(chosenEffort, options: effortOptions()),
            attachments: outgoing.map(\.prompt))
        // A prompt written while a turn runs is held here, not handed over: a message you can
        // still change is worth more than a message one place further along.
        guard lastState?.status != .running, lastState?.compaction?.isRunning != true else {
            hold(send)
            if let state = lastState { apply(state: state, rows: lastFullRows) }
            scrollToBottom()
            return
        }
        deliver(send, through: conversation)
        refreshUltracodeAura()
    }

    /// The words of a turn that said nothing, asked again. They go through the composer rather
    /// than straight to the backend so the retry is the same send as any other — echoed, drafted,
    /// and refused for the same reasons — and anything half-typed is kept rather than replaced.
    func askAgain(_ words: String) {
        guard !words.isEmpty else { return }
        let pending = composerText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending.isEmpty else {
            addWordsToComposer(words)
            return
        }
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), words, -1)
        sendFromComposer()
    }

    /// Words offered to a composer that is already being written in go after what is there, a
    /// blank line between, and nothing is sent: half a message is the person's, and a retry must
    /// never replace it or ride out with it.
    func addWordsToComposer(_ words: String, announcing: Bool = true) {
        let existing = composerText()
        let kept = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined: String
        if kept.isEmpty {
            joined = words
        } else {
            let tail = existing.reversed().prefix { $0 == "\n" }.count
            joined = String(repeating: "\n", count: max(0, 2 - tail)) + words
        }
        editor.insertAtEnd(joined)
        vim.reset(to: editor.text, cursor: editor.text.count, mode: .insert)
        updateVimBadge()
        focusComposer()
        if announcing && !kept.isEmpty { setNotice(Localized.text("Added to the composer.")) }
    }

    /// A prompt the app composed rather than the person typed — a design brief, a follow-up on an
    /// artboard — sent through the same composer for the same reasons: it is echoed, drafted and
    /// refused exactly like the words somebody types, and nothing half-written is thrown away.
    func sendComposed(_ words: String) {
        guard !words.isEmpty else { return }
        let pending = composerText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending.isEmpty else {
            setNotice(Localized.text("Send or clear what is in the composer first."))
            return
        }
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), words, -1)
        sendFromComposer()
    }

    /// A typed slash command goes where the completion list would send it. The decision is the
    /// shared one so all three clients answer a typed command the same way; false means the words
    /// go out as an ordinary prompt.
    func handleSlashCommand(_ text: String) -> Bool {
        switch SlashDispatch.decide(
            text: text, commands: composerCommands,
            supportsCompaction: backend?.capabilities.supportsCompaction != false,
            resolvesFromPromptText: backend?.resolvesCommandsFromPromptText == true,
            supportsDesign: supportsDesign, supportsDelegate: supportsDelegate)
        {
        case .compactPreflight(let instruction):
            host?.presentCompactPreflight(for: self, initialInstruction: instruction)
            return true
        case .designPreflight(let request):
            host?.presentDesignPreflight(for: self, request: request)
            return true
        case .delegatePreflight(let goal):
            handOff(goal: goal)
            return true
        case .run(let command, let arguments):
            guard let conversation else { return false }
            enqueueOrRun(
                QueuedSend(
                    text: arguments ?? "", model: chosenModel,
                    effort: ModelEffort.surviving(chosenEffort, options: effortOptions()),
                    kind: .command(name: command.name, arguments: arguments ?? "")),
                through: conversation)
            return true
        case .plainText:
            return false
        }
    }
}
