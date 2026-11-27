import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension ChatPane {
    /// Resume and Status? at the end of the box's line. They show only while the box is empty, so
    /// they never take typing room, and only while the chat is quiet, where a send goes now.
    func makeNudges() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(nudgeBox, "nudge-row")
        gtk_widget_set_valign(nudgeBox, GTK_ALIGN_START)
        gtk_widget_set_visible(nudgeBox, 0)
        for nudge in ChatNudge.all {
            let control = ChatChips.control(
                glyph: nudge.glyph, word: nudge.title.lowercased(), label: nudge.title
            ) { [weak self] in
                Gtk.onMain { [weak self] in self?.sendNudge(nudge) }
            }
            gtk_widget_set_tooltip_text(control.button, nudge.hint)
            gtk_widget_set_can_focus(control.button, 0)
            gtk_box_append(ptr(nudgeBox), control.button)
        }
        editor.onDictatingChanged = { [weak self] in self?.refreshNudges() }
        return nudgeBox
    }

    /// Shows the nudges exactly while Core offers them. Asked on every state a turn streams and on
    /// every key, so it touches the row only when the answer moves.
    func refreshNudges() {
        let shown = ChatNudge.offers(
            running: sendsBusy, holdsWords: composerHoldsWords,
            holdsAttachments: !attachments.isEmpty || carry != nil,
            editingQueued: editingQueued != nil, dictating: editor.dictating,
            hasTranscript: !(lastState?.messages.isEmpty ?? true))
        guard shown != nudgesShown else { return }
        nudgesShown = shown
        gtk_widget_set_visible(nudgeBox, shown ? 1 : 0)
    }

    /// The nudge's words, sent through the composer so they are echoed, drafted, queued and
    /// refused like typed ones.
    private func sendNudge(_ nudge: ChatNudge) {
        guard nudgesShown else { return }
        sendComposed(nudge.prompt)
        focusComposer()
    }
}
