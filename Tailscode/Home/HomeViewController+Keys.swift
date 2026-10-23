import TailscodeCore
import UIKit

extension HomeViewController {
    /// Only while the list is up, and only then claiming priority over the system: the arrows have
    /// to keep moving the caret through an ordinary question, Return has to keep sending it, and
    /// escape has to close the list before it gives up the keyboard.
    func paletteKeyCommands() -> [UIKeyCommand] {
        let bindings: [(String, Selector)] = [
            (UIKeyCommand.inputUpArrow, #selector(paletteSelectPrevious)),
            (UIKeyCommand.inputDownArrow, #selector(paletteSelectNext)),
            ("\t", #selector(paletteSelectNext)),
            ("\r", #selector(paletteAccept)),
            (UIKeyCommand.inputEscape, #selector(paletteDismiss)),
        ]
        var commands = bindings.map { input, action -> UIKeyCommand in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        let back = UIKeyCommand(
            input: "\t", modifierFlags: .shift, action: #selector(paletteSelectPrevious))
        back.wantsPriorityOverSystemBehavior = true
        commands.append(back)
        return commands
    }

    @objc private func paletteSelectNext() { commandPalette.moveSelection(by: 1) }

    @objc private func paletteSelectPrevious() { commandPalette.moveSelection(by: -1) }

    @objc private func paletteAccept() {
        guard commandPalette.activateSelection() else {
            let text = composerBar.currentText
            guard !text.isEmpty else { return }
            Theme.Haptics.send()
            composerSend(text)
            return
        }
    }

    @objc private func paletteDismiss() { hideCommandPalette() }

    @objc func handleInsertKeyCommand(_ command: UIKeyCommand) {
        guard let token = command.propertyList as? String,
            let chord = KeyBridge.chord(forToken: token)
        else { return }
        _ = KeyBridge.shared.handle(chord, context: .insert, awaitingApproval: false) {
            [weak self] action in
            self?.performKeyAction(action) ?? false
        }
    }
}

extension HomeViewController: KeyActionHost {
    var keyContext: KeyContext { composerBar.isEditing ? .insert : .normal }

    /// The board's answers to the shared registry: the app-level verbs live here — new chat,
    /// filter, archive view, help — and the list-cursor verbs live one push away on the Chats
    /// screen, which is where a hardware-keyboard user lands the moment they ask for them.
    func performKeyAction(_ action: KeyAction) -> Bool {
        switch action {
        case .newChat:
            guard let profile = viewModel.servers.first else { return false }
            if viewModel.servers.count == 1 {
                startChat(on: profile)
            } else {
                composerBar.focus()
            }
        case .search:
            if let workspace { workspace.beginSearch() } else { pushChats() }
        case .selectNext, .selectPrevious, .selectFirst, .selectLast, .openSelected:
            if let workspace { workspace.focusList(then: action) } else { pushChats() }
        case .toggleArchiveView:
            Theme.Haptics.tap()
            if let workspace {
                workspace.showArchived()
            } else {
                navigationController?.pushViewController(
                    ArchivedChatsViewController(), animated: true)
            }
        case .toggleSidebar:
            guard let workspace else { return false }
            workspace.toggleColumns()
        case .insert:
            composerBar.focus()
        case .quickAsk:
            presentQuickAsk()
        case .leaveInsert:
            guard composerBar.isEditing else { return false }
            composerBar.unfocus()
            becomeFirstResponder()
        case .scrollDown:
            nudgeBoard(by: 120)
        case .scrollUp:
            nudgeBoard(by: -120)
        case .halfPageDown:
            nudgeBoard(by: collectionView.bounds.height * 0.5)
        case .halfPageUp:
            nudgeBoard(by: -collectionView.bounds.height * 0.5)
        case .reload:
            Task { await load(.user) }
        case .toggleHelp:
            ShortcutCheatsheetViewController.present(from: self)
        case .effortHotter, .effortColder:
            guard let aim = composerAim else { return false }
            let options = dialOptions(for: aim)
            guard ModelEffort.isOffered(options: options) else { return false }
            let choice = modelChoices[aim.memoryKey] ?? ModelChoice()
            let notch = ModelDial.notch(
                from: choice.effort, by: action == .effortHotter ? 1 : -1, options: options)
            setComposeEffort(notch.level, for: aim)
            Theme.Haptics.notch()
            EffortSpeech.note(notch)
        case .modelDial:
            composerBar.dialPill.openRail()
        case .presetNext:
            cycleComposePreset(by: 1)
        case .presetPrevious:
            cycleComposePreset(by: -1)
        case .preset(let number):
            guard let aim = composerAim else { return false }
            let presets = composePins(for: aim).reachable
            guard presets.indices.contains(number - 1) else { return false }
            setComposePreset(presets[number - 1], for: aim)
        default:
            return false
        }
        return true
    }

    private func nudgeBoard(by delta: CGFloat) {
        let inset = collectionView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(
            minY, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
        let target = min(maxY, max(minY, collectionView.contentOffset.y + delta))
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }
}
