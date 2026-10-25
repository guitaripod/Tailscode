import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension QuickAskPanel {
    /// The keys the box itself owes an answer to. Return is the send unless the settings say
    /// otherwise and shift always writes the line break — the same bargain the chat's own box
    /// makes — and vim, when it is on, is the same engine wearing the same modes, so escape
    /// leaves insert before it closes the panel.
    ///
    /// The list, while it is up, answers first. Outside insert mode the vim branch swallows every
    /// unmodified key, so a walk claimed after it would never see j or k — and escape has to close
    /// the list before it closes the panel, since a question is lost the moment nobody thought to
    /// keep it. Nothing is taken while the list is down.
    ///
    /// Tab, with no list to walk, moves the aim to the next server and shift-Tab to the one
    /// before, the way the Linux window spends the key: a question has no use for a tab character
    /// and the field is the only thing on the panel worth focusing, so the key is free to be the
    /// fastest way from one machine to the next.
    ///
    /// The dial's chords are the panel's own rather than the registry's, because the panel is
    /// not the window the registry serves: ⌃⌥↑↓ step the level the way the composer's do, and
    /// ⌥M or ⌥E — the key the effort menu used to answer to — open the dial. While the dial is
    /// open its keys arrive at the popover's own window, so nothing here sees them. The party's
    /// slot chords and the ring are the registry's, asked of the shortcut set rather than spelled
    /// here, so a chord a person rebound is the chord that works.
    func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self, !self.asking, !self.editor.isComposing else {
                return event
            }
            let flags = event.modifierFlags
            let control = flags.contains(.control)
            let shift = flags.contains(.shift)
            let option = flags.contains(.option)
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if self.completion.isShowing, self.handleCompletionKey(event) { return nil }
            if self.handleDialKey(event) { return nil }
            if self.handlePartyKey(event) { return nil }
            if event.keyCode == 48, !control, !flags.contains(.command), !option,
                self.servers.count > 1
            {
                self.cycleServer(by: shift ? -1 : 1)
                return nil
            }
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

    /// ⌃⌥↑ hotter, ⌃⌥↓ colder, ⌥M or ⌥E the dial. A ⌘ chord is the menu bar's and a bare arrow
    /// the field's, so both modifiers are demanded of the arrows and exactly option of the letters.
    private func handleDialKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command) else { return false }
        let modifiers = flags.subtracting([.shift, .capsLock, .numericPad, .function])
        if modifiers == [.control, .option] {
            switch event.keyCode {
            case 126:
                stepEffort(by: 1)
                return true
            case 125:
                stepEffort(by: -1)
                return true
            default:
                return false
            }
        }
        guard modifiers == [.option], let letter = event.charactersIgnoringModifiers?.lowercased(),
            letter == "m" || letter == "e"
        else { return false }
        chooseModel()
        return true
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
    func refreshCommands() {
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
    func updateSlashCompletion() {
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
    func accept(_ command: AgentCommand) {
        SlashRecents.record(command.name)
        let text = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
        editor.setText(text, caretAtEnd: true)
        editor.vim.reset(to: text, cursor: text.count, mode: .insert)
        editor.refreshMode()
        editor.focus()
    }

    func dismissCompletion() {
        completionMatches = []
        completionCursor = 0
        guard completion.isShowing else { return }
        completion.hide()
        resize()
    }
}
