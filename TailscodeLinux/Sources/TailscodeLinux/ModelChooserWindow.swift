import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The whole catalog, drawn. A pill's popover can hold the handful of models a person actually
/// works with; it cannot hold two hundred, and the flat list it degenerated into — every row
/// repeating the same provider key underneath a name — was a list nobody could read.
///
/// This is the other half: one window, one search field, and the shared `ModelChooser`'s sections.
/// Nothing here decides anything — folding, ranking, the cursor and the keys all come from the Kit,
/// so what the phone shows and what this shows are the same list rendered twice.
final class ModelChooserWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var open: ModelChooserWindow?

    private var chooser: ModelChooser
    private let onPick: @Sendable (ModelPick) -> Void
    private let window: UnsafeMutablePointer<GtkWidget>
    private let entry: UnsafeMutablePointer<GtkWidget>
    private let list: UnsafeMutablePointer<GtkWidget>
    private let scroller: UnsafeMutablePointer<GtkWidget>
    private let count: UnsafeMutablePointer<GtkWidget>
    private var rowWidgets: [UInt] = []

    static func present(
        sources: [ModelSource], selected: ModelSelection?,
        parent: UnsafeMutablePointer<GtkWidget>?,
        onPick: @escaping @Sendable (ModelPick) -> Void
    ) {
        open?.close()
        open = ModelChooserWindow(
            sources: sources, selected: selected, parent: parent, onPick: onPick)
    }

    private init(
        sources: [ModelSource], selected: ModelSelection?,
        parent: UnsafeMutablePointer<GtkWidget>?,
        onPick: @escaping @Sendable (ModelPick) -> Void
    ) {
        chooser = ModelChooser(sources: sources, selected: selected)
        self.onPick = onPick

        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Model"))
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 620, 620)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(column, top: 14, bottom: 12, leading: 14, trailing: 14)
        gtk_window_set_child(ptr(window), column)

        count = Gtk.label(chooser.summary, css: "model-summary", selectable: false)
        gtk_box_append(ptr(column), count)

        entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(
            ptr(entry), Localized.text("Search models, providers, ids"))
        Gtk.addClass(entry, "model-search")
        gtk_box_append(ptr(column), entry)

        scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(scroller, 1)
        list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_scrolled_window_set_child(op(scroller), list)
        gtk_box_append(ptr(column), scroller)

        gtk_box_append(ptr(column), Gtk.label(chooser.hint, css: "chooser-hint", selectable: false))

        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.queryChanged() }
        }
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self else { return false }
            return self.key(keyval: keyval, state: state)
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            Gtk.onMain { ModelChooserWindow.open = nil }
        }

        render()
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(entry)
    }

    private func close() {
        Self.open = nil
        gtk_window_destroy(ptr(window))
    }

    private func queryChanged() {
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        chooser.search(String(cString: raw))
        gtk_label_set_text(op(count), chooser.summary)
        render()
    }

    private func key(keyval: UInt32, state: UInt32) -> Bool {
        guard let chord = KeyChord.canonical(keyval: keyval, state: state),
            let command = ModelChooser.command(for: chord)
        else { return false }
        let outcome = chooser.handle(command)
        guard outcome.handled else { return false }
        if outcome.dismissed {
            close()
            return true
        }
        if let chosen = outcome.pick {
            pick(chosen)
            return true
        }
        render()
        return true
    }

    private func pick(_ chosen: ModelPick) {
        let handler = onPick
        close()
        handler(chosen)
    }

    private func render() {
        Gtk.removeChildren(of: list)
        rowWidgets = []
        if let empty = chooser.emptyResult {
            let notice = Gtk.label(empty, css: "row-detail", wrap: true, selectable: false)
            Gtk.margins(notice, top: 24, bottom: 24, leading: 6, trailing: 6)
            gtk_box_append(ptr(list), notice)
            return
        }
        var index = 0
        for section in chooser.sections {
            if !section.title.isEmpty {
                gtk_box_append(ptr(list), header(section))
            }
            for row in section.rows {
                let widget = make(row, index: index)
                rowWidgets.append(UInt(bitPattern: widget))
                gtk_box_append(ptr(list), widget)
                index += 1
            }
        }
        revealCursor()
    }

    private func header(_ section: ModelChooserSection) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 12, bottom: 2, leading: 6, trailing: 6)
        let title = Gtk.label(
            section.title.uppercased(), css: "section-header", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(row), title)
        gtk_box_append(
            ptr(row), Gtk.label(section.detail, css: "model-section-count", selectable: false))
        return row
    }

    private func make(
        _ row: ModelChooserRow, index: Int
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "model-row")
        gtk_widget_set_hexpand(button, 1)

        let mark = Gtk.label(row.isSelected ? "✓" : " ", css: "model-check", selectable: false)
        gtk_label_set_ellipsize(op(mark), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_size_request(mark, 14, -1)
        gtk_widget_set_valign(mark, GTK_ALIGN_START)
        Gtk.margins(mark, top: 2)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.markupLabel(Self.markup(row), css: "row-title")
        gtk_label_set_wrap(op(title), 0)
        gtk_label_set_selectable(op(title), 0)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        for fact in row.facts {
            gtk_box_append(ptr(titleRow), Self.factPill(fact))
        }

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_box_append(ptr(lines), titleRow)
        if !row.detail.isEmpty {
            gtk_box_append(ptr(lines), Gtk.label(row.detail, css: "row-detail", selectable: false))
        }
        gtk_widget_set_hexpand(lines, 1)

        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(content, top: 3, bottom: 3, leading: 4, trailing: 4)
        gtk_box_append(ptr(content), mark)
        gtk_box_append(ptr(content), lines)
        gtk_button_set_child(ptr(button), content)

        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.activate(index) }
        }

        let wrapper = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        if row.isNested { Gtk.addClass(wrapper, "model-row-nested") }
        if index == chooser.cursor { Gtk.addClass(wrapper, "row-focused") }
        gtk_box_append(ptr(wrapper), button)
        if row.canExpand {
            let expanded = row.isExpanded
            let chevron = gtk_button_new()!
            Gtk.addClass(chevron, "flat")
            Gtk.addClass(chevron, "model-chevron")
            gtk_button_set_child(
                ptr(chevron),
                Gtk.label(expanded ? "⌄" : "›", css: "model-chevron-glyph", selectable: false))
            gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(chevron, Localized.text("The other providers that run it"))
            Gtk.connect(UnsafeMutableRawPointer(chevron), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.chooser.focus(index)
                    _ = self.chooser.setExpanded(!expanded, at: index)
                    self.render()
                }
            }
            gtk_box_append(ptr(wrapper), chevron)
        }
        return wrapper
    }

    /// Picking a row means picking its model — except on a folded row someone clicked while it was
    /// closed and whose other providers they may want to see first. Clicking still picks: the
    /// chevron is what opens it, and ⌃→ does the same from the keyboard.
    private func activate(_ index: Int) {
        chooser.focus(index)
        guard let row = chooser.focused else { return }
        pick(row.pick)
    }

    /// The focused row is brought into view without stealing focus from the search field — a
    /// chooser you type into cannot hand the caret to the list every time the cursor moves.
    private func revealCursor() {
        guard chooser.cursor < rowWidgets.count else { return }
        let rowBits = rowWidgets[chooser.cursor]
        let listBits = UInt(bitPattern: list)
        let scrollerBits = UInt(bitPattern: scroller)
        Gtk.after(1) {
            guard let rowRaw = UnsafeMutableRawPointer(bitPattern: rowBits),
                let listRaw = UnsafeMutableRawPointer(bitPattern: listBits),
                let scrollerRaw = UnsafeMutableRawPointer(bitPattern: scrollerBits),
                let adjustment = gtk_scrolled_window_get_vadjustment(op(scrollerRaw))
            else { return }
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(rowRaw)
            let offset = tailscode_widget_offset_y(widget, ptr(listRaw))
            guard offset >= 0 else { return }
            let page = gtk_adjustment_get_page_size(adjustment)
            let height = Double(gtk_widget_get_height(widget))
            let value = gtk_adjustment_get_value(adjustment)
            if offset < value {
                gtk_adjustment_set_value(adjustment, max(0, offset - 8))
            } else if offset + height > value + page {
                gtk_adjustment_set_value(
                    adjustment,
                    min(
                        max(0, offset + height - page + 8),
                        max(0, gtk_adjustment_get_upper(adjustment) - page)))
            }
        }
    }

    /// The letters the query landed on, weighted inside the name rather than beside it — a row
    /// that says why it is in the list is a row you can trust the ranking of.
    private static func markup(_ row: ModelChooserRow) -> String {
        let accent = MatrixTheme.palette.accent
        let characters = Array(row.title)
        guard !row.highlight.isEmpty else { return PangoMarkdown.escape(row.title) }
        let hits = Set(row.highlight)
        var result = ""
        var run = ""
        var runHit = false
        func flush() {
            guard !run.isEmpty else { return }
            let escaped = PangoMarkdown.escape(run)
            result +=
                runHit
                ? "<span foreground=\"\(accent)\" weight=\"bold\">\(escaped)</span>" : escaped
            run = ""
        }
        for (index, character) in characters.enumerated() {
            let hit = hits.contains(index)
            if hit != runHit {
                flush()
                runHit = hit
            }
            run.append(character)
        }
        flush()
        return result
    }

    private static func factPill(_ fact: ModelFact) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(fact.tag, css: "model-fact", selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(label, fact.label)
        switch fact {
        case .local: Gtk.addClass(label, "model-fact-local")
        case .providers: Gtk.addClass(label, "model-fact-providers")
        case .server: Gtk.addClass(label, "model-fact-server")
        default: break
        }
        return label
    }
}
