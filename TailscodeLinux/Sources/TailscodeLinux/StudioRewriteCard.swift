import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The rewrite card: the paragraph a helper model is writing for the brief, who is writing it,
/// and the verbs — use these words, keep mine, write again, one line to change. It rises out of
/// the dock over the stage's lower third and takes no room, so the stage never moves for it, and
/// it is the same card for a picture and for a clip because it is the same draft.
final class StudioRewriteCard: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let head = Gtk.label("", css: "draw-rewrite-head", wrap: true, selectable: false)
    private let body = gtk_text_view_new()!
    private let instruction = gtk_entry_new()!
    private let verbs = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let use: UnsafeMutablePointer<GtkWidget>
    private let keep: UnsafeMutablePointer<GtkWidget>
    private let again: UnsafeMutablePointer<GtkWidget>
    private let stop: UnsafeMutablePointer<GtkWidget>
    private var shown = ""
    private var wasWriting = false

    var onUse: (@Sendable () -> Void)?
    var onKeep: (@Sendable () -> Void)?
    var onAgain: (@Sendable () -> Void)?
    var onStop: (@Sendable () -> Void)?
    var onRevise: (@Sendable (String) -> Void)?

    init() {
        use = Gtk.button(ImageGenRewriteWords.useTitle, css: ["draw-action", "draw-action-lead"], onClick: {})
        keep = Gtk.button(ImageGenRewriteWords.keepTitle, css: ["draw-action"], onClick: {})
        again = Gtk.button(ImageGenRewriteWords.againTitle, css: ["draw-action"], onClick: {})
        stop = Gtk.button(ImageGenRewriteWords.stopTitle, css: ["draw-action", "danger"], onClick: {})
        build()
    }

    private func build() {
        Gtk.addClass(root, "draw-rewrite")
        Gtk.addClass(root, "studio-rewrite")
        gtk_label_set_xalign(op(head), 0)
        gtk_label_set_max_width_chars(op(head), 64)
        gtk_box_append(ptr(root), head)
        gtk_text_view_set_editable(ptr(body), 0)
        gtk_text_view_set_cursor_visible(ptr(body), 0)
        gtk_text_view_set_wrap_mode(ptr(body), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_left_margin(ptr(body), 10)
        gtk_text_view_set_right_margin(ptr(body), 10)
        gtk_text_view_set_top_margin(ptr(body), 8)
        gtk_text_view_set_bottom_margin(ptr(body), 8)
        Gtk.addClass(body, "draw-rewrite-body")
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_height(op(scroller), 80)
        gtk_scrolled_window_set_max_content_height(op(scroller), 150)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), body)
        Gtk.addClass(scroller, "draw-rewrite-scroller")
        gtk_box_append(ptr(root), scroller)
        gtk_entry_set_placeholder_text(ptr(instruction), ImageGenRewriteWords.instructionPlaceholder)
        Gtk.addClass(instruction, "draw-avoid")
        gtk_widget_set_hexpand(instruction, 1)
        gtk_widget_set_tooltip_text(instruction, ImageGenRewriteWords.reviseTitle)
        gtk_box_append(ptr(root), instruction)
        gtk_widget_set_tooltip_text(use, ImageGenRewriteWords.useHint)
        gtk_widget_set_tooltip_text(keep, ImageGenRewriteWords.keepHint)
        gtk_widget_set_tooltip_text(again, ImageGenRewriteWords.againHint)
        for verb in [use, again, keep, stop] { gtk_box_append(ptr(verbs), verb) }
        gtk_widget_set_halign(verbs, GTK_ALIGN_START)
        gtk_box_append(ptr(root), verbs)
        Gtk.connect(UnsafeMutableRawPointer(use), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.onUse?() }
        }
        Gtk.connect(UnsafeMutableRawPointer(keep), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.onKeep?() }
        }
        Gtk.connect(UnsafeMutableRawPointer(again), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.onAgain?() }
        }
        Gtk.connect(UnsafeMutableRawPointer(stop), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.onStop?() }
        }
        Gtk.connect(UnsafeMutableRawPointer(instruction), "activate") { [weak self] in
            guard let self, let raw = gtk_editable_get_text(op(self.instruction)) else { return }
            let words = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return }
            gtk_editable_set_text(op(self.instruction), "")
            Gtk.onMain { [weak self] in self?.onRevise?(words) }
        }
    }

    /// The card follows the draft: hidden with none, writing with a Stop, landed with the three
    /// verbs and a line for what to change, failed with the reason and a way to try again. The
    /// paragraph is set only when it grew, and the view keeps its end in sight while it does.
    /// Answers whether the card is showing.
    @discardableResult
    func refresh(_ draft: ImageGenRewriteDraft?, canUse: Bool) -> Bool {
        guard let draft else {
            shown = ""
            return false
        }
        gtk_label_set_text(op(head), draft.headline)
        if case .failed = draft.phase {
            Gtk.addClass(head, "danger")
        } else {
            gtk_widget_remove_css_class(head, "danger")
        }
        let landedNow = !draft.isWriting && wasWriting
        wasWriting = draft.isWriting
        if draft.written != shown || landedNow {
            shown = draft.written
            let buffer = gtk_text_view_get_buffer(ptr(body))
            gtk_text_buffer_set_text(buffer, draft.written, -1)
            var edge = GtkTextIter()
            if draft.isWriting {
                gtk_text_buffer_get_end_iter(buffer, &edge)
            } else {
                gtk_text_buffer_get_start_iter(buffer, &edge)
            }
            let mark = gtk_text_buffer_create_mark(buffer, nil, &edge, 0)
            gtk_text_view_scroll_mark_onscreen(ptr(body), mark)
            gtk_text_buffer_delete_mark(buffer, mark)
        }
        let scroller = gtk_widget_get_parent(body)
        gtk_widget_set_visible(scroller, draft.written.isEmpty ? 0 : 1)
        gtk_widget_set_visible(stop, draft.isWriting ? 1 : 0)
        gtk_widget_set_visible(use, draft.isUsable ? 1 : 0)
        gtk_widget_set_visible(again, draft.isWriting ? 0 : 1)
        gtk_widget_set_visible(keep, draft.isWriting ? 0 : 1)
        gtk_widget_set_visible(instruction, draft.isUsable ? 1 : 0)
        gtk_widget_set_sensitive(use, canUse ? 1 : 0)
        return true
    }

    /// Whether the instruction line has the keyboard, so the board's own keys leave it alone.
    var hasFocus: Bool { gtk_widget_has_focus(instruction) != 0 }
}
