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
    /// The card a table wears while it is being written: its own border, a sweep, and the count of
    /// what has landed. Nothing here is measured against anything — one glyph one advance wide and
    /// two labels whose text changes — so an arrival costs a label set and no layout at all.
    /// `TableDraft` says why the rows are held.
    static func draft(_ draft: TableDraft, key: String) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(card, "md-table")
        Gtk.addClass(card, "md-table-draft")
        gtk_widget_set_halign(card, GTK_ALIGN_START)
        gtk_widget_set_valign(card, GTK_ALIGN_START)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(row, "md-table-row")
        func word(_ text: String, css: String) -> UnsafeMutablePointer<GtkWidget> {
            let label = Gtk.label(text, css: css, selectable: false)
            // A card this small is never squeezed, so an ellipsis on it is not a truncation the
            // reader can do anything about — it is the label's own minimum quietly winning.
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
            return label
        }
        let sweep = word(TableDraft.mark.glyph, css: "md-table-sweep")
        gtk_box_append(ptr(row), sweep)
        gtk_box_append(ptr(row), word(draft.title, css: "md-table-header"))
        if let detail = draft.detail {
            gtk_box_append(ptr(row), word(detail, css: "md-table-draft-count"))
        }
        gtk_box_append(ptr(card), row)
        Sweep.lay(on: sweep, key: key)
        Wash.note(draft: key)
        return card
    }

    /// The sweep on a draft card, on the display's own clock rather than a chained timeout, and
    /// held by the widget it turns so a card scrolled out of existence takes its lap with it.
    final class Sweep: @unchecked Sendable {
        private let label: UnsafeMutablePointer<GtkWidget>
        private lazy var lap = RepeatingMotion(holding: false) { [weak self] in self?.step() }
        private var shown = ""

        private init(label: UnsafeMutablePointer<GtkWidget>) {
            self.label = label
        }

        static func lay(on label: UnsafeMutablePointer<GtkWidget>, key: String) {
            let sweep = Sweep(label: label)
            g_object_set_data_full(
                ptr(UnsafeMutableRawPointer(label)), "tailscode-table-sweep",
                Unmanaged.passRetained(sweep).toOpaque(),
                { raw in
                    guard let raw else { return }
                    Unmanaged<Sweep>.fromOpaque(raw).release()
                })
            sweep.relay()
            RepeatingMotion.watch(label) { [weak sweep] in sweep?.relay() }
        }

        /// The desk may change its mind about motion while a table is still arriving, so the
        /// question is asked again rather than remembered.
        private func relay() {
            lap.lay(on: label, meaning: TableDraft.motion)
        }

        /// Every glyph in the cycle is one advance wide, so the label never re-measures and the
        /// frame changes light rather than layout.
        private func step() {
            guard
                let frame = TableDraft.motion.frame(
                    at: CascadePainter.now, of: TableDraft.mark.cycle),
                frame != shown
            else { return }
            shown = frame
            gtk_label_set_text(op(label), frame)
        }
    }

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

        var bands: [UnsafeMutablePointer<GtkWidget>] = []
        let head = band("md-table-headrow")
        bands.append(head)
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
            bands.append(line)
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

        if Wash.owed(key) { Wash.lay(on: card, bands: bands) }

        let fold = Fold(
            key: key, table: table, columns: columns, fade: fade,
            viewport: gtk_scrolled_window_get_hadjustment(op(scroller)))
        fold.settle(when: card)
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

    /// The wash a finished table arrives on, and the ledger of which tables have earned one.
    ///
    /// Only a table that was a draft on this screen a moment ago is washed in: a table read out of
    /// history, or one this pane is rebuilding for the tenth time, is already a settled fact and a
    /// settled fact does not animate. The arithmetic and the beat are Core's (`TableEntrance`); the
    /// only thing done here is setting an opacity per band per frame, which changes light and never
    /// layout.
    final class Wash: @unchecked Sendable {
        private let bands: [UnsafeMutablePointer<GtkWidget>]
        private let clock: UnsafeMutablePointer<GtkWidget>
        private var tick: UInt = 0
        private var startedAt = 0.0

        /// Which tables were last drawn as a draft, so the wash is owed exactly once. Widgets are
        /// built on the main thread and nowhere else.
        nonisolated(unsafe) private static var drafted: Set<String> = []

        static func note(draft key: String) {
            drafted.insert(key)
            if drafted.count > 400 { drafted = [key] }
        }

        static func owed(_ key: String) -> Bool {
            guard RepeatingMotion.allowed else {
                drafted.remove(key)
                return false
            }
            return drafted.remove(key) != nil
        }

        private init(clock: UnsafeMutablePointer<GtkWidget>, bands: [UnsafeMutablePointer<GtkWidget>]) {
            self.clock = clock
            self.bands = bands
        }

        static func lay(
            on clock: UnsafeMutablePointer<GtkWidget>, bands: [UnsafeMutablePointer<GtkWidget>]
        ) {
            guard !bands.isEmpty else { return }
            let wash = Wash(clock: clock, bands: bands)
            for band in bands { gtk_widget_set_opacity(band, 0) }
            wash.startedAt = CascadePainter.now
            g_object_ref(UnsafeMutableRawPointer(clock))
            // A frame clock only ticks for a widget the compositor is drawing. A table built into
            // a pane nobody looks at would otherwise sit at zero opacity forever, so the wash has
            // an end it reaches without the clock.
            Gtk.after(UInt32(TableEntrance.span * 1000) + 250) { [weak wash] in wash?.land() }
            wash.tick = UInt(
                tailscode_add_tick(
                    clock,
                    { raw in
                        guard let raw else { return }
                        Unmanaged<Wash>.fromOpaque(raw).takeUnretainedValue().step()
                    }, Unmanaged.passRetained(wash).toOpaque()))
        }

        private func step() {
            guard tick != 0 else { return }
            let elapsed = CascadePainter.now - startedAt
            for (index, band) in bands.enumerated() {
                gtk_widget_set_opacity(
                    band, TableEntrance.opacity(band: index, of: bands.count, elapsed: elapsed))
            }
            // A settled table is a still one: the clock comes off by hand, because the entrance
            // merely ending changes no value a frame could notice.
            guard TableEntrance.isFinished(elapsed) else { return }
            land()
        }

        func land() {
            for band in bands { gtk_widget_set_opacity(band, 1) }
            guard tick != 0 else { return }
            tailscode_remove_tick(clock, guint(tick))
            tick = 0
            g_object_unref(UnsafeMutableRawPointer(clock))
            Unmanaged.passUnretained(self).release()
        }
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

        /// Measures and fits the table once it can be measured honestly, and again whenever it is
        /// realized anew.
        ///
        /// A label that is not yet in a window has no ancestors, so its own class is all the style
        /// it gets: the transcript's face and everything a cell inherits from it are missing, and a
        /// column measured like that is narrower than the words that land in it. The cells then
        /// wrapped on their own where the arithmetic had planned no fold, no height was pinned for
        /// them, and the scroller — which asks its child for a height at the child's natural width —
        /// was told a height the table only has when nothing wraps. The table drew past the bottom
        /// of its own card. Realize is the first moment the style is the one that will be painted,
        /// and it comes before the first allocation, so the first frame is already the right one.
        func settle(when widget: UnsafeMutablePointer<GtkWidget>) {
            if gtk_widget_get_root(widget) != nil { settle() }
            Gtk.connect(UnsafeMutableRawPointer(widget), "realize") { [weak self] in self?.settle() }
        }

        private func settle() {
            measure()
            applied = []
            fitting = 0
            let room = viewport.map { gtk_adjustment_get_page_size($0) } ?? 0
            apply(fitting: room > 1 ? room : Self.opening)
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
                for label in cells {
                    gtk_widget_set_size_request(label, width, -1)
                    // A size request is a floor, never a ceiling: a wrapping label pinned to 139
                    // points still reports its *natural* width — the whole unbroken string — and
                    // the scroller holding the table asks for heights at exactly that width, where
                    // nothing wraps. So every cell's height at the width it will actually be given
                    // is pinned, folded or not: a cell that wraps where the arithmetic planned no
                    // fold must still be counted, or the table draws past the bottom of its card.
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
