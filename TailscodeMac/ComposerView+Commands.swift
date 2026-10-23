import AppKit
import CodingAgentKit
import TailscodeCore

extension ComposerView {
    /// On the server first — what this machine will actually resolve — then what the app itself
    /// can do. Picking one drops it into the composer so arguments can follow; `/compact` keeps
    /// its preflight.
    func commandMenuRows() -> [PillsRow.MenuRow] {
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
        if supportsDesign {
            rows.append(
                PillsRow.MenuRow(
                    "/design", subtitle: CommandCatalogStore.designCommand.details
                ) { [weak self] in
                    self?.onDesignRequested?("")
                })
        }
        if supportsDelegate {
            rows.append(
                PillsRow.MenuRow(
                    "/delegate", subtitle: CommandCatalogStore.delegateCommand.details
                ) { [weak self] in
                    self?.onDelegateRequested?("")
                })
        }
        for command in commands
        where command.name != "compact" && command.name != "goal"
            && !(supportsDesign && command.name == SlashDispatch.designWord)
            && !(supportsDelegate && command.name == SlashDispatch.delegateWord)
        {
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
    func handleSlashCommand(_ text: String) -> Bool {
        switch SlashDispatch.decide(
            text: text, commands: availableCommands,
            supportsCompaction: backend?.capabilities.supportsCompaction != false,
            resolvesFromPromptText: backend?.resolvesCommandsFromPromptText == true,
            supportsDesign: supportsDesign, supportsDelegate: supportsDelegate)
        {
        case .compactPreflight(let instruction):
            onCompactRequested?(instruction)
            return true
        case .designPreflight(let request):
            onDesignRequested?(request)
            return true
        case .delegatePreflight(let goal):
            onDelegateRequested?(goal)
            return true
        case .run(let command, let arguments):
            SlashRecents.record(command.name)
            onRunCommand?(
                command, arguments, chosenModel,
                ModelEffort.surviving(chosenEffort, options: effortOptions()))
            return true
        case .plainText:
            return false
        }
    }

    /// Every path that changes what is in the box lands here — a keystroke, a vim edit, a
    /// completion accepted — so it is also where the draft is recorded. Recording is a dictionary
    /// write and the store coalesces the file write itself, so nothing here is throttled.
    func editorContentChanged() {
        if let draftScope {
            let text = editor.text
            DraftStore.record(text, for: draftScope)
            lastRecordedDraft = text
        }
        updateSlashCompletion()
        refreshAura()
    }

    /// Which row is highlighted is kept by which command it is, never by where it sat: a narrowing
    /// keystroke re-ranks and shortens the list, and an index would quietly move the highlight onto
    /// a different command — which is then the one Tab takes.
    private func updateSlashCompletion() {
        let typing = !vimEnabled || vim.mode == .insert
        guard typing else {
            dismissCompletion()
            return
        }
        completion.onPick = { [weak self] command in self?.accept(command) }
        completion.onBrowse = { [weak self] in self?.onBrowseCommands?() }
        let offered = availableCommands
        let presentation = SlashPresentation.of(
            text: editor.text, commands: offered,
            recents: SlashRecents.surviving(in: offered))
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
        case .arguments, .noMatch:
            completionMatches = []
            completionCursor = 0
            completion.renderCompletion(presentation)
        }
    }

    func acceptCompletion(at index: Int) {
        guard index < completionMatches.count else { return }
        accept(completionMatches[index].command)
    }

    func accept(_ command: AgentCommand) {
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
}
