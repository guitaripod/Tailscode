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

    static func addClass(_ widget: UnsafeMutablePointer<GtkWidget>, _ name: String) {
        gtk_widget_add_css_class(widget, name)
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
