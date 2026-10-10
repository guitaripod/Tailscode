import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The brief dock: the one thing a person writes, and everything that shapes what comes back, in
/// two rows under the stage.
///
///     [start from]  [ words …                         ✦ Enhance ]  [ Generate ]
///     [ chip ] [ chip ] [ chip ] [ chip ] …                    about 1 min 20 s on arch
///
/// The words are the largest control on the page — two lines tall, growing to six, set in the
/// canvas face — with Enhance and the helper that would write beside them at the trailing edge;
/// Generate (or Stop, while a render is out) sits at the end of the row; the chips below are
/// Core's own list, wrapping rather than clipping; and what the render should cost is quiet text
/// at the foot. The dock is the image studio's and the forge's alike: each fills the same places
/// with its own decisions.
final class StudioDock: @unchecked Sendable {
    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    let slotHolder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let promptView = gtk_text_view_new()!
    let enhance: UnsafeMutablePointer<GtkWidget>
    let helper: UnsafeMutablePointer<GtkWidget>
    let go: UnsafeMutablePointer<GtkWidget>
    let tray: StudioChipTray
    private let foot = Gtk.label("", css: "studio-foot", selectable: false)
    private let placeholder = Gtk.label("", css: "studio-placeholder", wrap: true, selectable: false)
    private let wordsFrame = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let scroller: UnsafeMutablePointer<GtkWidget>
    private var typing = false
    private let trailingBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let firstRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
    private let actionsRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private var compact = false

    /// The words changed, typed by a person or put there by the studio.
    var onChange: (@Sendable () -> Void)?
    /// Return was pressed in the words box.
    var onSubmit: (@Sendable () -> Void)?

    init(helper: UnsafeMutablePointer<GtkWidget>) {
        self.helper = helper
        enhance = Gtk.button(ImageGenWords.enhanceTitle, css: ["draw-link", "studio-enhance"], onClick: {})
        go = Gtk.button("", css: ["draw-go", "studio-go"], onClick: {})
        scroller = Gtk.boundedScroller(promptView, minimum: 56, maximum: 156)
        tray = StudioChipTray(trailing: foot)
        build()
    }

    private func build() {
        Gtk.addClass(root, "studio-dock")
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_size_request(root, -1, -1)

        let first = firstRow
        gtk_widget_set_size_request(slotHolder, 56, 56)
        gtk_widget_set_valign(slotHolder, GTK_ALIGN_START)
        gtk_box_append(ptr(first), slotHolder)

        gtk_text_view_set_wrap_mode(ptr(promptView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(ptr(promptView), 0)
        gtk_text_view_set_top_margin(ptr(promptView), 10)
        gtk_text_view_set_bottom_margin(ptr(promptView), 10)
        gtk_text_view_set_left_margin(ptr(promptView), 14)
        gtk_text_view_set_right_margin(ptr(promptView), 8)
        Gtk.addClass(promptView, "studio-words")
        Gtk.addClass(wordsFrame, "draw-textarea")
        Gtk.addClass(wordsFrame, "studio-wordsbox")
        gtk_widget_set_hexpand(wordsFrame, 1)

        let overlay = gtk_overlay_new()!
        gtk_widget_set_hexpand(overlay, 1)
        gtk_overlay_set_child(op(overlay), scroller)
        gtk_label_set_xalign(op(placeholder), 0)
        gtk_label_set_max_width_chars(op(placeholder), 72)
        gtk_widget_set_halign(placeholder, GTK_ALIGN_START)
        gtk_widget_set_valign(placeholder, GTK_ALIGN_START)
        Gtk.margins(placeholder, top: 10, leading: 14, trailing: 8)
        gtk_widget_set_can_target(placeholder, 0)
        Gtk.setHidden(placeholder, true)
        gtk_overlay_add_overlay(op(overlay), placeholder)
        gtk_box_append(ptr(wordsFrame), overlay)

        let trailing = trailingBox
        gtk_widget_set_valign(trailing, GTK_ALIGN_END)
        Gtk.margins(trailing, bottom: 6, trailing: 10)
        gtk_widget_set_halign(enhance, GTK_ALIGN_END)
        gtk_widget_set_halign(helper, GTK_ALIGN_END)
        Gtk.addClass(helper, "draw-link")
        Gtk.addClass(helper, "draw-helper-link")
        gtk_menu_button_set_can_shrink(op(helper), 0)
        gtk_menu_button_set_always_show_arrow(op(helper), 1)
        gtk_box_append(ptr(trailing), enhance)
        gtk_box_append(ptr(trailing), helper)
        gtk_box_append(ptr(wordsFrame), trailing)
        gtk_box_append(ptr(first), wordsFrame)

        gtk_widget_set_valign(go, GTK_ALIGN_START)
        gtk_widget_set_size_request(go, 112, 40)
        gtk_box_append(ptr(first), go)
        gtk_box_append(ptr(root), first)
        gtk_widget_set_visible(actionsRow, 0)
        gtk_box_append(ptr(root), actionsRow)

        let second = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        gtk_box_append(ptr(second), tray.container)
        gtk_label_set_xalign(op(foot), 1)
        gtk_label_set_width_chars(op(foot), Self.footChars)
        gtk_label_set_max_width_chars(op(foot), Self.footChars)
        gtk_label_set_ellipsize(op(foot), PANGO_ELLIPSIZE_END)
        gtk_widget_set_halign(foot, GTK_ALIGN_END)
        gtk_widget_set_valign(foot, GTK_ALIGN_END)
        gtk_widget_set_hexpand(foot, 0)
        gtk_box_append(ptr(root), second)

        Gtk.connect(
            UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(promptView))!), "changed"
        ) { [weak self] in
            guard let self else { return }
            self.refreshPlaceholder()
            if !self.typing { self.onChange?() }
        }
        Gtk.onKey(promptView) { [weak self] keyval, state in
            guard keyval == Keymap.enter || keyval == Keymap.keypadEnter,
                state & KeyChord.shiftMask == 0
            else { return false }
            self?.onSubmit?()
            return true
        }
    }

    /// In a narrow pane the words keep the whole width of their row: Enhance, the helper that
    /// would write and Generate move to a row of their own beneath it, by reference. Nothing is
    /// rebuilt, so what is typed and what is open survives the pane being narrowed.
    func setCompact(_ narrow: Bool) {
        guard narrow != compact else { return }
        compact = narrow
        for widget in [trailingBox, go] {
            g_object_ref(UnsafeMutableRawPointer(widget))
            if let parent = gtk_widget_get_parent(widget) { gtk_box_remove(ptr(parent), widget) }
        }
        gtk_widget_set_visible(actionsRow, narrow ? 1 : 0)
        gtk_menu_button_set_can_shrink(op(helper), narrow ? 1 : 0)
        if narrow {
            gtk_orientable_set_orientation(op(trailingBox), GTK_ORIENTATION_HORIZONTAL)
            gtk_box_set_spacing(ptr(trailingBox), 8)
            gtk_widget_set_valign(trailingBox, GTK_ALIGN_CENTER)
            gtk_widget_set_hexpand(trailingBox, 1)
            Gtk.margins(trailingBox)
            gtk_widget_set_halign(enhance, GTK_ALIGN_START)
            gtk_widget_set_halign(helper, GTK_ALIGN_START)
            gtk_widget_set_valign(go, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(actionsRow), trailingBox)
            gtk_box_append(ptr(actionsRow), go)
        } else {
            gtk_orientable_set_orientation(op(trailingBox), GTK_ORIENTATION_VERTICAL)
            gtk_box_set_spacing(ptr(trailingBox), 0)
            gtk_widget_set_valign(trailingBox, GTK_ALIGN_END)
            gtk_widget_set_hexpand(trailingBox, 0)
            Gtk.margins(trailingBox, bottom: 6, trailing: 10)
            gtk_widget_set_halign(enhance, GTK_ALIGN_END)
            gtk_widget_set_halign(helper, GTK_ALIGN_END)
            gtk_widget_set_valign(go, GTK_ALIGN_START)
            gtk_box_append(ptr(wordsFrame), trailingBox)
            gtk_box_append(ptr(firstRow), go)
        }
        g_object_unref(UnsafeMutableRawPointer(trailingBox))
        g_object_unref(UnsafeMutableRawPointer(go))
    }

    /// The words, wherever they came from. Writing them is not an edit, so it does not tell the
    /// owner a person typed.
    var words: String {
        get {
            let buffer = gtk_text_view_get_buffer(ptr(promptView))
            var start = GtkTextIter()
            var end = GtkTextIter()
            gtk_text_buffer_get_bounds(buffer, &start, &end)
            guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
            defer { g_free(raw) }
            return String(cString: raw)
        }
        set {
            guard newValue != words else { return }
            typing = true
            gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(promptView)), newValue, -1)
            typing = false
            refreshPlaceholder()
        }
    }

    /// Puts the caret at the end of the words, which is where somebody about to add to them
    /// expects to be.
    func placeCaretAtEnd() {
        let buffer = gtk_text_view_get_buffer(ptr(promptView))
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_place_cursor(buffer, &end)
    }

    func setPlaceholder(_ text: String) {
        gtk_label_set_text(op(placeholder), text)
        refreshPlaceholder()
    }

    private func refreshPlaceholder() {
        gtk_widget_set_visible(placeholder, words.isEmpty ? 1 : 0)
    }

    /// What the render should cost, as quiet text at the foot — or nothing, when nothing has been
    /// learned yet to say it from.
    func setFoot(_ text: String?, tooltip: String? = nil) {
        gtk_label_set_text(op(foot), text ?? "")
        gtk_widget_set_tooltip_text(foot, tooltip ?? text)
    }

    /// The foot keeps its width whether it has anything to say or not, so the chips break their
    /// lines in the same places before the first render, during one and after it — a render
    /// landing may not move a thing on the page.
    static let footChars: Int32 = 30

    /// Generate, or Stop while a render is out: the same control, saying which it is.
    func setGo(title: String, stopping: Bool, enabled: Bool = true) {
        gtk_button_set_label(ptr(go), title)
        if stopping {
            Gtk.addClass(go, "stopping")
        } else {
            gtk_widget_remove_css_class(go, "stopping")
        }
        gtk_widget_set_sensitive(go, enabled ? 1 : 0)
    }

    private var surveyShown: Date?

    /// The one control that writes words rather than choosing a value, so it says which model will
    /// write them and never runs on its own: press once to have the brief written out, press again
    /// while it writes to stop it, and press once more after taking it to get your own sentence
    /// back. The link beside it names who would write — the helper, or where the survey stands.
    func showEnhance(host: HelperHost, enhancing: Bool, canUndo: Bool, locked: Bool) {
        let helper = host.helper
        gtk_button_set_label(
            ptr(enhance),
            "✦ " + (enhancing ? ImageGenWords.enhancingTitle
                : (canUndo ? ImageGenWords.undoTitle : ImageGenWords.enhanceTitle)))
        gtk_widget_set_tooltip_text(
            enhance,
            enhancing ? ImageGenRewriteWords.stopTitle
                : helper.map(ImageGenWords.enhanceHint) ?? ImageGenWords.enhanceLookingHint)
        gtk_widget_set_sensitive(enhance, enhancing || !locked ? 1 : 0)
        let name: String
        if let helper {
            name = helper.enabled ? helper.chip : "\(helper.chip) · \(ImageGenWords.offMark)"
        } else if host.surveying {
            name = ImageGenRewriteWords.lookingTitle
        } else {
            name = ImageGenRewriteWords.chooseTitle
        }
        gtk_menu_button_set_label(op(self.helper), ImageGenRewriteWords.withLine(name))
        gtk_widget_set_tooltip_text(self.helper, HelperMenu.tooltip(host))
        reopenHelperMenuIfSurveyLanded(host)
    }

    /// A menu opened before the survey came back was a "Looking…" row; when the answer lands while
    /// it is still open, it is rebuilt in place rather than left to be closed and opened.
    private func reopenHelperMenuIfSurveyLanded(_ host: HelperHost) {
        guard let landed = host.surveyedAt, landed != surveyShown else { return }
        surveyShown = landed
        guard let popover = gtk_menu_button_get_popover(op(helper)),
            gtk_widget_get_mapped(UnsafeMutableRawPointer(popover).assumingMemoryBound(to: GtkWidget.self)) != 0
        else { return }
        gtk_menu_button_popdown(op(helper))
        gtk_menu_button_popup(op(helper))
    }

    /// The words and the chips are read-only while a render is out: what the render was made from
    /// is what is on screen, and an edit would be an edit of nothing.
    func setLocked(_ locked: Bool) {
        gtk_text_view_set_editable(ptr(promptView), locked ? 0 : 1)
        if locked {
            Gtk.addClass(wordsFrame, "studio-locked")
        } else {
            gtk_widget_remove_css_class(wordsFrame, "studio-locked")
        }
    }

    func focus() {
        gtk_widget_grab_focus(promptView)
    }

    var hasFocus: Bool { gtk_widget_has_focus(promptView) != 0 }

    /// The dock's own height, which the stage reserves rather than runs under.
    var height: Double { Double(gtk_widget_get_height(root)) }
}
