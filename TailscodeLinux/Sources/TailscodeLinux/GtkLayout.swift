import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension Gtk {
    /// The size a widget asks for, without the margins GTK counts into it — which is what a child
    /// positioned by its own margins needs to know, since its current margins would otherwise be
    /// read back as part of how big it is.
    static func naturalSize(of widget: UnsafeMutablePointer<GtkWidget>)
        -> (width: Double, height: Double)
    {
        var minimum = GtkRequisition()
        var natural = GtkRequisition()
        gtk_widget_get_preferred_size(widget, &minimum, &natural)
        let across = gtk_widget_get_margin_start(widget) + gtk_widget_get_margin_end(widget)
        let down = gtk_widget_get_margin_top(widget) + gtk_widget_get_margin_bottom(widget)
        return (Double(natural.width - across), Double(natural.height - down))
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

    /// A box that is a group to assistive technology and has a name: a card, which is one thing
    /// said in several labels, and which a plain box would leave as an unnamed pile of them.
    static func groupBox(
        _ orientation: GtkOrientation, spacing: Int32, spoken: String
    ) -> UnsafeMutablePointer<GtkWidget> {
        let box = tailscode_box_new_with_role(orientation, spacing, GTK_ACCESSIBLE_ROLE_GROUP)!
        tailscode_set_accessible_label(box, spoken)
        return box
    }

    /// A frame that asks for no width of its own. A row that gives parts up as it narrows has to be
    /// told how narrow it is, and a box reports at least the sum of its children, so the window
    /// grows to that and the row reads the growth as room; held in a frame that follows the content
    /// only vertically, the width the row sees is the width the pane really has.
    static func shrinkable(_ child: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget> {
        let frame = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(frame), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_propagate_natural_height(op(frame), 1)
        gtk_widget_set_focusable(frame, 0)
        gtk_scrolled_window_set_child(op(frame), child)
        return frame
    }

    /// Buttons side by side that fold onto further lines when the pane is too narrow for one,
    /// instead of asking the pane to be wider.
    static func wrapRow(_ children: [UnsafeMutablePointer<GtkWidget>], spacing: Int32 = 8)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let flow = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(op(flow), GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(op(flow), 0)
        gtk_flow_box_set_max_children_per_line(op(flow), UInt32(max(1, children.count)))
        gtk_flow_box_set_min_children_per_line(op(flow), 1)
        gtk_flow_box_set_column_spacing(op(flow), UInt32(spacing))
        gtk_flow_box_set_row_spacing(op(flow), 6)
        gtk_widget_set_halign(flow, GTK_ALIGN_START)
        addClass(flow, "wrap-row")
        for child in children {
            gtk_flow_box_append(op(flow), child)
            if let wrapper = gtk_widget_get_parent(child) { gtk_widget_set_focusable(wrapper, 0) }
        }
        return flow
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

    /// Empties a box of its rows without taking down anything else living on it. A context menu
    /// is a popover *parented* on the box, not appended to it, so a rebuild that swept every
    /// child would dismiss the menu under the pointer — which is exactly what a list that
    /// refreshes while working sessions change state kept doing. Popovers close on their own
    /// terms and unparent themselves when they do.
    static func removeChildren(of parent: UnsafeMutablePointer<GtkWidget>) {
        var doomed: [UnsafeMutablePointer<GtkWidget>] = []
        var child = gtk_widget_get_first_child(parent)
        while let current = child {
            if !isPopover(current) { doomed.append(current) }
            child = gtk_widget_get_next_sibling(current)
        }
        for widget in doomed { gtk_box_remove(ptr(parent), widget) }
    }

    /// Puts exactly `children` in a box, in this order. A child the box already held is
    /// referenced across the teardown: the box owns the only reference to what was appended to
    /// it, so taking a row out to put it back frees it, and whoever kept the pointer to draw into
    /// later writes into a widget that no longer exists.
    static func replaceChildren(
        of parent: UnsafeMutablePointer<GtkWidget>, with children: [UnsafeMutablePointer<GtkWidget>]
    ) {
        for child in children { g_object_ref(UnsafeMutableRawPointer(child)) }
        removeChildren(of: parent)
        for child in children { gtk_box_append(ptr(parent), child) }
        for child in children { g_object_unref(UnsafeMutableRawPointer(child)) }
    }

    static func isPopover(_ widget: UnsafeMutablePointer<GtkWidget>) -> Bool {
        let instance = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self)
        return g_type_check_instance_is_a(instance, gtk_popover_get_type()) != 0
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

    /// A hairline for a cell that spans a grid's columns, which asks for nothing. A rule that
    /// wants extra space inside a grid whose columns hug their content makes `GtkGrid` measure a
    /// height for a width distribution it never allocates: every wrapping cell is then measured
    /// one line short, and the table draws its last row over the paragraph beneath it. Spanning
    /// the columns already gives the rule the whole width of what it seats.
    static func spanningHairline() -> UnsafeMutablePointer<GtkWidget> {
        let rule = box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        addClass(rule, "turn-rule")
        gtk_widget_set_halign(rule, GTK_ALIGN_FILL)
        return rule
    }

    final class Slot: @unchecked Sendable {
        var bits: UInt = 0
    }

    /// A disclosure whose body does not exist until the first open. A transcript row that is
    /// collapsed — which is nearly every tool row — costs its header line and nothing else; the
    /// diff, the output, the subagent transcript are built the moment someone asks and kept after.
    /// `onToggle` also receives the disclosure's own widget bits, because the one thing a caller
    /// cannot reconstruct from a key is where on screen the row that was clicked actually is.
    static func disclosure(
        header: UnsafeMutablePointer<GtkWidget>,
        expanded: Bool,
        onToggle: @escaping @Sendable (Bool, UInt) -> Void,
        makeBody: @escaping @Sendable () -> UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let button = gtk_button_new()!
        addClass(button, "flat")
        addClass(button, "disclosure")
        let row = box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let chevron = label(
            expanded ? Self.chevronOpen : Self.chevronShut, css: "disclosure-chevron",
            selectable: false)
        gtk_box_append(ptr(row), chevron)
        gtk_widget_set_hexpand(header, 1)
        gtk_box_append(ptr(row), header)
        gtk_button_set_child(ptr(button), row)
        gtk_box_append(ptr(column), button)
        tailscode_set_accessible_label(button, spokenText(of: header))
        tailscode_set_accessible_expanded(button, expanded ? 1 : 0)
        let slot = Slot()
        if expanded {
            let body = makeBody()
            gtk_box_append(ptr(column), body)
            slot.bits = UInt(bitPattern: body)
        }
        let columnBits = UInt(bitPattern: column)
        let chevronBits = UInt(bitPattern: chevron)
        let buttonBits = UInt(bitPattern: button)
        let headerBits = UInt(bitPattern: header)
        @Sendable func mark(_ open: Bool) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: chevronBits) else { return }
            gtk_label_set_text(op(raw), open ? Self.chevronOpen : Self.chevronShut)
            guard let buttonRaw = UnsafeMutableRawPointer(bitPattern: buttonBits),
                let headerRaw = UnsafeMutableRawPointer(bitPattern: headerBits)
            else { return }
            tailscode_set_accessible_expanded(ptr(buttonRaw), open ? 1 : 0)
            tailscode_set_accessible_label(ptr(buttonRaw), spokenText(of: ptr(headerRaw)))
        }
        connect(UnsafeMutableRawPointer(button), "clicked") {
            if slot.bits == 0 {
                guard let raw = UnsafeMutableRawPointer(bitPattern: columnBits) else { return }
                let body = makeBody()
                gtk_box_append(ptr(raw), body)
                slot.bits = UInt(bitPattern: body)
                mark(true)
                onToggle(true, columnBits)
                return
            }
            guard let raw = UnsafeMutableRawPointer(bitPattern: slot.bits) else { return }
            let body: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let showing = gtk_widget_get_visible(body) != 0
            gtk_widget_set_visible(body, showing ? 0 : 1)
            mark(!showing)
            onToggle(!showing, columnBits)
        }
        return column
    }

    /// The words a widget shows, joined — what a control built around a glyph and a few labels
    /// should be called by a screen reader, since the glyph is not its name.
    static func spokenText(of widget: UnsafeMutablePointer<GtkWidget>) -> String {
        if tailscode_is_label(widget) != 0 {
            return gtk_label_get_text(op(widget)).map { String(cString: $0) } ?? ""
        }
        var parts: [String] = []
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            let text = spokenText(of: current)
            if !text.isEmpty { parts.append(text) }
            child = gtk_widget_get_next_sibling(current)
        }
        return parts.joined(separator: " ")
    }

    /// A row that opens says so, and says which way it is. Both glyphs are one cell wide, because a
    /// mark that changes width moves the words beside it every time somebody expands a row.
    static let chevronShut = "▸"

    static let chevronOpen = "▾"

    /// The header a `disclosure` was built around, past the chevron the shared shape adds. A caller
    /// that writes into its own header — a thought counting its words as it grows — has to reach it
    /// through the wrapper rather than assume the button's child is its label.
    static func disclosureHeader(_ button: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        guard let row = gtk_button_get_child(ptr(button)) else { return nil }
        return gtk_widget_get_last_child(row)
    }
}
