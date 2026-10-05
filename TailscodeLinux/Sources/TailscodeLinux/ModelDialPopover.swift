import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The composer's one dial, opened: the models a person reaches for beside the effort ladder of
/// the model this chat runs, so which machine and how hard are decided in one place.
///
/// Every decision is `ModelDialState`'s — the rows, the rungs, the cursor, what each key does.
/// This class draws the answer and forwards presses: a model row commits through `onPick` with the
/// level the ladder showed for it and the popover closes; a rung on this chat's own model is live
/// through `onEffort` and the popover stays, because a level is something a person nudges while
/// looking at the ladder, not something they submit. On any other row the ladder is a preview of
/// that model's levels, and a rung pressed there only travels with the pick.
final class ModelDialPopover: @unchecked Sendable {
    let popover: UnsafeMutablePointer<GtkWidget>
    private var state: ModelDialState?
    private let makeState: @Sendable () -> ModelDialState
    private let onPick: @Sendable (ModelPick, EffortAsk, String?) -> Void
    private let onEffort: @Sendable (String?) -> Void
    private let onOpenCatalog: @Sendable () -> Void
    private var entry: UnsafeMutablePointer<GtkWidget>?
    private var modelsColumn: UnsafeMutablePointer<GtkWidget>?
    private var ladderColumn: UnsafeMutablePointer<GtkWidget>?
    private var rowWidgets: [UInt] = []
    private var rungWidgets: [(level: String?, widget: UInt)] = []
    private var scroller: UnsafeMutablePointer<GtkWidget>?
    private var modelsPane: UnsafeMutablePointer<GtkWidget>?
    private var ladderSignature = ""

    init(
        makeState: @escaping @Sendable () -> ModelDialState,
        onPick: @escaping @Sendable (ModelPick, EffortAsk, String?) -> Void,
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
            Gtk.onMain { [weak self] in self?.fill() }
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
    func fill() {
        state = makeState()
        let shell = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let columns = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        let models = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(models, "dial-models")
        modelsPane = models
        gtk_widget_set_size_request(models, 430, -1)
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
        modelsPane = nil
        ladderSignature = ""
        rowWidgets = []
        rungWidgets = []
        state = nil
        gtk_popover_set_child(ptr(popover), nil)
    }

    /// What the dial holds right now, for a harness that has to prove what it drew.
    var current: ModelDialState? { state }

    /// A key arriving the way a press does, for the drive verbs and the self-test.
    func press(keyval: UInt32, state: UInt32 = 0) -> Bool {
        key(keyval: keyval, state: state)
    }

    func search(_ text: String) {
        guard let entry else { return }
        gtk_editable_set_text(op(entry), text)
        queryChanged()
    }

    var drawsPreview: Bool {
        ladderColumn.map { gtk_widget_has_css_class($0, "dial-ladder-preview") != 0 } ?? false
    }

    var activeColumnIsLadder: Bool {
        ladderColumn.map { gtk_widget_has_css_class($0, "dial-column-active") != 0 } ?? false
    }

    var drawnRows: Int { rowWidgets.count }

    private func queryChanged() {
        guard let entry, let raw = gtk_editable_get_text(op(entry)) else { return }
        state?.search(String(cString: raw))
        renderModels()
        renderLadder()
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
            renderLadder()
            return true
        case .effort(let level):
            onEffort(level)
            syncLadder()
            return true
        case .previewed:
            renderLadder()
            return true
        case .pick(let pick, let effort):
            let notice = state?.pickNotice
            gtk_popover_popdown(ptr(popover))
            onPick(pick, effort, notice)
            return true
        case .openCatalog:
            gtk_popover_popdown(ptr(popover))
            onOpenCatalog()
            return true
        case .pinned(let preset):
            ModelPresetStore.pin(preset)
            SettingsFile.capture()
            renderModels()
            renderLadder()
            return true
        case .dismiss:
            gtk_popover_popdown(ptr(popover))
            return true
        }
    }

    /// The column is rebuilt when its rows change — a query, a pin — and only re-lit when the
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
                dial.rows[index - 1].candidate != nil || dial.rows[index - 1].isMessage
            {
                let rule = Gtk.hairline()
                Gtk.margins(rule, top: 6, bottom: 4, leading: 6, trailing: 6)
                gtk_box_append(ptr(column), rule)
            }
            let widget = row.isMessage ? makeMessage(row) : makeRow(row, at: index)
            rowWidgets.append(UInt(bitPattern: widget))
            gtk_box_append(ptr(column), widget)
        }
        syncCursor()
    }

    /// A row that answers rather than offers — a search that found nothing — is two quiet lines
    /// and no control: nothing to hover, nothing to press, no star to set.
    private func makeMessage(_ row: ModelDialRow) -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(box, "dial-message")
        Gtk.margins(box, top: 10, bottom: 10, leading: 12, trailing: 12)
        let title = Gtk.label(row.title, css: "dial-message-title", wrap: true, selectable: false)
        gtk_box_append(ptr(box), title)
        if !row.detail.isEmpty {
            gtk_box_append(
                ptr(box),
                Gtk.label(row.detail, css: "dial-message-detail", wrap: true, selectable: false))
        }
        return box
    }

    private func makeRow(_ row: ModelDialRow, at index: Int) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "dial-row")
        if row.isCurrent { Gtk.addClass(button, "dial-row-here") }
        if row.opensCatalog { Gtk.addClass(button, "dial-row-door") }
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(line, top: 5, bottom: 5, leading: 8, trailing: 8)
        let star = Gtk.label(
            row.candidate == nil ? "" : (row.isStarred ? "★" : "☆"), css: "dial-star",
            selectable: false)
        if row.isStarred { Gtk.addClass(star, "dial-star-on") }
        gtk_widget_set_size_request(star, 12, -1)
        gtk_widget_set_valign(star, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), star)
        gtk_box_append(ptr(line), Self.familyDot(for: row))
        let title = Gtk.label(row.title, css: "dial-title", selectable: false)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(title), 24)
        gtk_widget_set_valign(title, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), title)
        for fact in row.facts where fact == .vision || fact == .pdf || fact == .local {
            let chip = Gtk.label(fact.tag, css: "dial-chip", selectable: false)
            if fact == .local { Gtk.addClass(chip, "dial-chip-local") }
            gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(chip, fact.label)
            gtk_box_append(ptr(line), chip)
        }
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(line), spacer)
        if let wall = row.wall {
            let note = Gtk.label(QuotaSurface.rowNote(wall), css: "dial-wall", selectable: false)
            gtk_widget_set_valign(note, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), note)
        }
        let showsDetail = row.level == nil || row.candidate?.isElsewhere == true
        if showsDetail, !row.detail.isEmpty {
            let detail = Gtk.label(row.detail, css: "dial-detail", selectable: false)
            gtk_label_set_ellipsize(op(detail), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(op(detail), row.candidate == nil ? 28 : 16)
            gtk_widget_set_valign(detail, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), detail)
        }
        if let level = row.level {
            gtk_box_append(ptr(line), Self.levelMark(level))
        }
        let check = Gtk.label(row.isCurrent ? "✓" : "", css: "dial-check", selectable: false)
        gtk_widget_set_size_request(check, 12, -1)
        gtk_widget_set_valign(check, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), check)
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

    /// Who answers, as a dot in the family's hue: the server's own choice is a ring, because it
    /// names no model, and the door to the catalog wears nothing.
    private static func familyDot(for row: ModelDialRow) -> UnsafeMutablePointer<GtkWidget> {
        let dot = Gtk.label("", css: "dial-row-dot", selectable: false)
        gtk_widget_set_size_request(dot, 10, -1)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        if let candidate = row.candidate {
            gtk_label_set_text(op(dot), "●")
            let chip = ModelBadge.chip(model: candidate.selection.modelID, effort: nil)
            Gtk.addClass(
                dot, ModelTint.identityClass(family: chip?.family, name: chip?.name ?? candidate.name))
        } else if row.kind == .serverDefault {
            gtk_label_set_text(op(dot), "○")
        }
        return dot
    }

    /// A pinned pair's level, drawn as the pill draws it: the word in ink beside the same five
    /// bars in the tier's heat, so the row promises exactly what the pill will then say.
    static func levelMark(_ level: ModelDialRow.Level) -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(box, "dial-row-level")
        gtk_widget_set_valign(box, GTK_ALIGN_CENTER)
        let word: UnsafeMutablePointer<GtkWidget>
        if level.isPower {
            word = Gtk.markupLabel(rainbowMarkup(level.word), css: "dial-level-word", wrap: false)
            gtk_label_set_selectable(op(word), 0)
        } else {
            word = Gtk.label(level.word, css: "dial-level-word", selectable: false)
        }
        if level.isServer { Gtk.addClass(word, "dial-level-server") }
        gtk_widget_set_valign(word, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(box), word)
        let meter = meter(
            heat: level.heat, tint: level.isServer ? nil : ModelTint.effortClass(level.word),
            rainbow: level.isPower, ember: level.isEmber)
        gtk_widget_set_valign(meter, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(box), meter)
        return box
    }

    private func syncCursor() {
        guard let dial = state else { return }
        for (index, bits) in rowWidgets.enumerated() {
            guard let widget = UnsafeMutablePointer<GtkWidget>(bitPattern: bits) else { continue }
            if index == dial.cursor, !dial.rows[index].isMessage {
                gtk_widget_add_css_class(widget, "dial-row-cursor")
                revealRow(widget)
            } else {
                gtk_widget_remove_css_class(widget, "dial-row-cursor")
            }
        }
        syncColumn()
    }

    /// The column the arrows drive wears the accent on its edge, so ⇥ moving them is seen
    /// rather than discovered by pressing ↓ and watching the wrong thing move.
    private func syncColumn() {
        guard let dial = state else { return }
        for (widget, column) in [(modelsPane, ModelDialState.Column.models), (ladderColumn, .ladder)] {
            guard let widget else { continue }
            if dial.column == column {
                gtk_widget_add_css_class(widget, "dial-column-active")
            } else {
                gtk_widget_remove_css_class(widget, "dial-column-active")
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

    /// The ladder follows the cursor, so it is redrawn whenever what it is the ladder of changes —
    /// another model's levels, a preview turning live, a carry sentence appearing — and only
    /// re-lit when nothing but the level moved.
    private func renderLadder() {
        guard let ladder = ladderColumn, let dial = state else { return }
        let signature = [
            dial.rungs.map(\.id).joined(separator: ","), dial.headline,
            dial.ladderIsPreview ? "preview" : "live", dial.carryNotice ?? "",
        ].joined(separator: "|")
        guard signature != ladderSignature else {
            syncLadder()
            return
        }
        ladderSignature = signature
        Gtk.removeChildren(of: ladder)
        rungWidgets = []
        if dial.ladderIsPreview {
            gtk_widget_add_css_class(ladder, "dial-ladder-preview")
        } else {
            gtk_widget_remove_css_class(ladder, "dial-ladder-preview")
        }
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let word = Gtk.label(Localized.text("EFFORT"), css: "dial-section", selectable: false)
        gtk_widget_set_hexpand(word, 1)
        gtk_box_append(ptr(head), word)
        if dial.ladderIsPreview {
            let tag = Gtk.label(Localized.text("preview"), css: "dial-preview-tag", selectable: false)
            gtk_widget_set_tooltip_text(
                tag, Localized.text("The ladder shows the levels of the row you are on."))
            gtk_box_append(ptr(head), tag)
        }
        Gtk.margins(head, bottom: 2, leading: 2, trailing: 2)
        gtk_box_append(ptr(ladder), head)
        let headline = Gtk.label(dial.headline, css: "dial-headline", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(headline), 34)
        Gtk.margins(headline, bottom: 4, leading: 2, trailing: 2)
        gtk_box_append(ptr(ladder), headline)
        for rung in dial.rungs where ModelEffort.isOffered(options: dial.focusedOptions) {
            let button = makeRung(rung)
            rungWidgets.append((rung.level, UInt(bitPattern: button)))
            gtk_box_append(ptr(ladder), button)
        }
        if let notice = dial.carryNotice {
            let line = Gtk.label(notice, css: "dial-carry", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(line), 34)
            Gtk.margins(line, top: 6, leading: 2, trailing: 2)
            gtk_box_append(ptr(ladder), line)
        }
        syncLadder()
        syncColumn()
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
        let meter = Self.meter(
            heat: rung.heat, tint: rung.level.flatMap(ModelTint.effortClass),
            rainbow: rung.isPower, ember: rung.isEmber)
        gtk_widget_set_valign(meter, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), meter)
        gtk_button_set_child(ptr(button), line)
        let level = rung.level
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, var dial = self.state else { return }
                let outcome = dial.setEffort(level)
                self.state = dial
                _ = self.act(on: outcome)
            }
        }
        return button
    }

    private func syncLadder() {
        guard let dial = state else { return }
        let lit = dial.currentRung
        for (level, bits) in rungWidgets {
            guard let widget = UnsafeMutablePointer<GtkWidget>(bitPattern: bits) else { continue }
            if let lit, level == lit.level {
                gtk_widget_add_css_class(widget, "dial-rung-current")
            } else {
                gtk_widget_remove_css_class(widget, "dial-rung-current")
            }
        }
    }

    /// Five bars, lit to the heat: the same meter the pill wears, so what the ladder promises and
    /// what the pill then shows are one drawing. An ember lights its bar dimly, which is how a
    /// level under low is told from low itself.
    static func meter(
        heat: Int, tint: String?, rainbow: Bool, ember: Bool = false
    ) -> UnsafeMutablePointer<GtkWidget> {
        let meter = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        Gtk.addClass(meter, "dial-meter")
        for index in 0..<EffortMeter.bars {
            let bar = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(bar, "dial-bar")
            Gtk.addClass(bar, "dial-bar-\(index)")
            if index < heat {
                Gtk.addClass(bar, "dial-bar-lit")
                if ember { Gtk.addClass(bar, "dial-bar-ember") }
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

    /// The power's word, one letter per rainbow stop, held to the canvas's contrast floor;
    /// `phase` rotates the stops along the word so the rainbow can travel.
    static func rainbowMarkup(_ word: String, phase: Int = 0) -> String {
        var colours = ModelTint.rainbow(letters: word.count, onCanvas: MatrixTheme.palette.canvas)
        if !colours.isEmpty {
            let shift = ((phase % colours.count) + colours.count) % colours.count
            colours = Array(colours[shift...] + colours[..<shift])
        }
        return zip(word, colours).map { letter, hex in
            "<span foreground=\"\(hex)\">\(PangoMarkdown.escape(String(letter)))</span>"
        }.joined()
    }
}
