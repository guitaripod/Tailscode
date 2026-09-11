import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The composer's one dial, opened: the models a person reaches for beside the effort ladder of
/// the model this chat runs, so which machine and how hard are decided in one place.
///
/// Every decision is `ModelDialState`'s — the rows, the rungs, the cursor, what each key does.
/// This class draws the answer and forwards presses: a model row commits through `onPick` and the
/// popover closes; a rung is live through `onEffort` and the popover stays, because a level is
/// something a person nudges while looking at the ladder, not something they submit.
final class ModelDialPopover: @unchecked Sendable {
    let popover: UnsafeMutablePointer<GtkWidget>
    private var state: ModelDialState?
    private let makeState: @Sendable () -> ModelDialState
    private let onPick: @Sendable (ModelPick) -> Void
    private let onEffort: @Sendable (String?) -> Void
    private let onOpenCatalog: @Sendable () -> Void
    private var entry: UnsafeMutablePointer<GtkWidget>?
    private var modelsColumn: UnsafeMutablePointer<GtkWidget>?
    private var ladderColumn: UnsafeMutablePointer<GtkWidget>?
    private var rowWidgets: [UInt] = []
    private var rungWidgets: [(level: String?, widget: UInt)] = []
    private var scroller: UnsafeMutablePointer<GtkWidget>?

    init(
        makeState: @escaping @Sendable () -> ModelDialState,
        onPick: @escaping @Sendable (ModelPick) -> Void,
        onEffort: @escaping @Sendable (String?) -> Void,
        onOpenCatalog: @escaping @Sendable () -> Void
    ) {
        self.makeState = makeState
        self.onPick = onPick
        self.onEffort = onEffort
        self.onOpenCatalog = onOpenCatalog
        popover = gtk_popover_new()!
        Gtk.addClass(popover, "dial-pop")
        gtk_popover_set_has_arrow(ptr(popover), 1)
        Gtk.connect(UnsafeMutableRawPointer(popover), "map") { [weak self] in
            Gtk.onMain { [weak self] in self?.open() }
        }
        Gtk.connect(UnsafeMutableRawPointer(popover), "closed") { [weak self] in
            Gtk.onMain { [weak self] in self?.tearDown() }
        }
        Gtk.onKey(popover) { [weak self] keyval, state in
            guard let self else { return false }
            return self.key(keyval: keyval, state: state)
        }
    }

    /// The dial re-reads the composer every time it opens: a chat may have changed model under
    /// it, and a level nudged with the wheel since is the level the ladder must light.
    private func open() {
        state = makeState()
        let shell = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let columns = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        let models = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(models, "dial-models")
        gtk_widget_set_size_request(models, 400, -1)
        let search = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(search), Localized.text("Search every model"))
        Gtk.addClass(search, "dial-search")
        Gtk.margins(search, top: 10, bottom: 6, leading: 10, trailing: 10)
        Gtk.connect(UnsafeMutableRawPointer(search), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.queryChanged() }
        }
        entry = search
        gtk_box_append(ptr(models), search)
        let list = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(list), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(op(list), 400)
        gtk_scrolled_window_set_propagate_natural_height(op(list), 1)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        Gtk.margins(column, top: 0, bottom: 6, leading: 6, trailing: 6)
        gtk_scrolled_window_set_child(op(list), column)
        gtk_box_append(ptr(models), list)
        scroller = list
        modelsColumn = column
        gtk_box_append(ptr(columns), models)

        let divider = gtk_separator_new(GTK_ORIENTATION_VERTICAL)!
        Gtk.addClass(divider, "dial-divider")
        gtk_box_append(ptr(columns), divider)

        let ladder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.addClass(ladder, "dial-ladder")
        gtk_widget_set_size_request(ladder, 290, -1)
        Gtk.margins(ladder, top: 12, bottom: 10, leading: 12, trailing: 12)
        ladderColumn = ladder
        gtk_box_append(ptr(columns), ladder)
        gtk_box_append(ptr(shell), columns)

        let foot = Gtk.label(ModelDial.hint, css: "dial-hint", selectable: false)
        Gtk.margins(foot, top: 4, bottom: 8, leading: 14, trailing: 14)
        gtk_box_append(ptr(shell), Gtk.hairline())
        gtk_box_append(ptr(shell), foot)
        gtk_popover_set_child(ptr(popover), shell)
        renderModels()
        renderLadder()
        gtk_widget_grab_focus(search)
    }

    private func tearDown() {
        entry = nil
        modelsColumn = nil
        ladderColumn = nil
        scroller = nil
        rowWidgets = []
        rungWidgets = []
        state = nil
        gtk_popover_set_child(ptr(popover), nil)
    }

    private func queryChanged() {
        guard let entry, let raw = gtk_editable_get_text(op(entry)) else { return }
        state?.search(String(cString: raw))
        renderModels()
    }

    private func key(keyval: UInt32, state: UInt32) -> Bool {
        guard var dial = self.state,
            let chord = KeyChord.canonical(keyval: keyval, state: state),
            let command = ModelDialState.command(for: chord, digitsLive: dial.digitsPickEffort)
        else { return false }
        let outcome = dial.handle(command)
        self.state = dial
        return act(on: outcome)
    }

    private func act(on outcome: ModelDialOutcome) -> Bool {
        switch outcome {
        case .unhandled:
            return false
        case .moved:
            syncCursor()
            return true
        case .effort(let level):
            onEffort(level)
            syncLadder()
            return true
        case .pick(let pick):
            gtk_popover_popdown(ptr(popover))
            onPick(pick)
            return true
        case .openCatalog:
            gtk_popover_popdown(ptr(popover))
            onOpenCatalog()
            return true
        case .starred(let selection):
            ModelFavoritesStore.toggle(selection)
            renderModels()
            return true
        case .dismiss:
            gtk_popover_popdown(ptr(popover))
            return true
        }
    }

    /// The column is rebuilt when its rows change — a query, a star — and only re-lit when the
    /// cursor moves, so walking the list never scrolls it under the hand.
    private func renderModels() {
        guard let column = modelsColumn, let dial = state else { return }
        Gtk.removeChildren(of: column)
        rowWidgets = []
        for (index, row) in dial.rows.enumerated() {
            if let section = row.section {
                let heading = Gtk.label(section.uppercased(), css: "dial-section", selectable: false)
                Gtk.margins(heading, top: index == 0 ? 4 : 10, bottom: 2, leading: 8, trailing: 8)
                gtk_box_append(ptr(column), heading)
            }
            if row.kind == .serverDefault || row.opensCatalog, index > 0,
                dial.rows[index - 1].candidate != nil
            {
                let rule = Gtk.hairline()
                Gtk.margins(rule, top: 6, bottom: 4, leading: 6, trailing: 6)
                gtk_box_append(ptr(column), rule)
            }
            let button = makeRow(row, at: index)
            rowWidgets.append(UInt(bitPattern: button))
            gtk_box_append(ptr(column), button)
        }
        syncCursor()
    }

    private func makeRow(_ row: ModelDialRow, at index: Int) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "dial-row")
        if row.isCurrent { Gtk.addClass(button, "dial-row-here") }
        if row.opensCatalog { Gtk.addClass(button, "dial-row-door") }
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(line, top: 5, bottom: 5, leading: 8, trailing: 8)
        if row.candidate != nil {
            let star = Gtk.label(row.isStarred ? "★" : "☆", css: "dial-star", selectable: false)
            if row.isStarred { Gtk.addClass(star, "dial-star-on") }
            gtk_widget_set_valign(star, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), star)
        }
        let title = Gtk.label(row.title, css: "dial-title", selectable: false)
        gtk_label_set_width_chars(op(title), 16)
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_valign(title, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), title)
        for fact in row.facts where fact == .vision || fact == .pdf || fact == .local {
            let chip = Gtk.label(fact.tag, css: "dial-chip", selectable: false)
            if fact == .local { Gtk.addClass(chip, "dial-chip-local") }
            gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(chip, fact.label)
            gtk_box_append(ptr(line), chip)
        }
        if let wall = row.wall {
            let note = Gtk.label(QuotaSurface.rowNote(wall), css: "dial-wall", selectable: false)
            gtk_widget_set_valign(note, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), note)
        }
        if !row.detail.isEmpty {
            let detail = Gtk.label(row.detail, css: "dial-detail", selectable: false)
            gtk_label_set_max_width_chars(op(detail), row.candidate == nil ? 28 : 16)
            gtk_widget_set_valign(detail, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), detail)
        }
        gtk_button_set_child(ptr(button), line)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, var dial = self.state else { return }
                dial.move(to: index)
                let outcome = dial.handle(.activate)
                self.state = dial
                _ = self.act(on: outcome)
            }
        }
        return button
    }

    private func syncCursor() {
        guard let dial = state else { return }
        for (index, bits) in rowWidgets.enumerated() {
            guard let widget = UnsafeMutablePointer<GtkWidget>(bitPattern: bits) else { continue }
            if index == dial.cursor {
                gtk_widget_add_css_class(widget, "dial-row-cursor")
                revealRow(widget)
            } else {
                gtk_widget_remove_css_class(widget, "dial-row-cursor")
            }
        }
    }

    /// Keeps the row under the cursor inside the scrolled column, moving the list only as far
    /// as it takes to show it.
    private func revealRow(_ widget: UnsafeMutablePointer<GtkWidget>) {
        guard let scroller, let column = modelsColumn,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        guard let bounds = Gtk.bounds(of: widget, in: column) else { return }
        let top = bounds.y
        let height = bounds.height
        let page = gtk_adjustment_get_page_size(adjustment)
        let value = gtk_adjustment_get_value(adjustment)
        if top < value {
            gtk_adjustment_set_value(adjustment, top)
        } else if top + height > value + page {
            gtk_adjustment_set_value(adjustment, top + height - page)
        }
    }

    private func renderLadder() {
        guard let ladder = ladderColumn, let dial = state else { return }
        Gtk.removeChildren(of: ladder)
        rungWidgets = []
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let word = Gtk.label(Localized.text("EFFORT"), css: "dial-section", selectable: false)
        gtk_widget_set_hexpand(word, 1)
        gtk_box_append(ptr(head), word)
        let headline = Gtk.label(dial.headline, css: "dial-headline", selectable: false)
        gtk_label_set_xalign(op(headline), 1)
        gtk_box_append(ptr(head), headline)
        Gtk.margins(head, bottom: 4, leading: 2, trailing: 2)
        gtk_box_append(ptr(ladder), head)
        for rung in dial.rungs {
            let button = makeRung(rung)
            rungWidgets.append((rung.level, UInt(bitPattern: button)))
            gtk_box_append(ptr(ladder), button)
        }
        syncLadder()
    }

    private func makeRung(_ rung: EffortRung) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "dial-rung")
        if let cls = rung.level.flatMap(ModelTint.effortClass) { Gtk.addClass(button, cls) }
        if rung.isServer { Gtk.addClass(button, "dial-rung-server") }
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(line, top: 5, bottom: 5, leading: 8, trailing: 10)
        let key = Gtk.label(String(rung.key), css: "dial-rung-key", selectable: false)
        gtk_widget_set_valign(key, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(key, 14, -1)
        gtk_box_append(ptr(line), key)
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_hexpand(words, 1)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        let title: UnsafeMutablePointer<GtkWidget>
        if rung.isPower {
            title = Gtk.markupLabel(
                Self.rainbowMarkup(rung.title), css: "dial-rung-title", wrap: false)
            gtk_label_set_selectable(op(title), 0)
        } else {
            title = Gtk.label(rung.title, css: "dial-rung-title", selectable: false)
        }
        gtk_box_append(ptr(words), title)
        if !rung.caption.isEmpty {
            gtk_box_append(
                ptr(words), Gtk.label(rung.caption, css: "dial-rung-caption", selectable: false))
        }
        gtk_box_append(ptr(line), words)
        if !rung.isServer {
            let meter = Self.meter(
                heat: rung.heat, tint: rung.level.flatMap(ModelTint.effortClass),
                rainbow: rung.isPower)
            gtk_widget_set_valign(meter, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), meter)
        }
        gtk_button_set_child(ptr(button), line)
        let level = rung.level
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, var dial = self.state else { return }
                dial.setEffort(level)
                self.state = dial
                _ = self.act(on: .effort(dial.effort))
            }
        }
        return button
    }

    private func syncLadder() {
        guard let dial = state else { return }
        for (level, bits) in rungWidgets {
            guard let widget = UnsafeMutablePointer<GtkWidget>(bitPattern: bits) else { continue }
            if level == dial.effort {
                gtk_widget_add_css_class(widget, "dial-rung-current")
            } else {
                gtk_widget_remove_css_class(widget, "dial-rung-current")
            }
        }
    }

    /// Five bars, lit to the heat: the same meter the pill wears, so what the ladder promises and
    /// what the pill then shows are one drawing.
    static func meter(heat: Int, tint: String?, rainbow: Bool) -> UnsafeMutablePointer<GtkWidget> {
        let meter = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        Gtk.addClass(meter, "dial-meter")
        for index in 0..<EffortMeter.bars {
            let bar = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(bar, "dial-bar")
            if index < heat {
                Gtk.addClass(bar, "dial-bar-lit")
                if rainbow {
                    Gtk.addClass(bar, "dial-bar-rainbow-\(index)")
                } else if let tint {
                    Gtk.addClass(bar, tint)
                }
            }
            gtk_box_append(ptr(meter), bar)
        }
        return meter
    }

    /// The power's word, one letter per rainbow stop, held to the canvas's contrast floor.
    static func rainbowMarkup(_ word: String) -> String {
        let colours = ModelTint.rainbow(letters: word.count, onCanvas: MatrixTheme.palette.canvas)
        return zip(word, colours).map { letter, hex in
            "<span foreground=\"\(hex)\">\(PangoMarkdown.escape(String(letter)))</span>"
        }.joined()
    }
}
