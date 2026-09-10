import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A pipe table as an object with edges: a bordered card, a header band that is visibly not the
/// body, and every other row washed. The design and every number in it are Core's
/// (`TableStyle`); what a column holds, where it sits and whether it may fold are
/// `MarkdownTable`'s; how wide each is is `TableLayout`'s. This file paints them in GTK.
///
/// Two things it does that the old grid could not.
///
/// **It measures in pixels.** The columns used to be sized in characters and handed to Pango as
/// `max-width-chars`, which is an *average*-character estimate against a proportional face — so a
/// four-letter bold header in a four-character column hyphenated itself to `Ban-d`, a reading
/// wrapped `MHz` under `2437`, and a column of capitals folded in half. Every cell is laid out
/// once with wrapping off, its ink measured, and the widths computed from those measures, so a
/// column that asks for room gets exactly the room it asks for.
///
/// **It uses the pane it is in.** The measure used to be a constant hundred and eight characters
/// whatever the window was, which on a wide desktop squeezed a table into a third of the screen
/// and folded it there. The scroller's own viewport is the measure instead, re-read whenever it
/// changes, so the same table opens out in a maximised window and folds in a narrow split. Only
/// the columns with something to fold pay for it (`MarkdownTable.rigidColumns`); what still will
/// not fit scrolls sideways, and the last inch of it dissolves rather than being cut off.
enum TableView {
    static func make(_ table: MarkdownTable, key: String) -> UnsafeMutablePointer<GtkWidget> {
        let palette = MatrixTheme.palette
        let kinds = table.kinds
        let names = table.namesItsRows

        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(card, "md-table")
        gtk_widget_set_halign(card, GTK_ALIGN_START)
        gtk_widget_set_valign(card, GTK_ALIGN_START)

        var columns = [[UnsafeMutablePointer<GtkWidget>]](
            repeating: [], count: max(1, table.columnCount))

        func cell(_ text: String, header: Bool, column: Int) -> UnsafeMutablePointer<GtkWidget> {
            var inline = PangoMarkdown.inline(text, code: palette.info, accent: palette.accent)
            if kinds.indices.contains(column), kinds[column] == .number {
                inline = "<span font_features=\"tnum=1\">\(inline)</span>"
            }
            // Pango hyphenates a wrapped line by default, which turns a token that was never a
            // word — a header, a cipher suite, a hostname — into one with a dash in the middle.
            inline = "<span insert_hyphens=\"false\">\(inline)</span>"
            let role = TableStyle.role(header: header, key: names && column == 0)
            // Wrapping is on from the start and breaks only between words: one measure then
            // reports both of the widths this table needs — the whole line as the natural, and
            // the longest word in it as the minimum, which is the width below which a cell stops
            // folding and starts breaking a token in half.
            let label = Gtk.markupLabel(inline, css: css(for: role), wrap: true)
            gtk_label_set_wrap_mode(op(label), PANGO_WRAP_WORD)
            gtk_label_set_max_width_chars(op(label), -1)
            gtk_label_set_width_chars(op(label), -1)
            gtk_widget_set_valign(label, GTK_ALIGN_START)
            gtk_widget_set_halign(label, GTK_ALIGN_FILL)
            switch table.effectiveAlignment(of: column) {
            case .leading: gtk_label_set_xalign(op(label), 0)
            case .center: gtk_label_set_xalign(op(label), 0.5)
            case .trailing: gtk_label_set_xalign(op(label), 1)
            }
            if column < columns.count { columns[column].append(label) }
            return label
        }

        func band(_ css: String) -> UnsafeMutablePointer<GtkWidget> {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Int32(TableStyle.columnGap))
            Gtk.addClass(row, css)
            gtk_widget_set_halign(row, GTK_ALIGN_FILL)
            return row
        }

        let head = band("md-table-headrow")
        for (column, title) in table.header.enumerated() {
            gtk_box_append(ptr(head), cell(title, header: true, column: column))
        }
        gtk_box_append(ptr(card), head)

        let rule = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(rule, "md-table-rule")
        gtk_widget_set_halign(rule, GTK_ALIGN_FILL)
        gtk_box_append(ptr(card), rule)

        for row in table.rows.indices {
            let line = band("md-table-row")
            if TableStyle.stripes(row: row) { Gtk.addClass(line, "md-table-band") }
            if row == table.rows.count - 1 { Gtk.addClass(line, "md-table-last") }
            for (column, text) in table.cells(in: row).enumerated() {
                gtk_box_append(ptr(line), cell(text, header: false, column: column))
            }
            gtk_box_append(ptr(card), line)
        }

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        // The viewport is built rather than implied, because the one a scrolled window makes for
        // you scrolls itself to whatever takes focus inside it — and every cell is a selectable
        // label, so a click anywhere in the pane slid the table sideways under the reader and
        // hid the column that names the row.
        let viewport = gtk_viewport_new(nil, nil)!
        gtk_viewport_set_scroll_to_focus(op(viewport), 0)
        gtk_viewport_set_child(op(viewport), card)
        gtk_scrolled_window_set_child(op(scroller), viewport)
        gtk_widget_set_hexpand(scroller, 1)
        Gtk.addClass(scroller, "md-table-scroll")

        let fade = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(fade, "md-table-fade")
        gtk_widget_set_halign(fade, GTK_ALIGN_END)
        gtk_widget_set_valign(fade, GTK_ALIGN_FILL)
        gtk_widget_set_size_request(fade, Int32(TableStyle.fade), -1)
        gtk_widget_set_can_target(fade, 0)
        gtk_widget_set_visible(fade, 0)

        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), scroller)
        gtk_overlay_add_overlay(op(overlay), fade)
        gtk_widget_set_hexpand(overlay, 1)

        let fold = Fold(
            key: key, table: table, columns: columns, fade: fade,
            viewport: gtk_scrolled_window_get_hadjustment(op(scroller)))
        fold.measure()
        fold.apply(fitting: Fold.opening)
        if let adjustment = fold.viewport {
            Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "page-size") { [weak fold] in
                fold?.scheduleReflow()
                fold?.showFade()
            }
            Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "upper") { [weak fold] in
                fold?.showFade()
            }
        }
        Fold.keep(fold, on: overlay)
        return overlay
    }

    private static func css(for role: TypeRole) -> String {
        switch role {
        case .tableHeader: return "md-table-header"
        case .tableKey: return "md-table-key"
        default: return "md-table-cell"
        }
    }

    /// One table's columns, and the arithmetic that decides how wide they are right now.
    ///
    /// It outlives the build so the table can be re-fitted when its pane changes width without
    /// being rebuilt — a rebuild would lose the reader's sideways scroll — and it is held by the
    /// widget it belongs to rather than by a global, so a transcript that has scrolled a thousand
    /// tables out of existence is holding none of them.
    final class Fold: @unchecked Sendable {
        /// The measure the first pass is fitted to, before any pane has said how wide it is. Wide
        /// enough that a table of prose is not folded twice over on a maximised window, narrow
        /// enough that the first frame of a narrow split is not visibly too wide.
        static let opening: Double = 760

        private let key: String
        private let columns: [[UnsafeMutablePointer<GtkWidget>]]
        private let rigid: [Bool]
        private let fade: UnsafeMutablePointer<GtkWidget>
        /// The scroller's own horizontal adjustment, whose page size *is* the room the table has.
        let viewport: UnsafeMutablePointer<GtkAdjustment>?
        private var natural: [Double] = []
        private var floors: [Double] = []
        private var applied: [Double] = []
        private var fitting: Double = 0
        private var scheduled = false

        init(
            key: String, table: MarkdownTable,
            columns: [[UnsafeMutablePointer<GtkWidget>]],
            fade: UnsafeMutablePointer<GtkWidget>,
            viewport: UnsafeMutablePointer<GtkAdjustment>?
        ) {
            self.key = key
            self.columns = columns
            self.rigid = table.rigidColumns
            self.fade = fade
            self.viewport = viewport
        }

        /// Every column's two widths, in points, which is the only unit a proportional face can be
        /// asked about honestly: the whole line it would like, and the longest word it cannot
        /// break. Never narrower than the same table measured a moment ago — a table grows a row
        /// at a time, and a column that gave room back mid-answer would move every column on the
        /// screen under a reader who is reading the rows already there.
        func measure() {
            var wanted = [Double](repeating: 0, count: columns.count)
            var least = [Double](repeating: 0, count: columns.count)
            for (column, cells) in columns.enumerated() {
                for label in cells {
                    var low: Int32 = 0
                    var high: Int32 = 0
                    gtk_widget_measure(
                        label, GTK_ORIENTATION_HORIZONTAL, -1, &low, &high, nil, nil)
                    wanted[column] = max(wanted[column], Double(high))
                    least[column] = max(least[column], Double(low))
                }
            }
            floors = least
            natural = TableLayout.settled(wanted, since: Self.remembered[key] ?? [])
            Self.remember(natural, for: key)
        }

        func apply(fitting available: Double) {
            let room = max(TableLayout.minimumColumn, available - TableStyle.edge * 2)
            let fresh = TableLayout.widths(
                natural: natural, fitting: room, rigid: rigid, floors: floors)
            let widths = abs(room - fitting) < 0.5
                ? TableLayout.settled(fresh, since: applied) : fresh
            fitting = room
            defer { showFade() }
            guard widths != applied else { return }
            applied = widths
            for (column, cells) in columns.enumerated() where column < widths.count {
                let width = Int32(widths[column].rounded())
                let folds = widths[column] < natural[column] - 0.5
                for label in cells {
                    gtk_widget_set_size_request(label, width, -1)
                    guard folds else { continue }
                    // A size request is a floor, never a ceiling: a wrapping label pinned to 139
                    // points still reports its *natural* width — the whole unbroken string — and
                    // so still reports one line tall. The box above it believes that, gives the
                    // table a one-line row, and the second line of the cell is drawn over
                    // whatever comes next; a table that folded two cells lost its last row
                    // entirely. So the fold is measured at the width it will actually get, with
                    // GTK's own height-for-width, and that height is pinned too.
                    var low: Int32 = 0
                    var tall: Int32 = 0
                    gtk_widget_measure(label, GTK_ORIENTATION_VERTICAL, width, &low, &tall, nil, nil)
                    gtk_widget_set_size_request(label, width, max(low, tall))
                }
            }
        }

        /// The pane's width arrives from inside the scroller's own size-allocate, and re-fitting
        /// there is how a table loses its last row: a cell that folds to two lines after the
        /// transcript has already measured the row is drawn past the height the row was given, and
        /// the bottom of the table is simply cut off. So the fit is taken one turn of the main loop
        /// later, where a changed size request is a fresh measure rather than a late one.
        func scheduleReflow() {
            guard !scheduled else { return }
            scheduled = true
            Gtk.after(0) { [weak self] in
                self?.scheduled = false
                self?.reflow()
            }
        }

        /// The pane said how wide it is. Re-fitting to it is not the streaming case and carries
        /// none of its floor: a window that narrowed has to be allowed to fold what it can, or the
        /// table would keep a width the pane no longer has and scroll for no reason.
        func reflow() {
            guard let viewport else { return }
            let room = gtk_adjustment_get_page_size(viewport)
            guard room > 1, abs(room - TableStyle.edge * 2 - fitting) > 0.5 else { return }
            apply(fitting: room)
        }

        /// The fade shows only when there is table off the side. A column cut off at a border
        /// reads as a bug; the same column dissolving reads as an invitation to push it.
        func showFade() {
            guard let viewport else { return }
            let more =
                gtk_adjustment_get_upper(viewport) > gtk_adjustment_get_page_size(viewport) + 1
            gtk_widget_set_visible(fade, more ? 1 : 0)
        }

        /// What each table's columns measured last time it was built, so a table that is rebuilt on
        /// every arrival never narrows a column under the reader. Built on the main thread only.
        nonisolated(unsafe) private static var remembered: [String: [Double]] = [:]

        private static func remember(_ widths: [Double], for key: String) {
            remembered[key] = widths
            if remembered.count > 400 { remembered = [key: widths] }
        }

        /// The fold is owned by the widget whose columns it holds: GTK frees the object, the object
        /// frees this, and nothing outlives the table it measured.
        static func keep(_ fold: Fold, on widget: UnsafeMutablePointer<GtkWidget>) {
            g_object_set_data_full(
                ptr(UnsafeMutableRawPointer(widget)), "tailscode-table-fold",
                Unmanaged.passRetained(fold).toOpaque(),
                { raw in
                    guard let raw else { return }
                    Unmanaged<Fold>.fromOpaque(raw).release()
                })
        }
    }
}
