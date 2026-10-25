import AppKit
import TailscodeCore

extension PreferencesWindow {
    /// The Shortcuts section of the Keyboard page: a search over every action, the list, the
    /// way to change one, and the way back to the shipped keys.
    func addShortcutsSection(to column: NSStackView) {
        column.addArrangedSubview(MacDialogs.sectionHeader(Localized.text("Shortcuts")))
        column.addArrangedSubview(
            infoRow(
                title: Localized.text("Change a shortcut"),
                detail: Localized.text(
                    "Press Change… and then the keys you want. ⌘ shortcuts belong to the menu bar.")
            ))
        let search = NSSearchField()
        search.placeholderString = Localized.text("Search shortcuts")
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(shortcutSearchChanged(_:))
        search.setAccessibilityLabel(Localized.text("Search shortcuts"))
        column.addArrangedSubview(search)
        search.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        column.setCustomSpacing(MacTheme.Spacing.m, after: search)

        shortcutNote.font = MacTheme.Ramp.font(.panelFootnote)
        shortcutNote.textColor = MacTheme.Color.warning
        shortcutNote.isHidden = true
        column.addArrangedSubview(shortcutNote)
        shortcutNote.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive =
            true

        let list = ShortcutListView()
        list.onChange = { [weak self] id in self?.changeShortcut(id) }
        list.onRestore = { [weak self] id in self?.restoreShortcut(id) }
        list.reload()
        shortcutList = list
        column.addArrangedSubview(list)
        list.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true

        shortcutResetButton.target = self
        shortcutResetButton.action = #selector(resetEveryShortcut)
        column.addArrangedSubview(
            chordRow(
                title: Localized.text("Reset every shortcut"), button: shortcutResetButton,
                detail: shortcutResetDetail, monospaced: false))
        renderShortcutReset()
    }

    @objc func shortcutSearchChanged(_ sender: NSSearchField) {
        shortcutList?.filter(sender.stringValue)
    }

    func renderShortcutReset() {
        if ShortcutFile.isUnreadable {
            shortcutResetButton.title = Localized.text("Reset the file…")
            shortcutResetDetail.stringValue = Localized.text(
                "keybindings.json is not valid JSON — fix it in the text editor, or reset it")
            shortcutResetDetail.textColor = MacTheme.Color.warning
            shortcutResetButton.isEnabled = true
            return
        }
        let changed = ShortcutBindings.load().customizedCount
        shortcutResetButton.title = Localized.text("Reset…")
        shortcutResetButton.isEnabled = changed > 0
        shortcutResetDetail.textColor = MacTheme.Color.secondaryLabel
        shortcutResetDetail.stringValue =
            switch changed {
            case 0: Localized.text("Every shortcut is as shipped")
            case 1: Localized.text("1 shortcut is changed from the keys it shipped with")
            default: Localized.text("%d shortcuts are changed from the keys they shipped with", changed)
            }
    }

    func shortcutsEdited() {
        shortcutList?.reload()
        renderShortcutReset()
        onReloadShortcuts()
    }

    private func say(_ problem: String?) {
        shortcutNote.stringValue = problem ?? ""
        shortcutNote.isHidden = problem == nil
    }

    func changeShortcut(_ id: String) {
        guard let window,
            let sheet = ShortcutCaptureSheet(id: id, onChange: { [weak self] in
                self?.shortcutsEdited()
            })
        else { return }
        say(nil)
        captureSheet?.stopHearing()
        captureSheet = sheet
        sheet.begin(on: window)
    }

    func restoreShortcut(_ id: String) {
        do {
            try ShortcutEditor.apply(ShortcutEditor.restoring(id, in: ShortcutBindings.load()))
            say(nil)
            shortcutsEdited()
        } catch {
            say(Self.shortcutProblem(error))
        }
    }

    static func shortcutProblem(_ error: Error) -> String {
        error as? ShortcutFile.Failure == .unreadable
            ? Localized.text(
                "keybindings.json is not valid JSON — fix it in the text editor, or reset it")
            : error.localizedDescription
    }

    @objc func resetEveryShortcut() {
        if ShortcutFile.isUnreadable {
            MacDialogs.confirm(
                on: window, title: Localized.text("Replace keybindings.json?"),
                body: Localized.text(
                    "The file is not valid JSON. Its text is kept beside it as keybindings.json.broken, and a fresh file takes its place."
                ), confirmLabel: Localized.text("Replace"), destructive: false
            ) { [weak self] in self?.replaceBrokenShortcutFile() }
            return
        }
        MacDialogs.confirm(
            on: window, title: Localized.text("Reset every shortcut?"),
            body: Localized.text(
                "Every shortcut goes back to the keys it shipped with. Notes you wrote in keybindings.json stay."
            ), confirmLabel: Localized.text("Reset")
        ) { [weak self] in
            do {
                try ShortcutFile.resetAll()
                self?.say(nil)
                self?.shortcutsEdited()
            } catch {
                self?.say(Self.shortcutProblem(error))
                self?.renderShortcutReset()
            }
        }
    }

    private func replaceBrokenShortcutFile() {
        do {
            try ShortcutFile.resetAll()
            say(nil)
            shortcutsEdited()
        } catch {
            say(error.localizedDescription)
        }
    }
}
