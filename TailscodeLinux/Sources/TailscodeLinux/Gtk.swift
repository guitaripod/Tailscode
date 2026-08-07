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

    /// A signal GTK asks a question of rather than merely announces — `close-request` being the
    /// one that matters here. The handler answers "carry on", so watching a window close never
    /// changes whether it closes; a void closure would leave the answer to whatever happened to
    /// be in the return register.
    static func observe(
        _ instance: UnsafeMutableRawPointer, _ signal: String,
        _ handler: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback:
            @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = {
                _, raw in
                guard let raw else { return 0 }
                Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
                return 0
            }
        tailscode_connect(
            instance, signal, unsafeBitCast(callback, to: GCallback.self), box)
    }

    /// A plain click (release with nothing selected) on any widget. The shim owns the gesture;
    /// the box leaks by design, like every other signal closure here — rows live as long as the
    /// transcript does.
    static func onRelease(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
        }
        tailscode_on_release(widget, unsafeBitCast(callback, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self), box)
    }

    /// Any button pressed anywhere inside `widget`, children included, with where it landed —
    /// before the widget under the pointer acts on it. The event itself is untouched, which is how
    /// a window learns what was pressed without taking the press away from it.
    static func onPressCapture(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ handler: @escaping @Sendable (Double, Double) -> Void
    ) {
        let box = Unmanaged.passRetained(PointBox(handler)).toOpaque()
        let callback: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = {
            x, y, raw in
            guard let raw else { return }
            Unmanaged<PointBox>.fromOpaque(raw).takeUnretainedValue().handler(x, y)
        }
        tailscode_on_press_capture(widget, callback, box)
    }

    /// A double click on a paned's handle — the divider itself, never its children. Single
    /// clicks and drags pass through untouched, so the handle keeps its ordinary meaning.
    static func onPanedHandleDoubleClick(
        _ paned: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
        }
        tailscode_on_paned_handle_double_click(paned, callback, box)
    }

    /// A right click (or long-press equivalent the desktop maps to it) on any widget, with where
    /// it landed, so a context menu can open under the pointer rather than at a corner.
    static func onRightClick(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ handler: @escaping @Sendable (Double, Double) -> Void
    ) {
        let box = Unmanaged.passRetained(PointBox(handler)).toOpaque()
        let callback: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = {
            x, y, raw in
            guard let raw else { return }
            Unmanaged<PointBox>.fromOpaque(raw).takeUnretainedValue().handler(x, y)
        }
        tailscode_on_right_click(widget, callback, box)
    }

    final class PointBox: @unchecked Sendable {
        let handler: @Sendable (Double, Double) -> Void
        init(_ handler: @escaping @Sendable (Double, Double) -> Void) { self.handler = handler }
    }

    /// Runs `work` on the GLib main context after a delay — the timed cousin of ``onMain(_:)``.
    static func after(_ milliseconds: UInt32, _ work: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        tailscode_after(
            guint(milliseconds),
            { raw in
                guard let raw else { return }
                Unmanaged<Box>.fromOpaque(raw).takeRetainedValue().work()
            }, box)
    }

    /// Watches a GObject property — `notify::` carries a GParamSpec the plain trampoline cannot
    /// marshal, so it goes through its own. The handler runs on the GLib main context.
    static func onNotify(
        _ instance: UnsafeMutableRawPointer, property: String,
        _ handler: @escaping @Sendable () -> Void
    ) {
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        tailscode_connect_notify(
            instance, property,
            { raw in
                guard let raw else { return }
                Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
            }, box)
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
    static func markupLabel(_ markup: String, css: String? = nil, wrap: Bool = true)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let widget = gtk_label_new(nil)!
        let label: OpaquePointer = op(widget)
        gtk_label_set_markup(label, markup)
        gtk_label_set_xalign(label, 0)
        gtk_label_set_wrap(label, wrap ? 1 : 0)
        gtk_label_set_selectable(label, 1)
        if wrap { gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR) }
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

    /// Makes `widget` a chat the pointer can pick up and carry to a pane.
    static func makeChatDragSource(
        _ widget: UnsafeMutablePointer<GtkWidget>, payload: String
    ) {
        tailscode_make_chat_drag_source(widget, payload)
    }

    /// A dragged chat over `widget`, in the widget's own coordinates: where it is now, when it
    /// leaves, and what to do when it lands. `drop` answers whether the chat was taken.
    static func acceptChatDrops(
        on widget: UnsafeMutablePointer<GtkWidget>,
        motion: @escaping @Sendable (String?, Double, Double) -> Void,
        leave: @escaping @Sendable () -> Void,
        drop: @escaping @Sendable (String, Double, Double) -> Bool
    ) {
        let box = Unmanaged.passRetained(ChatDropBox(motion: motion, leave: leave, drop: drop))
            .toOpaque()
        let onMotion:
            @convention(c) (UnsafePointer<CChar>?, Double, Double, UnsafeMutableRawPointer?) -> Void = {
                payload, x, y, raw in
                guard let raw else { return }
                Unmanaged<ChatDropBox>.fromOpaque(raw).takeUnretainedValue()
                    .motion(payload.map { String(cString: $0) }, x, y)
            }
        let onLeave: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<ChatDropBox>.fromOpaque(raw).takeUnretainedValue().leave()
        }
        let onDrop:
            @convention(c) (UnsafePointer<CChar>?, Double, Double, UnsafeMutableRawPointer?) -> gboolean = {
                payload, x, y, raw in
                guard let raw, let payload else { return 0 }
                let box = Unmanaged<ChatDropBox>.fromOpaque(raw).takeUnretainedValue()
                return box.drop(String(cString: payload), x, y) ? 1 : 0
            }
        tailscode_accept_chat_drops(widget, onMotion, onLeave, onDrop, box)
    }

    final class ChatDropBox: @unchecked Sendable {
        let motion: @Sendable (String?, Double, Double) -> Void
        let leave: @Sendable () -> Void
        let drop: @Sendable (String, Double, Double) -> Bool

        init(
            motion: @escaping @Sendable (String?, Double, Double) -> Void,
            leave: @escaping @Sendable () -> Void,
            drop: @escaping @Sendable (String, Double, Double) -> Bool
        ) {
            self.motion = motion
            self.leave = leave
            self.drop = drop
        }
    }

    /// Where `widget` sits inside `ancestor`, or nil when the two are not connected.
    static func bounds(
        of widget: UnsafeMutablePointer<GtkWidget>, in ancestor: UnsafeMutablePointer<GtkWidget>
    ) -> (x: Double, y: Double, width: Double, height: Double)? {
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        guard tailscode_widget_bounds_in(widget, ancestor, &x, &y, &width, &height) != 0 else {
            return nil
        }
        return (x, y, width, height)
    }

    /// Whether a point in `ancestor`'s coordinates falls inside `widget` as it is drawn right now.
    /// A widget the window has not mapped — a hidden pane, a collapsed column — contains nothing.
    static func contains(
        _ widget: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double,
        in ancestor: UnsafeMutablePointer<GtkWidget>
    ) -> Bool {
        guard gtk_widget_get_mapped(widget) != 0, let box = bounds(of: widget, in: ancestor) else {
            return false
        }
        return x >= box.x && x < box.x + box.width && y >= box.y && y < box.y + box.height
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

    /// Detaches a widget from whatever holds it, through the parent's own API. A raw
    /// `gtk_widget_unparent` on a `GtkPaned`'s child leaves the paned's `start_child`/`end_child`
    /// pointer dangling; if anything (AT-SPI, an animation) keeps that paned alive past the
    /// rebuild, its eventual dispose unparents the widget from its *new* parent — a double
    /// release that finalizes a live pane and leaves the fresh paned measuring freed memory.
    static func detachFromParent(_ widget: UnsafeMutablePointer<GtkWidget>) {
        guard let parent = gtk_widget_get_parent(widget) else { return }
        let instance = UnsafeMutableRawPointer(parent)
            .assumingMemoryBound(to: GTypeInstance.self)
        if g_type_check_instance_is_a(instance, gtk_paned_get_type()) != 0 {
            if gtk_paned_get_start_child(op(parent)) == widget {
                gtk_paned_set_start_child(op(parent), nil)
            } else if gtk_paned_get_end_child(op(parent)) == widget {
                gtk_paned_set_end_child(op(parent), nil)
            } else {
                gtk_widget_unparent(widget)
            }
        } else if g_type_check_instance_is_a(instance, gtk_box_get_type()) != 0 {
            gtk_box_remove(ptr(parent), widget)
        } else {
            gtk_widget_unparent(widget)
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

    final class Slot: @unchecked Sendable {
        var bits: UInt = 0
    }

    /// A disclosure whose body does not exist until the first open. A transcript row that is
    /// collapsed — which is nearly every tool row — costs its header line and nothing else; the
    /// diff, the output, the subagent transcript are built the moment someone asks and kept after.
    static func disclosure(
        header: UnsafeMutablePointer<GtkWidget>,
        expanded: Bool,
        onToggle: @escaping @Sendable (Bool) -> Void,
        makeBody: @escaping @Sendable () -> UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let button = gtk_button_new()!
        addClass(button, "flat")
        addClass(button, "disclosure")
        gtk_button_set_child(ptr(button), header)
        gtk_box_append(ptr(column), button)
        let slot = Slot()
        if expanded {
            let body = makeBody()
            gtk_box_append(ptr(column), body)
            slot.bits = UInt(bitPattern: body)
        }
        let columnBits = UInt(bitPattern: column)
        connect(UnsafeMutableRawPointer(button), "clicked") {
            if slot.bits == 0 {
                guard let raw = UnsafeMutableRawPointer(bitPattern: columnBits) else { return }
                let body = makeBody()
                gtk_box_append(ptr(raw), body)
                slot.bits = UInt(bitPattern: body)
                onToggle(true)
                return
            }
            guard let raw = UnsafeMutableRawPointer(bitPattern: slot.bits) else { return }
            let body: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let showing = gtk_widget_get_visible(body) != 0
            gtk_widget_set_visible(body, showing ? 0 : 1)
            onToggle(!showing)
        }
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
        gtk_menu_button_set_can_shrink(op(button), 1)
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
                    let subtitle = label(detail, css: "row-detail", selectable: false)
                    gtk_label_set_max_width_chars(op(subtitle), 72)
                    gtk_box_append(ptr(lines), subtitle)
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

    /// A menu popped up at a point inside `widget` — the right-click cousin of ``menuButton``:
    /// the same row shape, built once for this opening, unparented again when it closes. The
    /// anchor must be a widget that outlives the menu, not a row a re-render may remove.
    static func contextMenu(
        on widget: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double,
        rows: [(title: String, detail: String?, action: @Sendable () -> Void)]
    ) {
        guard !rows.isEmpty else { return }
        let popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, widget)
        gtk_popover_set_has_arrow(ptr(popover), 0)
        var rect = GdkRectangle(x: gint(x), y: gint(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(ptr(popover), &rect)
        let popoverBits = UInt(bitPattern: popover)
        let column = box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        for row in rows {
            let item = gtk_button_new()!
            addClass(item, "flat")
            let lines = box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_box_append(ptr(lines), label(row.title, css: "row-title", selectable: false))
            if let detail = row.detail, !detail.isEmpty {
                let subtitle = label(detail, css: "row-detail", selectable: false)
                gtk_label_set_max_width_chars(op(subtitle), 56)
                gtk_box_append(ptr(lines), subtitle)
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
        gtk_popover_set_child(ptr(popover), column)
        connect(UnsafeMutableRawPointer(popover), "closed") {
            onMain {
                guard let raw = UnsafeMutableRawPointer(bitPattern: popoverBits),
                    gtk_widget_get_parent(ptr(raw)) != nil
                else { return }
                gtk_widget_unparent(ptr(raw))
            }
        }
        gtk_popover_popup(ptr(popover))
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
