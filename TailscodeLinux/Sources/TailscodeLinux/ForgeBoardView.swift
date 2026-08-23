import CAdw
import Foundation
import TailscodeCore

/// The forge, drawn as a studio. `ForgeBoard` still decides every word and what pressing something
/// means; this is the composition — the stage is the room, the settings walk as chips, and what was
/// made is a strip of clips rather than another list.
enum ForgeBoardView {
    static func renderer(
        _ board: ForgeBoard, onActivate: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        guard let row = board.rows.first(where: { $0.kind == .field(.endpoint) }) else {
            return Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        }
        let phase = board.sections.first(where: { $0.id == ForgeBoard.rendererID })?.phase ?? .idle
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "forge-renderer")
        if row.id == board.focused?.id { Gtk.addClass(button, "forge-chip-on") }
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(line, top: 6, bottom: 6, leading: 10, trailing: 10)
        let host = Gtk.label(row.title, css: "forge-chip-value", selectable: false)
        gtk_widget_set_hexpand(host, 1)
        gtk_label_set_ellipsize(op(host), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(line), host)
        if let badge = row.badge {
            let pill = Gtk.label(badge, css: "pill", selectable: false)
            Gtk.addClass(pill, tone(for: row, phase: phase))
            gtk_box_append(ptr(line), pill)
        }
        let mark = Gtk.label(ForgeField.endpoint.affordanceGlyph, css: "forge-affordance", selectable: false)
        gtk_box_append(ptr(line), mark)
        gtk_button_set_child(ptr(button), line)
        gtk_widget_set_tooltip_text(button, row.detail)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onActivate)
        return button
    }

    static func model(
        _ board: ForgeBoard, onPick: @escaping @Sendable (String) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let choices = board.choices(of: .model)
        let button = Gtk.menuButton("", css: ["flat", "forge-model"]) {
            choices.map { choice in
                (
                    choice.menuTitle,
                    choice.detail.isEmpty ? nil : choice.detail,
                    { onPick(choice.id) }
                )
            }
        }
        gtk_widget_set_hexpand(button, 1)
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(line, top: 8, bottom: 8, leading: 10, trailing: 10)
        let value = Gtk.label(board.value(of: .model), css: "forge-chip-value", selectable: false)
        gtk_label_set_ellipsize(op(value), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_hexpand(value, 1)
        gtk_label_set_xalign(op(value), 0)
        let mark = Gtk.label(ForgeField.model.affordanceGlyph, css: "forge-affordance", selectable: false)
        gtk_box_append(ptr(line), value)
        gtk_box_append(ptr(line), mark)
        gtk_menu_button_set_child(op(button), line)
        gtk_menu_button_set_always_show_arrow(op(button), 0)
        gtk_widget_set_tooltip_text(button, board.recipe.model.detail)
        gtk_widget_set_sensitive(button, board.isBusy ? 0 : 1)
        return button
    }

    static func chips(
        _ board: ForgeBoard, onPick: @escaping @Sendable (ForgeField, String) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let wrap = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_hexpand(wrap, 1)
        Gtk.addClass(wrap, "forge-chips")
        let fields = ForgeStudio.chips
        let stride = 3
        var index = 0
        while index < fields.count {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            gtk_widget_set_hexpand(row, 1)
            for field in fields[index..<min(index + stride, fields.count)] {
                guard let item = board.rows.first(where: { $0.kind == .field(field) }) else {
                    continue
                }
                let button = chip(
                    item, field: field, board: board, focused: item.id == board.focused?.id,
                    onPick: onPick)
                gtk_widget_set_hexpand(button, 1)
                gtk_box_append(ptr(row), button)
            }
            gtk_box_append(ptr(wrap), row)
            index += stride
        }
        return wrap
    }

    static func filmstrip(
        _ board: ForgeBoard, onActivate: @escaping @Sendable (Int) -> Void,
        onClipMenu: @escaping @Sendable (ForgeEntry, Double, Double) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_min_content_height(op(scroller), Int32(ForgeStudio.filmHeight))
        gtk_widget_set_hexpand(scroller, 1)
        Gtk.addClass(scroller, "forge-film")
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 4, bottom: 2, leading: 2, trailing: 2)
        gtk_widget_set_valign(row, GTK_ALIGN_START)
        guard let section = board.sections.first(where: { $0.id == ForgeBoard.historyID }) else {
            gtk_scrolled_window_set_child(op(scroller), row)
            return scroller
        }
        if section.rows.allSatisfy({ $0.kind == .note }) {
            let empty = Gtk.label(
                section.rows.first?.title ?? "", css: "watch-note", wrap: true, selectable: false)
            gtk_box_append(ptr(row), empty)
        } else {
            for (offset, item) in section.rows.enumerated() {
                let card = filmCard(item, focused: item.id == board.focused?.id) {
                    onActivate(offset)
                }
                if let entry = item.entry {
                    Gtk.onRightClick(card) { x, y in onClipMenu(entry, x, y) }
                }
                gtk_box_append(ptr(row), card)
            }
        }
        gtk_scrolled_window_set_child(op(scroller), row)
        return scroller
    }

    static func stageFace(_ job: ForgeJob) -> UnsafeMutablePointer<GtkWidget> {
        let face = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_widget_set_hexpand(face, 1)
        gtk_widget_set_vexpand(face, 1)
        gtk_widget_set_valign(face, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(face, GTK_ALIGN_CENTER)
        let glyph = Gtk.label(job.phase.stageGlyph, css: "forge-stage-glyph", selectable: false)
        Gtk.addClass(glyph, job.phase.tone.glyphCSS)
        gtk_label_set_xalign(op(glyph), 0.5)
        gtk_box_append(ptr(face), glyph)
        let words = job.isBusy ? (job.stageName ?? job.subtitle) : job.subtitle
        let caption = Gtk.label(words, css: "forge-stage-caption", selectable: false)
        gtk_label_set_xalign(op(caption), 0.5)
        gtk_label_set_wrap(op(caption), 1)
        gtk_label_set_max_width_chars(op(caption), 36)
        gtk_box_append(ptr(face), caption)
        if let fraction = job.fraction {
            let track = bar(fraction)
            gtk_widget_set_size_request(track, 180, -1)
            gtk_widget_set_halign(track, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(face), track)
        }
        return face
    }

    static func status(_ job: ForgeJob) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(job.title, css: "row-title-unread", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(line), title)
        if let badge = job.badge {
            let pill = Gtk.label(badge, css: "pill", selectable: false)
            Gtk.addClass(pill, job.phase.tone == .danger ? "pill-error" : "pill-live")
            gtk_box_append(ptr(line), pill)
        }
        return line
    }

    private static func chip(
        _ row: ForgeRow, field: ForgeField, board: ForgeBoard, focused: Bool,
        onPick: @escaping @Sendable (ForgeField, String) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let choices = board.choices(of: field)
        let button = Gtk.menuButton("", css: ["flat", "forge-chip"]) {
            choices.map { choice in
                (
                    choice.menuTitle,
                    choice.detail.isEmpty ? nil : choice.detail,
                    { onPick(field, choice.id) }
                )
            }
        }
        gtk_menu_button_set_always_show_arrow(op(button), 0)
        if focused { Gtk.addClass(button, "forge-chip-on") }
        if !row.isActivatable { Gtk.addClass(button, "forge-row-spent") }
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.margins(column, top: 4, bottom: 4, leading: 8, trailing: 8)
        let name = Gtk.label(field.label, css: "forge-chip-label", selectable: false)
        gtk_label_set_xalign(op(name), 0)
        let value = Gtk.label(row.detail, css: "forge-chip-value", selectable: false)
        gtk_label_set_xalign(op(value), 0)
        gtk_box_append(ptr(column), name)
        gtk_box_append(ptr(column), value)
        gtk_menu_button_set_child(op(button), column)
        gtk_widget_set_sensitive(button, row.isActivatable ? 1 : 0)
        if let note = row.note, !note.isEmpty {
            gtk_widget_set_tooltip_text(button, note)
        }
        return button
    }

    private static func filmCard(
        _ row: ForgeRow, focused: Bool, onActivate: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        if case .expander = row.kind {
            let button = Gtk.button(row.title, css: ["flat", "forge-film-more"], onClick: onActivate)
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            return button
        }
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "forge-film-card")
        if focused { Gtk.addClass(button, "forge-chip-on") }
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.margins(column, top: 6, bottom: 6, leading: 8, trailing: 8)
        gtk_widget_set_size_request(column, 132, -1)
        let title = Gtk.label(row.title, css: "row-title", selectable: false)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(title), 16)
        gtk_box_append(ptr(column), title)
        if !row.detail.isEmpty {
            let detail = Gtk.label(row.detail, css: "watch-meta", selectable: false)
            gtk_label_set_ellipsize(op(detail), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(op(detail), 16)
            gtk_box_append(ptr(column), detail)
        }
        if let badge = row.badge {
            let pill = Gtk.label(badge, css: "pill", selectable: false)
            Gtk.addClass(pill, row.entry?.isPlayable == true ? "pill-source" : "pill-error")
            gtk_widget_set_halign(pill, GTK_ALIGN_START)
            gtk_box_append(ptr(column), pill)
        }
        gtk_button_set_child(ptr(button), column)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onActivate)
        return button
    }

    private static func bar(_ fraction: Double) -> UnsafeMutablePointer<GtkWidget> {
        let bar = gtk_progress_bar_new()!
        Gtk.addClass(bar, "forge-bar")
        gtk_progress_bar_set_fraction(op(bar), min(max(fraction, 0), 1))
        gtk_widget_set_hexpand(bar, 1)
        return bar
    }

    private static func tone(for row: ForgeRow, phase: ForgePhase) -> String {
        if let entry = row.entry { return entry.isPlayable ? "pill-source" : "pill-error" }
        switch phase {
        case .ready: return "pill-live"
        case .failed: return "pill-error"
        case .checking: return "pill-source"
        case .idle: return "pill-offline"
        }
    }
}
