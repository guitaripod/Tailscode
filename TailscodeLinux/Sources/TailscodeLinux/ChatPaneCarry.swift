import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension ChatPane {
    /// Puts what a move brings along into this pane's composer: the chip for the brief and, for a
    /// retry, the question in the field, unsent. Called by the window once the new chat is open,
    /// because opening a chat empties the composer.
    func adoptCarry(_ plan: CarryPlan) {
        carry = plan.brief
        renderAttachments()
        if let draft = plan.draft {
            fillComposer(with: draft)
        }
        focusComposer()
    }

    /// The name the carried conversation goes by, which is the one the chat list shows for it.
    var carrySourceTitle: String {
        guard let entry else { return "" }
        return SessionRowModel(entry: entry, unreachable: false, unread: false, saved: false).title
    }

    /// A pick of a model on another machine from this chat. A conversation with something to carry
    /// is never moved without saying so; one with nothing to carry keeps the words it always had.
    func continueElsewhere(_ pick: ModelPick, beforeMoving: @escaping @Sendable () -> Void = {}) {
        let plan = CarryPlan.continuing(
            pick: pick, title: carrySourceTitle, messages: lastState?.messages ?? [])
        guard plan.brief != nil else {
            ModelFleet.adopt(pick)
            beforeMoving()
            host?.startChat(on: pick.profileID, into: self)
            return
        }
        let words = plan.moveWords(for: pick)
        Dialogs.confirm(
            title: words.title, body: words.body, confirmLabel: words.action, destructive: false,
            parent: host?.windowWidget
        ) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                ModelFleet.adopt(pick)
                beforeMoving()
                self.host?.startChat(on: pick.profileID, into: self, carrying: plan)
            }
        }
    }

    /// The hover bar's "Try with another model…": the chooser, in the context that says every pick
    /// branches this chat from the question the answer was given to.
    func tryWithAnotherModel(answerID: String) {
        ModelChooserWindow.present(
            sources: modelSources(), selected: chosenModel,
            parent: host?.windowWidget ?? root, quotas: modelQuotas(), context: .branch,
            onRefresh: { [weak self] in self?.refreshModelCatalog() }
        ) { [weak self] pick in
            Gtk.onMain { [weak self] in self?.branch(from: answerID, pick: pick) }
        }
    }

    /// A new chat on the pick's machine, whose composer holds the question again and, when
    /// anything came before it, the brief of that. The chat this was made from is left as it is.
    func branch(from answerID: String, pick: ModelPick) {
        let plan = CarryPlan.branching(
            pick: pick, title: carrySourceTitle, messages: lastState?.messages ?? [],
            answerID: answerID)
        ModelFleet.adopt(pick)
        host?.startChat(
            on: pick.profileID, into: self, carrying: plan.draft == nil ? nil : plan)
    }

    /// Whether an answer can be tried again elsewhere: it is finished and there is a question to
    /// put back in the field.
    func offersBranch(_ message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        guard message.role == .assistant, !message.isStreaming else { return false }
        return ConversationBrief.question(before: message.id, in: messages)
            .flatMap(ConversationBrief.typed) != nil
    }

    func fillComposer(with text: String) {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), text, -1)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        updateVimBadge()
    }

    /// The one chip a carrying composer wears beside the attachments: the arrow, where the
    /// conversation is from, and the control that makes this a fresh chat instead. It wraps rather
    /// than truncating, because the name is the person's own.
    func carryChip(_ brief: ConversationBrief) -> UnsafeMutablePointer<GtkWidget> {
        let chip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(chip, "carry-chip")
        gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
        let glyph = Gtk.label("↩", css: "chip-glyph", selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        let text = Gtk.label(brief.chip, css: "carry-chip-text", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(text), 48)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        let fresh = Localized.text("Start a fresh chat instead")
        let clear = Gtk.button("✕", css: ["flat", "carry-chip-clear"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.clearCarry() }
        }
        gtk_widget_set_valign(clear, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(clear, fresh)
        tailscode_set_accessible_label(clear, fresh)
        gtk_box_append(ptr(chip), glyph)
        gtk_box_append(ptr(chip), text)
        gtk_box_append(ptr(chip), clear)
        gtk_widget_set_margin_end(chip, 6)
        return chip
    }

    func clearCarry() {
        carry = nil
        renderAttachments()
        focusComposer()
    }
}
