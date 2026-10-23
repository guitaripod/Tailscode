import TailscodeCore
import UIKit

extension ChatViewController {
    /// Only while the palette is up, and only then claiming priority over the system: the same
    /// arrows have to keep moving the caret through an ordinary draft, and Return has to keep
    /// sending one. A completion list that ate them permanently would be worse than none.
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
            composer.triggerSend()
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

extension ChatViewController: KeyActionHost {
    var keyContext: KeyContext {
        composer.isEditing || findField.isFirstResponder ? .insert : .normal
    }

    var keyAwaitingApproval: Bool { pendingPermission != nil }

    /// The conversation's answers to the shared registry — the same verbs the desktops
    /// dispatch, spoken through this screen's own controls. False lets a press fall through.
    func performKeyAction(_ action: KeyAction) -> Bool {
        switch action {
        case .scrollDown:
            nudgeTranscript(by: 80)
        case .scrollUp:
            nudgeTranscript(by: -80)
        case .halfPageDown:
            nudgeTranscript(by: collectionView.bounds.height * 0.5)
        case .halfPageUp:
            nudgeTranscript(by: -collectionView.bounds.height * 0.5)
        case .scrollTop:
            userScrolledUp = true
            collectionView.setContentOffset(
                CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
        case .scrollBottom:
            scrollToBottom(animated: true)
        case .previousPrompt:
            jumpToPrompt(by: -1)
        case .nextPrompt:
            jumpToPrompt(by: 1)
        case .copyLastAnswer:
            return copyLastAnswer()
        case .findInConversation:
            openFind()
        case .insert:
            composer.focus()
        case .leaveInsert:
            if findVisible {
                closeFind()
                becomeFirstResponder()
            } else if composer.isEditing {
                composer.unfocus()
                becomeFirstResponder()
            } else {
                return false
            }
        case .send:
            guard composer.isEditing else { return false }
            composer.triggerSend()
        case .stop:
            guard viewModel.isBusy else { return false }
            composerDidTapStop()
        case .commandPalette:
            composer.setDraft("/")
        case .toggleSaved:
            toggleSaved()
        case .archiveSelected:
            toggleArchivedFromHere()
        case .renameSelected:
            guard viewModel.canRename else { return false }
            promptRename()
        case .forkSelected:
            guard viewModel.canFork else { return false }
            forkConversation()
        case .allowOnce:
            guard let permission = pendingPermission else { return false }
            viewModel.respond(to: permission, decision: .once)
        case .allowAlways:
            guard let permission = pendingPermission else { return false }
            viewModel.respond(to: permission, decision: .always)
        case .deny:
            guard let permission = pendingPermission else { return false }
            viewModel.respond(to: permission, decision: .reject)
        case .toggleHelp:
            ShortcutCheatsheetViewController.present(from: self)
        case .toggleSidebar:
            guard let workspace else { return false }
            workspace.toggleColumns()
        case .effortHotter:
            stepEffort(by: 1)
        case .effortColder:
            stepEffort(by: -1)
        case .modelDial:
            dialPill.openRail()
        case .presetNext:
            cyclePreset(by: 1)
        case .presetPrevious:
            cyclePreset(by: -1)
        case .preset(let number):
            guard let preset = viewModel.preset(number: number) else { return false }
            applyPreset(preset)
        default:
            return false
        }
        return true
    }

    /// The rows that are a person's own words, in order: where the previous-prompt and
    /// next-prompt keys stop.
    private var promptRowIDs: [String] {
        orderedIDs.filter { id in
            guard let row = rowsByID[id], row.role == .user, case .text = row.content else {
                return false
            }
            return true
        }
    }

    /// Scrolls so the previous or next prompt of the person sits at the top of the page, one
    /// motion (none under reduced motion), and stays put at either end.
    private func jumpToPrompt(by direction: Int) {
        let inset = collectionView.adjustedContentInset
        let top = collectionView.contentOffset.y + inset.top
        let snapshot = dataSource.snapshot()
        let anchors: [CGFloat] = promptRowIDs.compactMap { id in
            guard let index = snapshot.indexOfItem(id),
                let frame = collectionView.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0))?.frame
            else { return nil }
            return frame.minY + (appliedGaps[id] ?? 0) - Theme.Spacing.s
        }
        let target = direction < 0
            ? anchors.last { $0 < top - 2 } : anchors.first { $0 > top + 2 }
        guard let target else { return }
        let minY = -inset.top
        let maxY = max(
            minY, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
        let offset = min(maxY, max(minY, target - inset.top))
        userScrolledUp = true
        collectionView.setContentOffset(
            CGPoint(x: 0, y: offset), animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// The last thing the agent said, on the pasteboard, said aloud and shown for a moment.
    private func copyLastAnswer() -> Bool {
        guard let answer = viewModel.state.messages.last(where: { $0.role == .assistant })?.text,
            !answer.isEmpty
        else { return false }
        UIPasteboard.general.string = answer
        Theme.Haptics.selection()
        presentToast(String(localized: "Copied"))
        announce(String(localized: "Copied"))
        return true
    }

    private func nudgeTranscript(by delta: CGFloat) {
        let inset = collectionView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
        let target = min(maxY, max(minY, collectionView.contentOffset.y + delta))
        if delta < 0 { userScrolledUp = true }
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }
}
