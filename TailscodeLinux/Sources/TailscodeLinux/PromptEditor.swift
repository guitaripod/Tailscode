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
    let edge = ListeningEdge()
    private var restingPlaceholder: String
    private var writingDictation = false
    private(set) var dictating = false
    private var modeFrame: UnsafeMutablePointer<GtkWidget>
    private var height: Int32 = 0
    private var measuring = false
    private var footer: UnsafeMutablePointer<GtkWidget>?
    private var footerRoom = 0.0
    private var footerTarget = 0.0
    private var footerStepping = false

    var onChanged: (@Sendable () -> Void)?
    /// The person changed the box with their own hands while a take was writing into it.
    var onEditDuringDictation: (@Sendable () -> Void)?
    /// The person changed the box with their own hands while no take was writing into it.
    var onEditOutsideDictation: (@Sendable () -> Void)?
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

        restingPlaceholder = text
        placeholder = Gtk.label(text, css: "composer-placeholder", selectable: false)
        gtk_widget_set_can_target(placeholder, 0)
        gtk_widget_set_halign(placeholder, GTK_ALIGN_START)
        gtk_widget_set_valign(placeholder, GTK_ALIGN_START)
        Gtk.margins(placeholder, top: 8, leading: 11, trailing: 10)

        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), scroller)
        gtk_overlay_add_overlay(op(overlay), placeholder)
        gtk_overlay_add_overlay(op(overlay), aura.widget)
        gtk_overlay_add_overlay(op(overlay), edge.widget)
        gtk_widget_set_hexpand(overlay, 1)
        widget = overlay

        Gtk.connect(
            UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(textView))), "changed"
        ) { [weak self] in
            guard let self else { return }
            self.grow()
            self.refreshPlaceholder()
            if !self.writingDictation {
                if self.dictating { self.onEditDuringDictation?() } else { self.onEditOutsideDictation?() }
            }
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

    /// Which overlay wears the ultracode aura. The light belongs on the edge a person reads as the
    /// box, so a surface that frames the editor together with its buttons hands that frame's
    /// overlay over, and the ring goes around all of it instead of drawing a second box inside.
    func wearAura(on overlay: UnsafeMutablePointer<GtkWidget>) {
        for ring in [aura.widget, edge.widget] {
            g_object_ref(UnsafeMutableRawPointer(ring))
            gtk_overlay_remove_overlay(op(widget), ring)
            gtk_overlay_add_overlay(op(overlay), ring)
            g_object_unref(UnsafeMutableRawPointer(ring))
        }
    }

    /// The box's last line: what a take says about itself, inside the box under the words rather
    /// than a label outside it. It crossfades in and out, and the text keeps clear of it by the
    /// line's height while it shows, so the caret and the last words are never under it.
    func mountFooter(_ content: UnsafeMutablePointer<GtkWidget>) {
        guard footer == nil else { return }
        let revealer = gtk_revealer_new()!
        gtk_revealer_set_transition_type(op(revealer), GTK_REVEALER_TRANSITION_TYPE_CROSSFADE)
        gtk_revealer_set_transition_duration(op(revealer), Gtk.animationsAllowed ? 200 : 0)
        gtk_revealer_set_child(op(revealer), content)
        gtk_widget_set_halign(revealer, GTK_ALIGN_END)
        gtk_widget_set_valign(revealer, GTK_ALIGN_END)
        gtk_overlay_add_overlay(op(widget), revealer)
        footer = revealer
    }

    var footerShown: Bool {
        guard let footer else { return false }
        return gtk_revealer_get_reveal_child(op(footer)) != 0
    }

    func setFooterShown(_ shown: Bool) {
        guard let footer, footerShown != shown else { return }
        gtk_revealer_set_reveal_child(op(footer), shown ? 1 : 0)
        footerTarget = shown ? Self.footerLine : 0
        stepFooterRoom()
    }

    private static var footerLine: Double { 22 * Preferences.scale(.chrome) }

    /// Moves the room kept under the words toward its target a frame at a time, so the box grows
    /// and shrinks with the line rather than jumping.
    private func stepFooterRoom() {
        guard !footerStepping else { return }
        let gap = footerTarget - footerRoom
        guard abs(gap) > 0.5, Gtk.animationsAllowed else {
            footerRoom = footerTarget
            applyFooterRoom()
            return
        }
        footerRoom += gap * 0.32
        applyFooterRoom()
        footerStepping = true
        Gtk.after(16) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.footerStepping = false
                self.stepFooterRoom()
            }
        }
    }

    private func applyFooterRoom() {
        gtk_text_view_set_bottom_margin(ptr(textView), Int32(footerRoom.rounded()))
        measure()
    }

    /// Where a take's words would go: the text before the selection and the text after it.
    func dictationAnchor() -> DictationInsertion {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        if gtk_text_buffer_get_selection_bounds(buffer, &start, &end) == 0 {
            gtk_text_buffer_get_iter_at_mark(buffer, &start, gtk_text_buffer_get_insert(buffer))
            end = start
        }
        var first = GtkTextIter()
        var last = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &first, &last)
        return DictationInsertion(before: slice(buffer, &first, &start), after: slice(buffer, &end, &last))
    }

    private func slice(
        _ buffer: UnsafeMutablePointer<GtkTextBuffer>?, _ from: inout GtkTextIter, _ to: inout GtkTextIter
    ) -> String {
        guard let raw = gtk_text_buffer_get_text(buffer, &from, &to, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    /// Opens or closes the box to a take: the placeholder says it is listening, and the words the
    /// take writes from here on are its own and not the person's typing.
    func setDictating(_ value: Bool) {
        dictating = value
        gtk_label_set_text(op(placeholder), value ? DictationReading.listeningPlaceholder : restingPlaceholder)
        if !value { tailscode_text_tag_span(textView, Self.heardTag, 0, 0) }
        if !value { tailscode_text_tag_span(textView, Self.struckTag, 0, 0) }
    }

    static let heardTag = "dictation-heard"
    static let struckTag = "dictation-struck"

    /// The box with a take in it, written outside the undo history: only the take's last state
    /// becomes one undo step, in `commitDictation`.
    func showDictation(_ composition: DictationComposition, struck: Bool) {
        let palette = MatrixTheme.palette
        let accent = PartyInk(hex: palette.accent)
        let dim = PartyInk(hex: palette.textDim)
        tailscode_text_tag_style(textView, Self.heardTag, accent.red, accent.green, accent.blue, 0.9, 0)
        tailscode_text_tag_style(textView, Self.struckTag, dim.red, dim.green, dim.blue, 0.8, 1)
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        writingDictation = true
        gtk_text_buffer_begin_irreversible_action(buffer)
        if text != composition.text { gtk_text_buffer_set_text(buffer, composition.text, -1) }
        gtk_text_buffer_end_irreversible_action(buffer)
        writingDictation = false
        let heard = composition.heardScalars
        tailscode_text_tag_span(textView, Self.heardTag, Int32(heard.lowerBound), Int32(heard.upperBound))
        let take = composition.takeScalars
        tailscode_text_tag_span(
            textView, Self.struckTag, struck ? Int32(take.lowerBound) : 0, struck ? Int32(take.upperBound) : 0)
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &caret, Int32(composition.caretScalars))
        gtk_text_buffer_place_cursor(buffer, &caret)
        gtk_text_view_scroll_to_mark(ptr(textView), gtk_text_buffer_get_insert(buffer), 0, 0, 0, 0)
    }

    /// The take's last words, written as one undo step from the box as it was before the take.
    func commitDictation(_ composition: DictationComposition, from original: String) {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        writingDictation = true
        gtk_text_buffer_begin_irreversible_action(buffer)
        gtk_text_buffer_set_text(buffer, original, -1)
        gtk_text_buffer_end_irreversible_action(buffer)
        if composition.text != original {
            gtk_text_buffer_begin_user_action(buffer)
            var start = GtkTextIter()
            var end = GtkTextIter()
            gtk_text_buffer_get_bounds(buffer, &start, &end)
            gtk_text_buffer_delete(buffer, &start, &end)
            gtk_text_buffer_get_start_iter(buffer, &start)
            gtk_text_buffer_insert(buffer, &start, composition.text, -1)
            gtk_text_buffer_end_user_action(buffer)
        }
        writingDictation = false
        setDictating(false)
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &caret, Int32(composition.caretScalars))
        gtk_text_buffer_place_cursor(buffer, &caret)
        vim.reset(to: text, cursor: cursor, mode: vim.mode)
    }

    /// The box exactly as it was before a take that was thrown away.
    func restoreDictation(_ original: String, caret: Int) {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        writingDictation = true
        gtk_text_buffer_begin_irreversible_action(buffer)
        gtk_text_buffer_set_text(buffer, original, -1)
        gtk_text_buffer_end_irreversible_action(buffer)
        writingDictation = false
        setDictating(false)
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, Int32(caret))
        gtk_text_buffer_place_cursor(buffer, &iter)
        vim.reset(to: text, cursor: cursor, mode: vim.mode)
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

    /// Puts the caret at a character offset, for words written with a place left for the person.
    func placeCaret(at offset: Int) {
        let buffer = gtk_text_view_get_buffer(ptr(textView))
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, gint(offset))
        gtk_text_buffer_place_cursor(buffer, &iter)
        vim.reset(to: text, cursor: cursor, mode: vim.mode)
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
        settleAfterLayout()
    }

    /// A text view validates the lines of a document written whole in its own idle passes, and
    /// until they are validated it reports the height of the lines it has already laid out. Words
    /// arriving a keystroke at a time are measured again by the next keystroke; a document set in
    /// one write (a starter, an errand with the clipboard under it, a restored draft) has no next
    /// keystroke, so the box is measured once more after the view has laid the document out.
    private func settleAfterLayout() {
        Gtk.after(80) { [weak self] in
            Gtk.onMain { [weak self] in self?.measure() }
        }
    }

    private func measure() {
        let line = 20.0 * Preferences.scale(.mono)
        let room = Int32(footerRoom.rounded())
        let ceiling = Int32(line * Double(Preferences.composerLines) + 18) + room
        let floor = Int32(line + 18) + room
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
