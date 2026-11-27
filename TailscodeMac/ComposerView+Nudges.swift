import AppKit
import TailscodeCore

extension ComposerView {
    /// Resume and Status? beside the box, before the microphone. They show only while the box is
    /// empty, so they never take typing room, and only while the chat is quiet, where a send goes
    /// now.
    func configureNudges() {
        nudgeRow.orientation = .horizontal
        nudgeRow.alignment = .centerY
        nudgeRow.spacing = MacTheme.Spacing.xs
        nudgeRow.translatesAutoresizingMaskIntoConstraints = false
        nudgeRow.setContentHuggingPriority(.required, for: .horizontal)
        nudgeRow.setContentCompressionResistancePriority(.required, for: .horizontal)
        nudgeRow.isHidden = true
        for nudge in ChatNudge.all {
            let chip = SymbolChip(kind: .control)
            chip.symbol = nudge.symbol
            chip.text = nudge.title
            chip.toolTip = nudge.hint
            chip.setAccessibilityLabel(nudge.title)
            chip.setAccessibilityHelp(nudge.hint)
            chip.refusesFirstResponder = true
            chip.onTap = { [weak self] in self?.sendNudge(nudge) }
            nudgeRow.addArrangedSubview(chip)
        }
        editor.onDictatingChanged = { [weak self] in self?.refreshNudges() }
    }

    /// Shows the nudges exactly while Core offers them. Asked on every state a turn streams and on
    /// every key, so it touches the row only when the answer moves.
    func refreshNudges() {
        let shown = ChatNudge.offers(
            running: running, holdsWords: holdsWords,
            holdsAttachments: !attachments.isEmpty || carry != nil,
            editingQueued: isEditingQueued?() == true, dictating: dictation.isOpen,
            hasTranscript: !(lastState?.messages.isEmpty ?? true))
        guard shown != nudgesShown else { return }
        nudgesShown = shown
        nudgeRow.isHidden = !shown
    }

    /// The nudge's words, sent the way typed words are, so they are echoed, queued and refused for
    /// the same reasons.
    private func sendNudge(_ nudge: ChatNudge) {
        guard nudgesShown, sendAgain(nudge.prompt) else { return }
        takeFocus()
    }
}
