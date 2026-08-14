import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The prompt box, as one thing rather than as a habit each surface repeats. A question typed to
/// start a conversation and a question typed inside one are the same act, so they are the same
/// widget: a text view that is as tall as what is in it and stops at the height the settings
/// window sets, wrapping instead of scrolling sideways, wearing the composer's own type, carrying
/// the vim engine that shadows it, the ultracode aura that says the powers are on, and the
/// placeholder that says what the box is for.
///
/// It owns composition and nothing else — where the words go, what may ride with them and which
/// keys mean send are the surface's to decide, because a chat has a conversation to send into and
/// a quick ask has a machine to mint one on.
final class PromptEditor: @unchecked Sendable {
    let textView = gtk_text_view_new()!
    let scroller = gtk_scrolled_window_new()!
    let widget: UnsafeMutablePointer<GtkWidget>
    let vim = VimEngine()

    private let placeholder: UnsafeMutablePointer<GtkWidget>
    private let aura = AuraPainter()
    private var modeFrame: UnsafeMutablePointer<GtkWidget>
    private var height: Int32 = 0
    private var measuring = false

    var onChanged: (@Sendable () -> Void)?
    /// Fired when the box actually took a new height. A surface whose window is sized to its
    /// contents has to ask for that size again, or the box grows inside a window that did not.
    var onHeightChanged: (@Sendable () -> Void)?

    init(css: String, placeholder text: String) {
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_text_view_set_wrap_mode(ptr(textView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_monospace(ptr(textView), 1)
        gtk_text_view_set_top_margin(ptr(textView), 8)
        gtk_text_view_set_left_margin(ptr(textView), 10)
        gtk_text_view_set_right_margin(ptr(textView), 10)
        gtk_scrolled_window_set_child(op(scroller), textView)
        Gtk.addClass(scroller, css)
        modeFrame = scroller

        placeholder = Gtk.label(text, css: "composer-placeholder", selectable: false)
        gtk_widget_set_can_target(placeholder, 0)
        gtk_widget_set_halign(placeholder, GTK_ALIGN_START)
        gtk_widget_set_valign(placeholder, GTK_ALIGN_START)
        Gtk.margins(placeholder, top: 8, leading: 11, trailing: 10)

        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), scroller)
        gtk_overlay_add_overlay(op(overlay), placeholder)
        gtk_overlay_add_overlay(op(overlay), aura.widget)
        gtk_widget_set_hexpand(overlay, 1)
        widget = overlay

        Gtk.connect(
            UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(textView))), "changed"
        ) { [weak self] in
            guard let self else { return }
            self.grow()
            self.refreshPlaceholder()
            self.onChanged?()
        }
    }

    /// Which widget wears the vim mode. The chat's box is its own frame; a surface that draws a
    /// frame around the editor and its buttons hands that frame over instead, so the mode is worn
    /// by the thing a person reads as the box.
    func carryModeOn(_ widget: UnsafeMutablePointer<GtkWidget>) {
        gtk_widget_remove_css_class(modeFrame, "composer-normal")
        gtk_widget_remove_css_class(modeFrame, "composer-visual")
        modeFrame = widget
    }

    var text: String {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    var cursor: Int {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &iter, gtk_text_buffer_get_insert(buffer))
        return Int(gtk_text_iter_get_offset(&iter))
    }

    func setText(_ text: String, caretAtEnd: Bool = true) {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        gtk_text_buffer_set_text(buffer, text, -1)
        guard caretAtEnd else { return }
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_place_cursor(buffer, &end)
    }

    func insertAtEnd(_ text: String) {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_insert(buffer, &end, text, -1)
        focus()
    }

    /// Where a paste actually lands, which is at the caret and never at the end: the box is a
    /// document a person moves around in, and vim's shadow of it has to be told what was written
    /// or the next normal-mode key would edit a string that no longer exists.
    func insertAtCaret(_ text: String) {
        gtk_text_buffer_insert_at_cursor(gtk_text_view_get_buffer(ptr(textView)), text, -1)
        focus()
        vim.reset(to: self.text, cursor: cursor, mode: vim.mode)
    }

    func write(_ document: VimDocument, selection: Range<Int>?) {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        if text != document.text {
            gtk_text_buffer_set_text(buffer, document.text, -1)
        }
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &caret, Int32(document.cursor))
        if let selection {
            var start = GtkTextIter()
            var end = GtkTextIter()
            gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(selection.lowerBound))
            gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(selection.upperBound))
            gtk_text_buffer_select_range(buffer, &end, &start)
        } else {
            gtk_text_buffer_place_cursor(buffer, &caret)
        }
        gtk_text_view_scroll_to_mark(
            ptr(textView), gtk_text_buffer_get_insert(buffer), 0, 0, 0, 0)
    }

    func selection() -> String? {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        guard gtk_text_buffer_get_selection_bounds(buffer, &start, &end) != 0,
            let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0)
        else { return nil }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    func clear() {
        setText("")
        vim.reset(to: "", cursor: 0, mode: .insert)
        refreshMode()
    }

    func focus() {
        gtk_widget_grab_focus(textView)
    }

    func hasFocus(in window: UnsafeMutablePointer<GtkWidget>?) -> Bool {
        guard let window, let focused = tailscode_focused_widget(window) else { return false }
        return focused == textView
    }

    func setSensitive(_ sensitive: Bool) {
        gtk_widget_set_sensitive(textView, sensitive ? 1 : 0)
    }

    /// Alongside any badge a surface keeps, the caret itself says which mode this is: it blinks
    /// only in insert, because letters belong to commands everywhere else and a blinking beam
    /// would promise typing the box will not do.
    func refreshMode() {
        gtk_widget_remove_css_class(modeFrame, "composer-normal")
        gtk_widget_remove_css_class(modeFrame, "composer-visual")
        guard Preferences.vimComposer else {
            gtk_text_view_set_cursor_visible(ptr(textView), 1)
            return
        }
        gtk_text_view_set_cursor_visible(ptr(textView), vim.mode == .insert ? 1 : 0)
        switch vim.mode {
        case .normal: Gtk.addClass(modeFrame, "composer-normal")
        case .visual, .visualLine: Gtk.addClass(modeFrame, "composer-visual")
        case .insert: break
        }
    }

    /// The settings changed underneath a live box: switching vim off must leave normal mode, so
    /// no draft ends up trapped behind a hidden caret, and a new ceiling re-measures the height.
    func applyPreferences() {
        if !Preferences.vimComposer, vim.mode != .insert {
            vim.reset(to: text, cursor: cursor, mode: .insert)
        }
        refreshMode()
        height = 0
        grow()
    }

    var auraActive: Bool { aura.isActive }

    func setAura(effort: String?, inFlight: Bool) {
        aura.setActive(
            Ultracode.auraActive(effort: effort, draft: text, inFlightInvoked: inFlight))
    }

    /// Puts the light out whatever the draft says — for a surface that is being let go of, where
    /// the words are about to stop being anybody's.
    func stopAura() {
        aura.setActive(false)
    }

    /// The box is as tall as what is in it, and it stops growing at the height the settings
    /// window sets. Measured on the next idle, never inline: a view that was just emptied still
    /// reports the height it had until the next layout.
    func grow() {
        guard !measuring else { return }
        measuring = true
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.measuring = false
            self.measure()
        }
    }

    private func measure() {
        let line = 20.0 * Preferences.scale(.mono)
        let ceiling = Int32(line * Double(Preferences.composerLines) + 18)
        let floor = Int32(line + 18)
        var minimum: Int32 = 0
        var natural: Int32 = 0
        let width = gtk_widget_get_width(textView)
        gtk_widget_measure(
            textView, GTK_ORIENTATION_VERTICAL, width > 0 ? width : -1, &minimum, &natural,
            nil, nil)
        let wanted = text.isEmpty ? floor : max(floor, min(ceiling, natural + 18))
        guard wanted != height else { return }
        height = wanted
        gtk_widget_set_size_request(scroller, -1, wanted)
        onHeightChanged?()
    }

    private func refreshPlaceholder() {
        gtk_widget_set_visible(placeholder, text.isEmpty ? 1 : 0)
    }
}
