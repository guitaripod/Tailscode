import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// One chip of the brief dock: its label and its value, both drawn, always. A chip that showed
/// only the value left a person to guess which decision "3:2" belonged to, and a chip that
/// clipped its value to fit left them guessing which one it was — so a chip never shrinks, and
/// the row it sits in wraps instead of cutting it.
///
/// The words are Core's (`StudioChipReading`); this only draws them. A chip that would change
/// nothing is insensitive rather than gone, so the row never moves under the pointer.
final class StudioChip: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    private let name: UnsafeMutablePointer<GtkWidget>
    private let value: UnsafeMutablePointer<GtkWidget>
    private let mark: UnsafeMutablePointer<GtkWidget>
    private var base: String?

    private init(widget: UnsafeMutablePointer<GtkWidget>, opens: Bool) {
        self.widget = widget
        name = Gtk.label("", css: "draw-chip-name", selectable: false)
        value = Gtk.label("", css: "draw-chip-value", selectable: false)
        mark = Gtk.label(opens ? ImageGenField.engine.affordanceGlyph : "", css: "draw-chip-mark", selectable: false)
        for label in [name, value, mark] {
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        }
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_append(ptr(row), name)
        gtk_box_append(ptr(row), value)
        gtk_box_append(ptr(row), mark)
        gtk_widget_set_visible(mark, opens ? 1 : 0)
        if opens {
            gtk_menu_button_set_child(op(widget), row)
            gtk_menu_button_set_can_shrink(op(widget), 0)
            gtk_menu_button_set_always_show_arrow(op(widget), 0)
        } else {
            gtk_button_set_child(ptr(widget), row)
        }
        Gtk.addClass(widget, "draw-chip")
        Gtk.addClass(widget, "studio-chip")
        gtk_widget_set_halign(widget, GTK_ALIGN_START)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
    }

    /// A chip that opens a menu of Core's choices for one decision.
    static func menu(
        rows: @escaping @Sendable () -> [(title: String, detail: String?, action: @Sendable () -> Void)]
    ) -> StudioChip {
        StudioChip(widget: Gtk.menuButton("", css: [], rows: rows), opens: true)
    }

    /// A chip that opens whatever popover the caller builds — the avoid list's own entry.
    static func popover(content: UnsafeMutablePointer<GtkWidget>) -> StudioChip {
        let button = gtk_menu_button_new()!
        let popover = gtk_popover_new()!
        gtk_popover_set_child(ptr(popover), content)
        gtk_menu_button_set_popover(op(button), popover)
        return StudioChip(widget: button, opens: true)
    }

    /// A chip that is pressed: the cutout switch, the seed hold, a file to add.
    static func button(_ onClick: @escaping @Sendable () -> Void) -> StudioChip {
        let button = gtk_button_new()!
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        return StudioChip(widget: button, opens: false)
    }

    /// Opens the chip's menu or popover, as pressing it does — for the keyboard and the driver.
    func open() {
        guard gtk_widget_get_sensitive(widget) != 0 else { return }
        gtk_menu_button_popup(op(widget))
    }

    /// Says what Core says: the label and value, the mark of a chip that is on, the warning of
    /// one the machine cannot honour, and the whole of it to a screen reader.
    func apply(_ reading: StudioChipReading, tooltip: String? = nil) {
        gtk_label_set_text(op(name), reading.label)
        gtk_widget_set_visible(name, reading.label.isEmpty ? 0 : 1)
        gtk_label_set_text(op(value), reading.value)
        gtk_widget_set_sensitive(widget, reading.isEnabled ? 1 : 0)
        if reading.isOn {
            Gtk.addClass(widget, "draw-chip-on")
        } else {
            gtk_widget_remove_css_class(widget, "draw-chip-on")
        }
        if reading.warning != nil {
            Gtk.addClass(widget, "studio-chip-warn")
        } else {
            gtk_widget_remove_css_class(widget, "studio-chip-warn")
        }
        let note = [reading.warning, tooltip].compactMap { $0 }.joined(separator: "\n")
        gtk_widget_set_tooltip_text(widget, note.isEmpty ? nil : note)
        let spoken = reading.accessibility
        if spoken != base {
            base = spoken
            tailscode_set_accessible_label(widget, spoken)
        }
    }
}

/// The dock's chips, laid out so a narrow dock wraps them onto another line rather than clipping
/// the last — and able to hand the very same chips to a Settings popover when the pane is too
/// short to spend two rows on them. The chips are built once and reparented, never rebuilt, so a
/// menu open on one survives the pane being resized under it.
///
/// A flow box lays children out in columns of equal width, which makes a row of chips of very
/// different widths look like a table; this breaks lines greedily on each chip's own natural
/// width instead, and moves chips between rows only when the break actually changes.
final class StudioChipTray: @unchecked Sendable {
    /// What the dock holds in its row: lines of chips, one box per line, the trailing word at the
    /// end of the last.
    let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    /// What stands in for the lines in a short pane: the Settings control and the trailing word.
    let folded = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
    /// What the dock places. The chips are never allowed to set how narrow the pane can be: their
    /// natural width is a row of a thousand points, and a pane that could not be narrower than
    /// its chips would never be told it was narrow, so would never wrap them. The lines live in a
    /// window that scrolls in neither direction and asks for no minimum width of its own.
    let container = gtk_scrolled_window_new()!
    private let settings: UnsafeMutablePointer<GtkWidget>
    private let settingsLines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let trailing: UnsafeMutablePointer<GtkWidget>
    private var chips: [StudioChip] = []
    private var isFoldedNow = false
    private var available: Double = 0
    private var signature: [Int] = []
    private var rows: [UnsafeMutablePointer<GtkWidget>] = []
    private var spacers: [UnsafeMutablePointer<GtkWidget>] = []

    /// - Parameter trailing: the quiet word at the dock's foot. It goes at the end of the last
    ///   line when there is room for it there and on a line of its own when there is not, and it
    ///   is counted whether it has anything to say or not, so the lines break in the same places
    ///   before a render, during it and after it.
    init(trailing: UnsafeMutablePointer<GtkWidget>) {
        self.trailing = trailing
        settings = gtk_menu_button_new()!
        Gtk.addClass(settings, "draw-chip")
        Gtk.addClass(settings, "studio-chip")
        Gtk.addClass(lines, "studio-chips")
        gtk_widget_set_hexpand(lines, 1)
        gtk_widget_set_hexpand(settingsLines, 1)
        let popover = gtk_popover_new()!
        let frame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.margins(frame, 12)
        gtk_widget_set_size_request(frame, Int32(Self.settingsWidth + 24), -1)
        gtk_box_append(ptr(frame), settingsLines)
        gtk_popover_set_child(ptr(popover), frame)
        gtk_menu_button_set_popover(op(settings), popover)
        gtk_menu_button_set_label(op(settings), StudioWords.settingsTitle)
        gtk_menu_button_set_can_shrink(op(settings), 0)
        gtk_widget_set_halign(settings, GTK_ALIGN_START)
        gtk_widget_set_valign(settings, GTK_ALIGN_CENTER)
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(folded), settings)
        gtk_box_append(ptr(folded), spacer)
        gtk_widget_set_visible(folded, 0)
        gtk_widget_set_hexpand(folded, 1)
        let stack = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(stack), lines)
        gtk_box_append(ptr(stack), folded)
        gtk_scrolled_window_set_policy(op(container), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_propagate_natural_height(op(container), 1)
        gtk_scrolled_window_set_child(op(container), stack)
        gtk_widget_set_hexpand(container, 1)
        gtk_widget_set_overflow(container, GTK_OVERFLOW_HIDDEN)
        g_object_ref(UnsafeMutableRawPointer(trailing))
    }

    static let settingsWidth: Double = 340

    /// The pane is going away: the references the tray held across reparenting are let go of.
    func release() {
        for chip in chips { g_object_unref(UnsafeMutableRawPointer(chip.widget)) }
        g_object_unref(UnsafeMutableRawPointer(trailing))
        chips = []
    }

    /// Gives the tray its chips, in order. Called once, by whoever knows what a dock of this kind
    /// carries.
    func fill(_ chips: [StudioChip]) {
        self.chips = chips
        for chip in chips { g_object_ref(UnsafeMutableRawPointer(chip.widget)) }
        relayout(force: true)
    }

    /// Whether the chips are in the dock's lines or folded into the Settings popover. They move by
    /// reference, and a menu open on one is left alone.
    func fold(_ fold: Bool) {
        guard fold != isFoldedNow else { return }
        isFoldedNow = fold
        gtk_widget_set_visible(lines, fold ? 0 : 1)
        gtk_widget_set_visible(folded, fold ? 1 : 0)
        if !fold, let popover = gtk_menu_button_get_popover(op(settings)) { gtk_popover_popdown(popover) }
        relayout(force: true)
    }

    var isFolded: Bool { isFoldedNow }

    /// How much width the chips may use: the dock's inner width. A change that moves no line break
    /// moves nothing.
    func layout(available width: Double) {
        guard abs(width - available) > 0.5 else { return }
        available = width
        relayout(force: false)
    }

    private func natural(_ widget: UnsafeMutablePointer<GtkWidget>) -> Double {
        Double(Gtk.naturalSize(of: widget).width)
    }

    /// The natural width of each chip may have changed — a seed was held, a value was chosen — so
    /// the breaks are taken again from what the chips say now.
    func relayout(force: Bool) {
        guard !chips.isEmpty else { return }
        let room = isFoldedNow ? Self.settingsWidth : available
        let spacing: Double = 6
        var next: [Int] = []
        var used = 0.0
        var count = 0
        for chip in chips {
            let width = natural(chip.widget)
            if count > 0, room > 0, used + spacing + width > room {
                next.append(count)
                used = 0
                count = 0
            }
            used += (count > 0 ? spacing : 0) + width
            count += 1
        }
        next.append(count)
        let alone = !isFoldedNow && room > 0 && used + spacing + natural(trailing) > room
        let marks = next + [alone ? 1 : 0, isFoldedNow ? 1 : 0]
        guard force || marks != signature else { return }
        signature = marks
        for chip in chips {
            if let parent = gtk_widget_get_parent(chip.widget) { gtk_box_remove(ptr(parent), chip.widget) }
        }
        if let parent = gtk_widget_get_parent(trailing) { gtk_box_remove(ptr(parent), trailing) }
        for spacer in spacers {
            if let parent = gtk_widget_get_parent(spacer) { gtk_box_remove(ptr(parent), spacer) }
        }
        for row in rows {
            if let parent = gtk_widget_get_parent(row) { gtk_box_remove(ptr(parent), row) }
        }
        rows = []
        spacers = []
        let target = isFoldedNow ? settingsLines : lines
        var index = 0
        for (line, size) in next.enumerated() {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Int32(spacing))
            for _ in 0..<size {
                gtk_box_append(ptr(row), chips[index].widget)
                index += 1
            }
            if !isFoldedNow, !alone, line == next.count - 1 { appendTrailing(to: row) }
            gtk_box_append(ptr(target), row)
            rows.append(row)
        }
        if !isFoldedNow, alone {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            appendTrailing(to: row)
            gtk_box_append(ptr(target), row)
            rows.append(row)
        }
        if isFoldedNow { gtk_box_append(ptr(folded), trailing) }
    }

    private func appendTrailing(to row: UnsafeMutablePointer<GtkWidget>) {
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(row), spacer)
        gtk_box_append(ptr(row), trailing)
        spacers.append(spacer)
    }
}
