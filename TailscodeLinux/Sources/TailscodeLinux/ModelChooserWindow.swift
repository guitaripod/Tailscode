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
    private let selected: ModelSelection?
    private let quotas: [UsageQuota]
    private let recents: [ModelSelection]
    private let window: UnsafeMutablePointer<GtkWidget>
    private let entry: UnsafeMutablePointer<GtkWidget>
    private let list: UnsafeMutablePointer<GtkWidget>
    private let scroller: UnsafeMutablePointer<GtkWidget>
    private let count: UnsafeMutablePointer<GtkWidget>
    private let band: UnsafeMutablePointer<GtkWidget>
    private let fold: UnsafeMutablePointer<GtkWidget>
    /// One width for every row's capability marks, so what a model reads forms a column rather than
    /// a ragged edge that moves with the length of the name beside it.
    private var markColumn: UnsafeMutableRawPointer?
    private var rowWidgets: [UInt] = []
    /// Where the list must land once GTK knows how tall the rebuilt box is. A scroller whose
    /// children were replaced this frame reports the old height — often one screenful — so a
    /// position set before that is clamped to the top and then stays there. Held until the
    /// adjustment's own `upper` says the real size, and cleared the moment it is honoured.
    private var pendingScroll: Double?
    /// Which hold is current, so a rebuild that arrives during another's settle window does not
    /// have its own position let go by the older one's timer.
    private var scrollGeneration = 0
    private var scopeButtons: [(scope: ModelChooserScope, widget: UInt)] = []

    static func present(
        sources: [ModelSource], selected: ModelSelection?,
        parent: UnsafeMutablePointer<GtkWidget>?, quotas: [UsageQuota] = [],
        recents: [ModelSelection] = RecentModelsStore.all(),
        onPick: @escaping @Sendable (ModelPick) -> Void
    ) {
        open?.close()
        open = ModelChooserWindow(
            sources: sources, selected: selected, parent: parent, quotas: quotas,
            recents: recents, onPick: onPick)
    }

    private init(
        sources: [ModelSource], selected: ModelSelection?,
        parent: UnsafeMutablePointer<GtkWidget>?, quotas: [UsageQuota],
        recents: [ModelSelection], onPick: @escaping @Sendable (ModelPick) -> Void
    ) {
        chooser = ModelChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas)
        self.onPick = onPick
        self.selected = selected
        self.quotas = quotas
        self.recents = recents

        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Model"))
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 740, 660)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.margins(column, top: 14, bottom: 12, leading: 14, trailing: 14)
        gtk_window_set_child(ptr(window), column)

        entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(
            ptr(entry), Localized.text("Search models, providers, ids"))
        Gtk.addClass(entry, "model-search")
        gtk_box_append(ptr(column), entry)

        count = Gtk.label(chooser.summary, css: "model-summary", selectable: false)
        gtk_label_set_xalign(op(count), 1)
        fold = gtk_button_new_with_label("")!
        Gtk.addClass(fold, "flat")
        Gtk.addClass(fold, "model-scope")
        band = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.margins(band, top: 2, bottom: 2, leading: 2, trailing: 2)
        gtk_box_append(ptr(column), band)

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
        Gtk.connect(UnsafeMutableRawPointer(entry), "icon-release") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                gtk_editable_set_text(op(self.entry), "")
                gtk_widget_grab_focus(self.entry)
            }
        }
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self else { return false }
            return self.key(keyval: keyval, state: state)
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            Gtk.onMain { ModelChooserWindow.open = nil }
        }

        if let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) {
            Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "upper") { [weak self] in
                Gtk.onMain { [weak self] in self?.applyPendingScroll() }
            }
        }
        buildScopes()
        syncFold()
        render(keepingScroll: false, revealingCursor: true)
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(entry)
    }

    /// The standing filters, as chips beside the count. They carry their own key, because a filter
    /// nobody can see the shortcut for is a filter reached with the mouse forever.
    private func buildScopes() {
        for (index, scope) in chooser.scopes.enumerated() {
            let button = gtk_button_new()!
            Gtk.addClass(button, "flat")
            Gtk.addClass(button, "model-scope")
            let label = gtk_label_new(nil)!
            gtk_label_set_markup(
                op(label),
                "\(PangoMarkdown.escape(scope.title))"
                    + "  <span alpha=\"55%\">⌃\(index + 1)</span>")
            gtk_button_set_child(ptr(button), label)
            gtk_widget_set_tooltip_text(button, scope.detail)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, self.chooser.setScope(scope) else { return }
                    self.refresh(keepingScroll: false)
                }
            }
            scopeButtons.append((scope, UInt(bitPattern: button)))
            gtk_box_append(ptr(band), button)
        }
        gtk_widget_set_hexpand(count, 1)
        gtk_widget_set_valign(count, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(band), count)
        gtk_box_append(ptr(band), fold)
        Gtk.connect(UnsafeMutableRawPointer(fold), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, let action = self.chooser.foldAction,
                    self.chooser.setAllCollapsed(action.collapses)
                else { return }
                self.refresh(keepingScroll: true)
            }
        }
        syncScopes()
    }

    /// The one press over the whole list: open everything a fold is holding, or shut it all again.
    private func syncFold() {
        guard let action = chooser.foldAction else {
            gtk_widget_set_visible(fold, 0)
            return
        }
        gtk_widget_set_visible(fold, 1)
        gtk_button_set_label(ptr(fold), action.title)
    }

    private func syncScopes() {
        for entry in scopeButtons {
            guard let raw = UnsafeMutableRawPointer(bitPattern: entry.widget) else { continue }
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            Gtk.setTone(
                widget, entry.scope == chooser.scope ? "model-scope-on" : nil,
                from: ["model-scope-on"])
        }
    }

    /// Everything the list's own state feeds: the count, the chips, the rows.
    private func refresh(keepingScroll: Bool = false, revealingCursor: Bool = true) {
        gtk_label_set_text(op(count), chooser.summary)
        syncScopes()
        syncFold()
        render(keepingScroll: keepingScroll, revealingCursor: revealingCursor)
    }

    /// A catalog that arrived while the window is open — a server that came back from a restart —
    /// re-answers the list in place. What the reader was doing survives: the query, the filter and
    /// the fold are re-applied rather than reset.
    static func updateOpen(sources: [ModelSource]) {
        Gtk.onMain { open?.refreshSources(sources) }
    }

    private func refreshSources(_ sources: [ModelSource]) {
        let query = chooser.query
        let scope = chooser.scope
        chooser = ModelChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas)
        chooser.search(query)
        if chooser.scopes.contains(scope) || scope == .all { _ = chooser.setScope(scope) }
        scopeButtons = []
        Gtk.removeChildren(of: band)
        buildScopes()
        refresh(keepingScroll: false)
    }

    private func close() {
        Self.open = nil
        gtk_window_destroy(ptr(window))
    }

    private func queryChanged() {
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        let typed = String(cString: raw)
        gtk_entry_set_icon_from_icon_name(
            ptr(entry), GTK_ENTRY_ICON_SECONDARY, typed.isEmpty ? nil : "edit-clear-symbolic")
        chooser.search(typed)
        refresh(keepingScroll: false)
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
        refresh(keepingScroll: true)
        return true
    }

    private func pick(_ chosen: ModelPick) {
        let handler = onPick
        close()
        handler(chosen)
    }

    /// The width of the column the chevron sits in, kept under every row that has no chevron so the
    /// list has one right edge rather than two.
    private static let chevronWidth: Int32 = 24

    /// - Parameter keepingScroll: whether the list is still answering the same question and must
    ///   therefore stay exactly where the reader left it. Opening a family, or a row's other
    ///   providers, adds lines *below* the line that was pressed, so every pixel above it is
    ///   unchanged and the honest answer is to move nothing — but the whole box is rebuilt to draw
    ///   them, and a box emptied of its children takes the scroller's position to zero with it.
    ///   Left there, the cursor is then brought into view from the top of a list it never left,
    ///   and a press that asked to see one more row throws the catalog across itself. A new
    ///   question — a query, a filter, a fresh catalog — is a different list, and that one starts
    ///   at the top on purpose.
    /// - Parameter revealingCursor: whether the focused row is worth pulling into view. It is when
    ///   the cursor just moved — a keypress asked for that row — and it is not when a fold opened
    ///   somewhere the cursor does not live: the cursor sits on the model this chat already runs,
    ///   usually the first row of the list, so chasing it after opening a family at the bottom
    ///   throws the reader back to the top of a catalog they were reading the end of.
    private func render(keepingScroll: Bool, revealingCursor: Bool) {
        let held = keepingScroll ? scrollOffset() : nil
        Gtk.removeChildren(of: list)
        rowWidgets = []
        if let group = markColumn { g_object_unref(group) }
        markColumn = UnsafeMutableRawPointer(gtk_size_group_new(GTK_SIZE_GROUP_HORIZONTAL))
        if let empty = chooser.emptyResult {
            let notice = Gtk.label(empty, css: "row-detail", wrap: true, selectable: false)
            gtk_label_set_xalign(op(notice), 0.5)
            Gtk.margins(notice, top: 28, bottom: 10, leading: 6, trailing: 6)
            gtk_box_append(ptr(list), notice)
            if let escape = chooser.emptyEscape {
                let way = Gtk.button(
                    Localized.text("Clear the filter"), css: ["model-scope"]
                ) { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self, self.chooser.setScope(escape) else { return }
                        self.refresh(keepingScroll: false)
                    }
                }
                gtk_widget_set_halign(way, GTK_ALIGN_CENTER)
                Gtk.margins(way, top: 4, bottom: 24)
                gtk_box_append(ptr(list), way)
            }
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
        gtk_widget_queue_draw(list)
        gtk_widget_queue_draw(scroller)
        settle(at: held, revealingCursor: revealingCursor)
    }

    private func scrollOffset() -> Double? {
        guard let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) else { return nil }
        return gtk_adjustment_get_value(adjustment)
    }

    /// A heading a long catalog can be aimed with: the family, what is under it, and — where it
    /// folds — the whole line as one press, because a disclosure triangle you have to hit is a
    /// smaller target than the heading nobody was using for anything else.
    private func header(_ section: ModelChooserSection) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 12, bottom: 2, leading: 6, trailing: 6)
        if section.canCollapse {
            let glyph = Gtk.label(
                section.isCollapsed ? "›" : "⌄", css: "model-section-fold", selectable: false)
            gtk_widget_set_size_request(glyph, 12, -1)
            gtk_box_append(ptr(row), glyph)
        }
        let title = Gtk.label(
            section.title.uppercased(), css: "section-header", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(row), title)
        gtk_box_append(
            ptr(row), Gtk.label(section.detail, css: "model-section-count", selectable: false))
        guard section.canCollapse else { return row }
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "model-section-button")
        gtk_button_set_child(ptr(button), row)
        gtk_widget_set_hexpand(button, 1)
        let id = section.id
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.chooser.toggleSection(id) else { return }
                self.refresh(keepingScroll: true, revealingCursor: false)
            }
        }
        return button
    }

    /// One row in three columns that hold their places down the whole list: the tick, the name over
    /// what it is, and everything the row wears flush to the right edge. The facts used to sit
    /// immediately after the name, so their left edge moved with every name's length and the eye had
    /// to find them again on each line; against the right edge they read as a column.
    private func make(
        _ row: ModelChooserRow, index: Int
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "model-row")
        gtk_widget_set_hexpand(button, 1)

        let tick = Gtk.label(row.isSelected ? "✓" : " ", css: "model-check", selectable: false)
        gtk_label_set_ellipsize(op(tick), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_size_request(tick, 14, -1)
        gtk_widget_set_valign(tick, GTK_ALIGN_CENTER)

        let title = Gtk.markupLabel(Self.markup(row), css: "row-title")
        gtk_label_set_wrap(op(title), 0)
        gtk_label_set_selectable(op(title), 0)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(title, 1)
        if row.wall != nil { Gtk.addClass(title, "model-row-spent") }

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_box_append(ptr(lines), title)
        if !row.detail.isEmpty {
            let detail = Gtk.label(row.detail, css: "row-detail", selectable: false)
            gtk_label_set_ellipsize(op(detail), PANGO_ELLIPSIZE_END)
            gtk_box_append(ptr(lines), detail)
        }
        gtk_widget_set_hexpand(lines, 1)
        gtk_widget_set_valign(lines, GTK_ALIGN_CENTER)

        let trailing = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 5)
        gtk_widget_set_halign(trailing, GTK_ALIGN_END)
        gtk_widget_set_valign(trailing, GTK_ALIGN_CENTER)
        if let wall = row.wall {
            let pill = Gtk.label(QuotaSurface.rowMark(wall), css: "model-fact", selectable: false)
            gtk_label_set_ellipsize(op(pill), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(pill, QuotaSurface.bannerBody(wall))
            Gtk.addClass(pill, "model-fact-spent")
            gtk_box_append(ptr(trailing), pill)
        }
        for fact in row.facts where !fact.isCapability {
            gtk_box_append(ptr(trailing), Self.factPill(fact))
        }
        let capabilities = row.facts.filter(\.isCapability)
        let marks = Gtk.label(
            capabilities.map(\.tag).joined(separator: " "), css: "model-mark", selectable: false)
        gtk_label_set_ellipsize(op(marks), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_xalign(op(marks), 0)
        gtk_widget_set_valign(marks, GTK_ALIGN_CENTER)
        if !capabilities.isEmpty {
            gtk_widget_set_tooltip_text(marks, capabilities.map(\.label).joined(separator: " · "))
        }
        if let group = markColumn { gtk_size_group_add_widget(ptr(group), marks) }
        gtk_box_append(ptr(trailing), marks)

        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(content, top: 4, bottom: 4, leading: 4, trailing: 6)
        gtk_box_append(ptr(content), tick)
        gtk_box_append(ptr(content), lines)
        gtk_box_append(ptr(content), trailing)
        gtk_button_set_child(ptr(button), content)

        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.activate(index) }
        }

        let wrapper = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        if row.isNested { Gtk.addClass(wrapper, "model-row-nested") }
        if row.isSelected { Gtk.addClass(wrapper, "model-row-current") }
        if index == chooser.cursor { Gtk.addClass(wrapper, "row-focused") }
        gtk_box_append(ptr(wrapper), button)
        guard row.canExpand else {
            let gutter = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_size_request(gutter, Self.chevronWidth, -1)
            gtk_box_append(ptr(wrapper), gutter)
            return wrapper
        }
        if row.canExpand {
            let expanded = row.isExpanded
            let chevron = gtk_button_new()!
            Gtk.addClass(chevron, "flat")
            Gtk.addClass(chevron, "model-chevron")
            gtk_button_set_child(
                ptr(chevron),
                Gtk.label(expanded ? "⌄" : "›", css: "model-chevron-glyph", selectable: false))
            gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
            gtk_widget_set_size_request(chevron, Self.chevronWidth, -1)
            gtk_widget_set_tooltip_text(chevron, Localized.text("The other providers that run it"))
            Gtk.connect(UnsafeMutableRawPointer(chevron), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.chooser.focus(index)
                    _ = self.chooser.setExpanded(!expanded, at: index)
                    self.render(keepingScroll: true, revealingCursor: false)
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

    /// Puts the list back where the reader left it, then brings the focused row into view if the
    /// cursor is what moved — never stealing focus from the search field, because a chooser you
    /// type into cannot hand the caret to the list every time the cursor moves.
    private func settle(at held: Double?, revealingCursor: Bool) {
        holdScroll(at: held)
        guard revealingCursor, chooser.cursor < rowWidgets.count else { return }
        holdScroll(at: nil)
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

    /// A held position, re-asserted for as long as the rebuild is still settling.
    ///
    /// One attempt is not enough, in both directions. `gtk_adjustment_set_value` clamps against
    /// the adjustment's *current* upper, so a position set before the rebuilt box has been
    /// measured is clamped to the top; and a box emptied and refilled passes through a state where
    /// it is one row tall, which clamps a position that had already been set correctly. Either way
    /// the list ends at zero. So the wanted value is held and re-applied on every height the
    /// scroller reports (`notify::upper`) until the rebuild has stopped changing size, and then
    /// let go — a reader who scrolls after that owns the position again.
    private func applyPendingScroll() {
        guard let wanted = pendingScroll,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let page = gtk_adjustment_get_page_size(adjustment)
        let ceiling = max(0, gtk_adjustment_get_upper(adjustment) - page)
        gtk_adjustment_set_value(adjustment, min(max(0, wanted), ceiling))
    }

    /// How long a rebuild is given to stop changing height. Long enough to outlast the frame the
    /// box is refilled on, short enough that it can never be mistaken for the app resisting a
    /// scroll the reader made.
    private static let settleWindow: UInt32 = 250

    private func holdScroll(at value: Double?) {
        pendingScroll = value
        applyPendingScroll()
        guard value != nil else { return }
        let token = scrollGeneration + 1
        scrollGeneration = token
        Gtk.after(Self.settleWindow) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.scrollGeneration == token else { return }
                self.pendingScroll = nil
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
