import AppKit
import CodingAgentKit
import TailscodeCore

extension ComposerView {
    func configureEditor() {
        editor.onPaste = { [weak self] in self?.takeClipboard() ?? false }
        editor.onChanged = { [weak self] in self?.editorContentChanged() }
        editor.onModeChanged = { [weak self] in self?.updateVimUI() }

        sendButton.title = Localized.text("Send")
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func configureLayout() {
        let editorRow = NSStackView(views: [editor, sendButton])
        editorRow.orientation = .horizontal
        editorRow.alignment = .bottom
        editorRow.spacing = MacTheme.Spacing.s
        editorRow.translatesAutoresizingMaskIntoConstraints = false

        let column = FillingStack(views: [chips, editorRow, pills])
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
        chips.onClearCarry = { [weak self] in self?.carry = nil }
        completion.onPick = { [weak self] command in
            self?.accept(command)
        }
        completion.onBrowse = { [weak self] in self?.onBrowseCommands?() }
    }

    func wirePills() {
        pills.onDial = { [weak self] in self?.pressModelPill() }
        pills.onDialStep = { [weak self] delta in self?.stepEffort(by: delta) }
        pills.commandRows = { [weak self] in self?.commandMenuRows() ?? [] }
        pills.attachRows = { [weak self] in self?.attachMenuRows() ?? [] }
        pills.onStop = { [weak self] in self?.onStop?() }
        pills.onCall = { [weak self] in self?.onCall?() }
        pills.onLane = { [weak self] lane in self?.onLane?(lane) }
    }

    /// Everything worth knowing about the session besides its transcript, fetched once per open
    /// and remembered: the models the server offers and the commands it resolves. The catalog is
    /// watched rather than asked once — a server asked while it restarts must not be remembered as
    /// having no models, so the ask retries and every answer re-paints the pills and an open sheet.
    func loadSessionExtras(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        let profileID = entry.profileID
        let directory = entry.session.directory
        catalogWatch?.cancel()
        catalogWatch = Task { [weak self] in
            for await reading in ModelCatalogWatch.readings(
                profileID: profileID, backend: backend)
            {
                guard let self, self.entry?.session.id == sessionID else { return }
                self.modelsByProfile[profileID] = reading.models
                self.reachableByProfile[profileID] = reading.reachable
                self.models = reading.models
                self.modelSheet?.update(sources: self.modelSources(), quotas: self.quotasForModels?())
                self.refreshPills()
            }
        }
        Task { [weak self] in
            let commands = (try? await backend.availableCommands(directory: directory)) ?? []
            guard let self else { return }
            self.commandsBySession[sessionID] = commands
            guard self.entry?.session.id == sessionID else { return }
            self.commands = commands
            self.refreshPills()
        }
    }

    static func preferenceKey(_ entry: SessionEntry) -> String {
        "\(entry.profileID)/\(entry.session.id)"
    }

    /// Alongside the badge, the caret itself says which mode this is: it blinks only in insert.
    /// In normal and visual it is hidden — the letters belong to commands, and a blinking beam
    /// would promise typing the composer will not do. The field's border carries the mode too.
    func updateVimUI() {
        editor.refreshMode()
        pills.setVim(vimEnabled ? vim.mode : nil)
    }

    func writeEditor(_ document: VimDocument, selection: Range<Int>?) {
        editor.write(document, selection: selection)
    }

    func setEditorText(_ text: String, caretAtEnd: Bool) {
        editor.setText(text, caretAtEnd: caretAtEnd)
    }

    func restoreDraft(for entry: SessionEntry) {
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
