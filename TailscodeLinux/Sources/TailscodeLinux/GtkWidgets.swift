import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension Gtk {
    /// A text view that grows with what is typed up to a ceiling and scrolls past it, so a long
    /// paragraph never pushes the window taller than the screen.
    static func boundedScroller(
        _ child: UnsafeMutablePointer<GtkWidget>, minimum: Int32, maximum: Int32
    ) -> UnsafeMutablePointer<GtkWidget> {
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_min_content_height(op(scroller), minimum)
        gtk_scrolled_window_set_max_content_height(op(scroller), maximum)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), child)
        gtk_widget_set_hexpand(scroller, 1)
        return scroller
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
    /// markdown resolved into emphasis instead of shown as punctuation. It is a reveal label: any
    /// prose row can become the one the agent is writing into, and until one does it draws exactly
    /// as a `GtkLabel` does.
    static func markupLabel(_ markup: String, css: String? = nil, wrap: Bool = true)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let widget = tailscode_reveal_label_new()!
        let label: OpaquePointer = op(widget)
        gtk_label_set_markup(label, markup)
        gtk_label_set_xalign(label, 0)
        gtk_label_set_wrap(label, wrap ? 1 : 0)
        gtk_label_set_selectable(label, 1)
        if wrap { gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR) }
        gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_NONE)
        tailscode_label_open_links(widget)
        if let css { addClass(widget, css) }
        return widget
    }

    static func addClass(_ widget: UnsafeMutablePointer<GtkWidget>, _ name: String) {
        gtk_widget_add_css_class(widget, name)
    }

    /// The one class out of a set of mutually exclusive tones, applied by taking the others off
    /// first — a widget that reports a changing state keeps the classes it was given otherwise.
    static func setTone(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ name: String?, from tones: [String]
    ) {
        for tone in tones where tone != name { gtk_widget_remove_css_class(widget, tone) }
        if let name { gtk_widget_add_css_class(widget, name) }
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
        attachDrops(
            tailscode_accept_chat_drops, to: widget, motion: motion, leave: leave, drop: drop)
    }

    /// Makes `widget` (a pane's identity strip) a pane the pointer can pick up and carry to
    /// another pane, under a type of its own that no chat target and no text field accepts.
    static func makePaneDragSource(
        _ widget: UnsafeMutablePointer<GtkWidget>, payload: String
    ) {
        tailscode_make_pane_drag_source(widget, payload)
    }

    /// A dragged pane over `widget`, reported exactly as a dragged chat is.
    static func acceptPaneDrops(
        on widget: UnsafeMutablePointer<GtkWidget>,
        motion: @escaping @Sendable (String?, Double, Double) -> Void,
        leave: @escaping @Sendable () -> Void,
        drop: @escaping @Sendable (String, Double, Double) -> Bool
    ) {
        attachDrops(
            tailscode_accept_pane_drops, to: widget, motion: motion, leave: leave, drop: drop)
    }

    typealias DropAttacher = @convention(c) (
        UnsafeMutablePointer<GtkWidget>?,
        (@convention(c) (UnsafePointer<CChar>?, Double, Double, UnsafeMutableRawPointer?) -> Void)?,
        (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
        (@convention(c) (UnsafePointer<CChar>?, Double, Double, UnsafeMutableRawPointer?) -> gboolean)?,
        UnsafeMutableRawPointer?
    ) -> Void

    static func attachDrops(
        _ attach: DropAttacher, to widget: UnsafeMutablePointer<GtkWidget>,
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
        attach(widget, onMotion, onLeave, onDrop, box)
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

    /// One row of a grouped menu: a title, a second line, whether it wears the current mark, and
    /// what pressing it does — nothing, for a row that is only there to say something.
    struct MenuRow: Sendable {
        let title: String
        let detail: String?
        var on: Bool = false
        var action: (@Sendable () -> Void)? = nil
    }

    /// A run of rows under one heading. A nil heading is a run with no line over it.
    struct MenuSection: Sendable {
        let heading: String?
        let rows: [MenuRow]
    }

    /// The grouped cousin of ``menuButton(_:css:rows:)``: the same popover, built on every
    /// opening, with a dim heading over each run of rows and a mark on the row that is current.
    /// A row with no action is a sentence rather than a choice and is drawn as one.
    static func menuButton(
        _ title: String, css: [String] = [],
        sections: @escaping @Sendable () -> [MenuSection]
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
            gtk_scrolled_window_set_max_content_height(op(scroller), 480)
            gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
            gtk_scrolled_window_set_propagate_natural_width(op(scroller), 1)
            for (index, section) in sections().enumerated() {
                if let heading = section.heading {
                    let line = label(heading, css: "menu-heading", selectable: false)
                    gtk_widget_set_margin_top(line, index == 0 ? 2 : 8)
                    gtk_widget_set_margin_start(line, 10)
                    gtk_widget_set_margin_end(line, 10)
                    gtk_box_append(ptr(column), line)
                }
                for row in section.rows {
                    let item = gtk_button_new()!
                    addClass(item, "flat")
                    if row.on { addClass(item, "menu-row-on") }
                    let lines = box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                    let mark = row.on ? "✓ " : (section.rows.contains { $0.on } ? "   " : "")
                    gtk_box_append(
                        ptr(lines), label(mark + row.title, css: "row-title", selectable: false))
                    if let detail = row.detail, !detail.isEmpty {
                        let subtitle = label(detail, css: "row-detail", selectable: false)
                        gtk_label_set_max_width_chars(op(subtitle), 72)
                        gtk_label_set_wrap(op(subtitle), 1)
                        gtk_box_append(ptr(lines), subtitle)
                    }
                    gtk_button_set_child(ptr(item), lines)
                    if let action = row.action {
                        connect(UnsafeMutableRawPointer(item), "clicked") {
                            guard let raw = UnsafeMutableRawPointer(bitPattern: popoverBits) else {
                                return
                            }
                            gtk_popover_popdown(ptr(raw))
                            action()
                        }
                    } else {
                        gtk_widget_set_sensitive(item, 0)
                    }
                    gtk_box_append(ptr(column), item)
                }
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
        rows: [(title: String, detail: String?, action: @Sendable () -> Void)],
        onClosed: (@Sendable () -> Void)? = nil
    ) {
        guard !rows.isEmpty else { return }
        let popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, widget)
        gtk_popover_set_has_arrow(ptr(popover), 0)
        var rect = GdkRectangle(x: gint(x), y: gint(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(ptr(popover), &rect)
        let popoverBits = UInt(bitPattern: popover)
        let popoverHold = WeakWidget(popover)
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
                onClosed?()
                guard let held = popoverHold.widget, gtk_widget_get_parent(held) != nil
                else { return }
                gtk_widget_unparent(held)
            }
        }
        gtk_popover_popup(ptr(popover))
    }
}
