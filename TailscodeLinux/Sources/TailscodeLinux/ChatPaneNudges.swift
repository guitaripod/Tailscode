import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension ChatPane {
    /// Resume and Status? for the chat on screen, as rows of its own menu: they take no room while
    /// nobody needs them, and are offered only while the chat is quiet and has been spoken to.
    func nudgeRows() -> [(String, String?, @Sendable () -> Void)] {
        guard
            ChatNudge.offers(
                running: sendsBusy, hasTranscript: !(lastState?.messages.isEmpty ?? true))
        else { return [] }
        return ChatNudge.all.map { nudge in
            (
                nudge.title, nudge.hint,
                { [weak self] in Gtk.onMain { [weak self] in self?.sendNudge(nudge) } }
            )
        }
    }

    /// The words through this chat's ordinary send, echoed and queued like typed ones, leaving
    /// whatever is in the box where it is.
    func sendNudge(_ nudge: ChatNudge) {
        guard let conversation else { return }
        enqueueOrRun(
            QueuedSend(
                text: nudge.prompt, model: chosenModel,
                effort: ModelEffort.surviving(chosenEffort, options: effortOptions())),
            through: conversation)
    }
}
