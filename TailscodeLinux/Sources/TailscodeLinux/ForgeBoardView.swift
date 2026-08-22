import CAdw
import Foundation
import TailscodeCore

/// The forge, drawn. `ForgeBoard` decides the four sections — the renderer and whether it answered,
/// the render in hand, what the next one is made from, and the clips already made — and this turns
/// each of them into a heading and its rows. Nothing here decides what a row says, which state it
/// is in, or what pressing it means: every word comes off the row, and the only judgement made
/// here is which of the app's existing tones a badge wears.
///
/// Rebuilt whole on every snapshot, like the watch board beside it. A render yields several job
/// snapshots a second and a section is a few dozen widgets, so rebuilding costs less than keeping
/// a tree and a model in agreement about a shape that changes every time a phase does.
enum ForgeBoardView {
    /// The board, and where in it the cursor sits — reported as the child's position rather than as
    /// its pointer, because the board is rebuilt on every snapshot and a pointer handed across a
    /// frame is a pointer to a widget that may already be gone.
    static func make(
        _ model: ForgeBoard, onActivate: @escaping @Sendable (String, Int) -> Void,
        onCall: @escaping @Sendable () -> Void,
        onClipMenu: @escaping @Sendable (ForgeEntry, Double, Double) -> Void
    ) -> (root: UnsafeMutablePointer<GtkWidget>, focused: Int?) {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(column, 1)
        var cursorAt: Int?
        var position = 0

        for section in model.sections {
            let call = section.id == ForgeBoard.renderID ? onCall : nil
            gtk_box_append(ptr(column), header(section, call: call))
            position += 1
            for (offset, row) in section.rows.enumerated() {
                let isFocused = row.id == model.focused?.id
                let widget = make(row, phase: section.phase, focused: isFocused) {
                    onActivate(section.id, offset)
                }
                if isFocused { cursorAt = position }
                if let entry = row.entry {
                    Gtk.onRightClick(widget) { x, y in onClipMenu(entry, x, y) }
                }
                gtk_box_append(ptr(column), widget)
                position += 1
            }
        }
        return (column, cursorAt)
    }

    /// A section's heading. The render section's detail is not a caption but the caption of the
    /// button — `ForgeBoard.renderCall` is the answer to "what does pressing this do", said in
    /// four different words in four different states — so it is drawn as the button it describes
    /// rather than as dim text beside a row somebody has to find.
    private static func header(
        _ section: ForgeSection, call: (@Sendable () -> Void)?
    ) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(section.title, css: "section-header", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(line), title)
        guard section.detail.isEmpty == false else {
            Gtk.margins(line, trailing: 8)
            return line
        }
        if let call {
            let button = Gtk.button(section.detail, css: ["forge-call"], onClick: call)
            gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), button)
        } else {
            let detail = Gtk.label(section.detail, css: "watch-section-detail", selectable: false)
            gtk_widget_set_valign(detail, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), detail)
        }
        Gtk.margins(line, trailing: 8)
        return line
    }

    private static func make(
        _ row: ForgeRow, phase: ForgePhase, focused: Bool,
        onActivate: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        if case .note = row.kind { return note(row) }
        guard row.isActivatable else { return spent(row, phase: phase) }
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        if focused { Gtk.addClass(button, "row-focused") }
        if row.isPrimary { Gtk.addClass(button, "forge-render-row") }
        gtk_button_set_child(ptr(button), lines(row, phase: phase))
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onActivate)
        return button
    }

    /// A line the board owed the reader — that a section is being asked, that nothing has been
    /// rendered yet, or why one stopped. It is a label, never a button: nothing here does anything,
    /// and drawing it as a row that hovers would promise otherwise.
    private static func note(_ row: ForgeRow) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(row.title, css: "watch-note", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(label), 44)
        Gtk.margins(label, top: 2, bottom: 4, leading: 8, trailing: 8)
        return label
    }

    /// A setting the render in flight has already consumed. It keeps its label and its value —
    /// what the render was started with is exactly what a person watching it wants to read — and
    /// loses only the ability to be pressed, which is the honest thing for a row whose value the
    /// other machine is already working from.
    private static func spent(
        _ row: ForgeRow, phase: ForgePhase
    ) -> UnsafeMutablePointer<GtkWidget> {
        let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(holder, "forge-row-spent")
        Gtk.margins(holder, top: 4, bottom: 4, leading: 4, trailing: 6)
        gtk_box_append(ptr(holder), lines(row, phase: phase))
        return holder
    }

    private static func lines(
        _ row: ForgeRow, phase: ForgePhase
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.margins(column, top: 4, bottom: 4, leading: 4, trailing: 6)
        gtk_widget_set_hexpand(column, 1)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(
            row.title, css: row.isPrimary ? "row-title-unread" : "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if let badge = row.badge {
            let pill = Gtk.label(badge, css: "pill", selectable: false)
            Gtk.addClass(pill, tone(for: row, phase: phase))
            gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(titleRow), pill)
        }
        gtk_box_append(ptr(column), titleRow)

        if !row.detail.isEmpty {
            let detail = Gtk.label(
                row.detail, css: row.isPrimary ? "forge-state" : "row-detail", wrap: row.isPrimary,
                selectable: false)
            gtk_label_set_max_width_chars(op(detail), 52)
            gtk_box_append(ptr(column), detail)
        }
        if let fraction = row.fraction {
            gtk_box_append(ptr(column), bar(fraction))
        }
        if let note = row.note, !note.isEmpty {
            gtk_box_append(
                ptr(column), Gtk.label(note, css: "watch-meta", selectable: false))
        }
        return column
    }

    /// The render's own bar, drawn only where the board handed one over. Submitting and queueing
    /// carry no fraction on purpose — there is nothing honest to fill — so those states get the
    /// word in the corner and no bar at all rather than a bar that has not moved.
    private static func bar(_ fraction: Double) -> UnsafeMutablePointer<GtkWidget> {
        let bar = gtk_progress_bar_new()!
        Gtk.addClass(bar, "forge-bar")
        gtk_progress_bar_set_fraction(op(bar), min(max(fraction, 0), 1))
        gtk_widget_set_hexpand(bar, 1)
        Gtk.margins(bar, top: 2, bottom: 2)
        return bar
    }

    /// Which of the app's existing pill tones a badge wears. Read off state rather than off the
    /// word inside the badge: a clip says whether its file is still fetchable, and every other row
    /// takes its section's phase, so nothing here has to recognise a string Core is free to reword.
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
