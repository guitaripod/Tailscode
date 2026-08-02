import CAdw
import CGtkShim
import Foundation

/// The thin layer between Swift and GTK: signal connection, marshalling back onto the GLib main
/// context, and the casts every call needs. Everything above this file talks in Swift terms.
/// GTK's C types import as distinct pointer types, so every call up or down the widget hierarchy
/// needs a cast. One helper rather than a `unsafeBitCast` at each call site.
/// GTK declares most of its classes as incomplete C types, which Swift imports as
/// `OpaquePointer`, and a handful as complete structs, which it imports as typed pointers. Every
/// call up or down the hierarchy therefore needs one cast or the other.
@inline(__always)
func op(_ pointer: UnsafeMutableRawPointer) -> OpaquePointer {
    OpaquePointer(pointer)
}

@inline(__always)
func ptr<T>(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutablePointer<T> {
    pointer.assumingMemoryBound(to: T.self)
}

enum Gtk {
    /// Runs `work` on the GLib main context. GTK is not thread-safe and the agent engine runs on
    /// cooperative threads, so every UI touch that starts in a `Task` comes back through here.
    static func onMain(_ work: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        tailscode_on_main(
            { raw in
                guard let raw else { return }
                let box = Unmanaged<Box>.fromOpaque(raw).takeRetainedValue()
                box.work()
            }, box)
    }

    final class Box: @unchecked Sendable {
        let work: @Sendable () -> Void
        init(_ work: @escaping @Sendable () -> Void) { self.work = work }
    }

    /// Connects a signal to a Swift closure. The closure is retained for the life of the process,
    /// which is the right lifetime for a window's own controls and avoids a class of
    /// use-after-free that is much harder to see than a leak.
    static func connect(_ instance: UnsafeMutableRawPointer, _ signal: String, _ handler: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
            _, raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
        }
        tailscode_connect(
            instance, signal, unsafeBitCast(callback, to: GCallback.self), box)
    }

    /// Key presses on a widget, in the capture phase, so normal-mode letters never reach a text
    /// view that would otherwise swallow them.
    static func onKey(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ handler: @escaping @Sendable (UInt32, UInt32) -> Bool
    ) {
        let box = Unmanaged.passRetained(KeyBox(handler)).toOpaque()
        let callback: @convention(c) (guint, guint, UnsafeMutableRawPointer?) -> gboolean = {
            keyval, state, raw in
            guard let raw else { return 0 }
            let box = Unmanaged<KeyBox>.fromOpaque(raw).takeUnretainedValue()
            return box.handler(UInt32(keyval), UInt32(state)) ? 1 : 0
        }
        tailscode_connect_key(widget, callback, box)
    }

    final class KeyBox: @unchecked Sendable {
        let handler: @Sendable (UInt32, UInt32) -> Bool
        init(_ handler: @escaping @Sendable (UInt32, UInt32) -> Bool) { self.handler = handler }
    }

    /// Whether what has focus right now takes text. Insert mode is implied by focus rather than
    /// declared, so clicking into the composer and typing behaves the way a pointer user expects.
    static func focusTakesText(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        tailscode_focus_is_editable(widget) != 0
    }

    static func label(_ text: String, css: String? = nil, wrap: Bool = false, selectable: Bool = true)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let widget = gtk_label_new(text)!
        let label: OpaquePointer = op(widget)
        gtk_label_set_xalign(label, 0)
        gtk_label_set_wrap(label, wrap ? 1 : 0)
        gtk_label_set_selectable(label, selectable ? 1 : 0)
        if wrap { gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR) }
        gtk_label_set_ellipsize(label, wrap ? PANGO_ELLIPSIZE_NONE : PANGO_ELLIPSIZE_END)
        if let css { addClass(widget, css) }
        return widget
    }

    /// A label whose text is Pango markup rather than plain text — the transcript's prose, with the
    /// markdown resolved into emphasis instead of shown as punctuation.
    static func markupLabel(_ markup: String, css: String? = nil)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let widget = gtk_label_new(nil)!
        let label: OpaquePointer = op(widget)
        gtk_label_set_markup(label, markup)
        gtk_label_set_xalign(label, 0)
        gtk_label_set_wrap(label, 1)
        gtk_label_set_selectable(label, 1)
        gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR)
        gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_NONE)
        if let css { addClass(widget, css) }
        return widget
    }

    static func addClass(_ widget: UnsafeMutablePointer<GtkWidget>, _ name: String) {
        gtk_widget_add_css_class(widget, name)
    }

    /// Files dropped anywhere on `widget` arrive as absolute paths.
    static func acceptFileDrops(
        on widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping ([String]) -> Void
    ) {
        let box = Unmanaged.passRetained(PathListBox(handler)).toOpaque()
        let callback:
            @convention(c) (
                UnsafePointer<UnsafePointer<CChar>?>?, Int32, UnsafeMutableRawPointer?
            ) -> Void = { paths, count, raw in
                guard let raw else { return }
                let box = Unmanaged<PathListBox>.fromOpaque(raw).takeUnretainedValue()
                var result: [String] = []
                if let paths {
                    for index in 0..<Int(count) {
                        if let path = paths[index] { result.append(String(cString: path)) }
                    }
                }
                box.handler(result)
            }
        tailscode_accept_file_drops(widget, callback, box)
    }

    static func box(_ orientation: GtkOrientation, spacing: Int32) -> UnsafeMutablePointer<GtkWidget> {
        gtk_box_new(orientation, spacing)!
    }

    static func margins(_ widget: UnsafeMutablePointer<GtkWidget>, _ all: Int32) {
        margins(widget, top: all, bottom: all, leading: all, trailing: all)
    }

    static func margins(
        _ widget: UnsafeMutablePointer<GtkWidget>, top: Int32 = 0, bottom: Int32 = 0,
        leading: Int32 = 0, trailing: Int32 = 0
    ) {
        gtk_widget_set_margin_top(widget, top)
        gtk_widget_set_margin_bottom(widget, bottom)
        gtk_widget_set_margin_start(widget, leading)
        gtk_widget_set_margin_end(widget, trailing)
    }

    static func removeChildren(of parent: UnsafeMutablePointer<GtkWidget>) {
        while let child = gtk_widget_get_first_child(parent) {
            gtk_box_remove(ptr(parent), child)
        }
    }

    static func button(
        _ title: String, css: [String] = [], onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new_with_label(title)!
        for name in css { addClass(button, name) }
        connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        return button
    }

    static func copyToClipboard(_ text: String) {
        guard let display = gdk_display_get_default(),
            let clipboard = gdk_display_get_clipboard(display)
        else { return }
        gdk_clipboard_set_text(clipboard, text)
    }

    static func hairline() -> UnsafeMutablePointer<GtkWidget> {
        let rule = box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        addClass(rule, "turn-rule")
        gtk_widget_set_hexpand(rule, 1)
        return rule
    }

    /// A header you click to show or hide a body, with the state reported back so a re-render can
    /// restore it. GtkExpander's own toggle notifies through a three-argument signal the shim does
    /// not marshal; a plain button avoids the whole shape.
    static func disclosure(
        header: UnsafeMutablePointer<GtkWidget>,
        body: UnsafeMutablePointer<GtkWidget>,
        expanded: Bool,
        onToggle: @escaping @Sendable (Bool) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let button = gtk_button_new()!
        addClass(button, "flat")
        addClass(button, "disclosure")
        gtk_button_set_child(ptr(button), header)
        gtk_widget_set_visible(body, expanded ? 1 : 0)
        let bodyBits = UInt(bitPattern: body)
        connect(UnsafeMutableRawPointer(button), "clicked") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bodyBits) else { return }
            let body: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let showing = gtk_widget_get_visible(body) != 0
            gtk_widget_set_visible(body, showing ? 0 : 1)
            onToggle(!showing)
        }
        gtk_box_append(ptr(column), button)
        gtk_box_append(ptr(column), body)
        return column
    }

    /// A button that opens a popover of rows. One shape serves the actions menu, the model picker
    /// and the effort picker; the rows are built lazily on every open so they always reflect
    /// current state.
    static func menuButton(
        _ title: String, css: [String] = [],
        rows: @escaping @Sendable () -> [(title: String, detail: String?, action: @Sendable () -> Void)]
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_menu_button_new()!
        gtk_menu_button_set_label(op(button), title)
        for name in css { addClass(button, name) }
        let popover = gtk_popover_new()!
        gtk_menu_button_set_popover(op(button), popover)
        let popoverBits = UInt(bitPattern: popover)
        connect(UnsafeMutableRawPointer(popover), "map") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: popoverBits) else { return }
            let column = box(GTK_ORIENTATION_VERTICAL, spacing: 2)
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_max_content_height(op(scroller), 420)
            gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
            gtk_scrolled_window_set_propagate_natural_width(op(scroller), 1)
            for row in rows() {
                let item = gtk_button_new()!
                addClass(item, "flat")
                let lines = box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                gtk_box_append(ptr(lines), label(row.title, css: "row-title", selectable: false))
                if let detail = row.detail, !detail.isEmpty {
                    gtk_box_append(
                        ptr(lines), label(detail, css: "row-detail", selectable: false))
                }
                gtk_button_set_child(ptr(item), lines)
                let action = row.action
                connect(UnsafeMutableRawPointer(item), "clicked") {
                    guard let raw = UnsafeMutableRawPointer(bitPattern: popoverBits) else { return }
                    gtk_popover_popdown(ptr(raw))
                    action()
                }
                gtk_box_append(ptr(column), item)
            }
            gtk_scrolled_window_set_child(op(scroller), column)
            gtk_popover_set_child(ptr(raw), scroller)
        }
        return button
    }

    /// The app's own style. Chrome is left to libadwaita; this only sets the transcript's rhythm
    /// and the two type registers the design calls for.
    static func installStyle() {
        let css = """
            .transcript { background-color: @view_bg_color; }
            .prompt-rule { background-color: @accent_bg_color; min-width: 2px; }
            .agent-text { font-size: 1.0rem; }
            .tool-line { font-family: monospace; font-size: 0.9rem; }
            .dim { opacity: 0.55; }
            .status-line { font-family: monospace; font-size: 0.85rem; opacity: 0.7; }
            .sidebar-title { font-weight: 600; }
            .sidebar-detail { font-size: 0.85rem; opacity: 0.6; }
            """
        let provider = gtk_css_provider_new()
        gtk_css_provider_load_from_string(provider, css)
        if let display = gdk_display_get_default() {
            gtk_style_context_add_provider_for_display(
                display, op(provider!),
                guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        }
    }
}
