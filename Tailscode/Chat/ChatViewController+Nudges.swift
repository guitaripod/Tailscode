import TailscodeCore
import UIKit

extension ChatViewController {
    func configureNudgeChips() {
        for (nudge, chip) in nudgeChips {
            chip.setSymbol(nudge.symbol)
            chip.text = nudge.title
            chip.accessibilityLabel = nudge.title
            chip.accessibilityHint = nudge.hint
            chip.addAction(
                UIAction { [weak self] _ in self?.sendNudge(nudge) }, for: .touchUpInside)
        }
        composer.onBareChanged = { [weak self] in self?.refreshNudges() }
    }

    /// Shows the nudges exactly while Core offers them. Asked on every state a turn streams and on
    /// every change to the box, so it touches the row only when the answer moves.
    func refreshNudges() {
        let shown = ChatNudge.offers(
            running: viewModel.isBusy, holdsWords: composer.holdsWords,
            holdsAttachments: composer.carriesAttachments, editingQueued: composer.isEditingQueued,
            dictating: composer.dictation.isOpen, hasTranscript: !viewModel.state.messages.isEmpty)
        guard shown != nudgesShown else { return }
        nudgesShown = shown
        for (_, chip) in nudgeChips { chip.isHidden = !shown }
        factsRow.refresh()
        syncFactsScrim()
    }

    /// The nudge's words, sent the way typed words are, so they are echoed, queued and refused for
    /// the same reasons.
    private func sendNudge(_ nudge: ChatNudge) {
        guard nudgesShown else { return }
        Theme.Haptics.send()
        composerDidSend(nudge.prompt)
    }
}
