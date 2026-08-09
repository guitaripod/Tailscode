import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Every kind of row the chat list can draw, in one place: a section heading, a conversation, the
/// banner that says a server stopped answering, and the line that admits there is nothing here.
enum SidebarRow {
    static func header(_ title: String, count: Int) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let label = Gtk.label(title, css: "section-header", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        let tally = Gtk.label("\(count)", css: "section-header", selectable: false)
        gtk_label_set_ellipsize(op(tally), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_size_request(tally, 34, -1)
        gtk_box_append(ptr(row), label)
        gtk_box_append(ptr(row), tally)
        return row
    }

    static func banner(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "row-detail", wrap: true, selectable: false)
        Gtk.addClass(label, "glyph-error")
        Gtk.margins(label, top: 8, bottom: 8, leading: 12, trailing: 12)
        return label
    }

    /// The heading over what happened while nobody was here, with the way to dismiss the lot. The
    /// clear lives in the header rather than on each row: the list is read all at once or not at
    /// all, and a per-row dismiss turns catching up into filing.
    static func missedHeader(count: Int, onClear: @escaping @Sendable () -> Void)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let label = Gtk.label(
            Localized.text("MISSED"), css: "section-header", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), label)
        let clear = Gtk.button(Localized.text("clear"), css: ["flat", "dim"], onClick: onClear)
        gtk_widget_set_valign(clear, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(
            clear, Localized.text("Clear all %@ missed notices", "\(count)"))
        gtk_box_append(ptr(row), clear)
        return row
    }

    /// One thing that happened out of sight: what it was, in which chat, and how long ago.
    static func missed(_ item: MissedActivity, onOpen: @escaping @Sendable () -> Void)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")

        let face = item.reason.face
        let glyph = Gtk.label(
            face.glyph,
            css: item.isBlocking
                ? face.tone.glyphCSS : item.reason == .turnFailed ? "glyph-error" : "glyph-done",
            selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        Gtk.margins(glyph, top: 3)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(item.title, css: "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if item.isBlocking {
            gtk_box_append(ptr(titleRow), makePill(item.kindLabel.uppercased(), css: "pill-needs"))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), titleRow)
        gtk_box_append(
            ptr(column),
            Gtk.label(
                "\(item.body) · \(StatusFacts.age(Date().timeIntervalSince(item.at))) ago",
                css: "row-detail", selectable: false))
        gtk_widget_set_hexpand(column, 1)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 4, bottom: 4, leading: 4, trailing: 4)
        gtk_box_append(ptr(row), glyph)
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)
        gtk_widget_set_hexpand(button, 1)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onOpen)
        return button
    }

    /// The heading over what was found, with the way back to the list. It names the query rather
    /// than saying "results", because the words that were searched for are the only thing that
    /// makes a result list readable a minute later.
    static func searchHeader(
        query: String, count: Int, running: Bool, onLeave: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let label = Gtk.label(
            running
                ? Localized.text("SEARCHING “%@”", query)
                : Localized.text("“%@” · %@", query, "\(count)"),
            css: "section-header", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), label)
        let leave = Gtk.button(Localized.text("back"), css: ["flat", "dim"], onClick: onLeave)
        gtk_widget_set_valign(leave, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(leave, Localized.text("Back to the chat list"))
        gtk_box_append(ptr(row), leave)
        return row
    }

    /// One conversation the words were found in: what it is, where it lives, and the places it
    /// said them — each quoted under the register it was in, so an answer, a thought and a shell
    /// command are told apart at a glance rather than read for.
    static func searchResult(
        _ result: TranscriptSearch.Row, onOpen: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(result.title, css: "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if result.isTitleOnly {
            gtk_box_append(ptr(titleRow), makePill(Localized.text("TITLE"), css: "pill-offline"))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), titleRow)
        gtk_box_append(
            ptr(column),
            Gtk.label(
                [result.project, result.profileName].compactMap { $0 }.joined(separator: " · "),
                css: "row-detail", selectable: false))
        for match in result.matches.prefix(3) {
            let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            let kind = Gtk.label(TranscriptSearch.label(for: match), css: "tool-name", selectable: false)
            gtk_label_set_ellipsize(op(kind), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_valign(kind, GTK_ALIGN_START)
            gtk_box_append(ptr(line), kind)
            let quote = Gtk.label(match.text, css: "row-detail", selectable: false)
            gtk_widget_set_hexpand(quote, 1)
            gtk_box_append(ptr(line), quote)
            gtk_box_append(ptr(column), line)
        }
        if result.total > result.matches.count {
            gtk_box_append(
                ptr(column),
                Gtk.label(
                    Localized.text("… %@ more in this chat", "\(result.total - result.matches.count)"),
                    css: "dim", selectable: false))
        }
        gtk_widget_set_hexpand(column, 1)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 6, bottom: 6, leading: 4, trailing: 4)
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)
        gtk_widget_set_hexpand(button, 1)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onOpen)
        return button
    }

    static func empty(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "dim", selectable: false)
        Gtk.margins(label, top: 20, bottom: 20, leading: 12, trailing: 12)
        return label
    }

    /// One conversation. Three registers on two lines — what it is, where it lives, and what it is
    /// doing — with the state carried by a pill rather than by a colour a reader has to decode.
    /// A right click hands back the row widget (as bits, for the sendable hop) and where inside it
    /// the click landed, so the caller can open a menu under the pointer. The row is also the
    /// handle a pointer picks the chat up by: it carries its own identity to whichever pane it is
    /// dragged onto.
    ///
    /// The mark lives in a button of its own beside the chat rather than inside it, because a
    /// press inside a `GtkButton` belongs to that button: a marker drawn into the row would open
    /// the conversation every time someone tried to select it.
    static func make(
        _ model: SessionRowModel, focused: Bool, marked: Bool = false,
        vocabulary: ChatListVocabulary = .full,
        onOpen: @escaping @Sendable () -> Void,
        onMark: @escaping @Sendable () -> Void = {},
        onMenu: @escaping @Sendable (UInt, Double, Double) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        if focused { Gtk.addClass(button, "row-focused") }
        if marked { Gtk.addClass(button, "row-marked") }

        let glyph = Gtk.label(model.state.glyph.text, css: model.state.glyph.css, selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        Gtk.margins(glyph, top: 3)
        ActivityPulse.apply(model.state.activity?.icon, to: glyph)
        if let spoken = model.state.activity?.spoken {
            gtk_widget_set_tooltip_text(glyph, spoken)
        }

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(
            model.title, css: model.unread ? "row-title-unread" : "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if let pill = model.state.pill {
            gtk_box_append(ptr(titleRow), makePill(pill.text, css: pill.css))
        }
        if model.pinned {
            gtk_box_append(ptr(titleRow), makePill(Localized.text("PINNED"), css: "pill-pinned"))
        }
        if model.saved {
            gtk_box_append(ptr(titleRow), makePill(Localized.text("SAVED"), css: "pill-saved"))
        }
        if model.unread, model.state.pill == nil {
            gtk_box_append(ptr(titleRow), Gtk.label("●", css: "unread-dot", selectable: false))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), titleRow)
        gtk_box_append(ptr(column), detailRow(model, vocabulary: vocabulary))
        gtk_widget_set_hexpand(column, 1)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 4, bottom: 4, leading: 4, trailing: 4)
        gtk_box_append(ptr(row), glyph)
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)

        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onOpen)
        let buttonBits = UInt(bitPattern: button)
        Gtk.onRightClick(button) { x, y in onMenu(buttonBits, x, y) }
        Gtk.makeChatDragSource(
            button,
            payload: PaneDragPayload(
                profileID: model.entry.profileID, sessionID: model.entry.session.id).encoded)
        gtk_widget_set_hexpand(button, 1)

        let holder = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(holder, "session-row-holder")
        gtk_box_append(ptr(holder), makeMark(marked: marked, onMark: onMark))
        gtk_box_append(ptr(holder), button)
        return holder
    }

    /// The second line, read as three things rather than one: what the conversation is in, where
    /// it lives, and how long ago it moved. The age is pinned to the trailing edge in monospace so
    /// it forms a straight column down the list — a staleness that has to be found at the end of a
    /// sentence of varying length is a fact nobody reads. A row that is working says what it is
    /// working on instead, and keeps the column.
    private static func detailRow(_ model: SessionRowModel, vocabulary: ChatListVocabulary)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let facets = model.facets(vocabulary)
        let chip = ModelBadge.chip(for: model.entry)
        if let chip {
            gtk_box_append(ptr(line), modelLabel(chip))
        }
        if let snippet = model.snippet {
            let text = chip == nil ? snippet : "· \(snippet)"
            let label = Gtk.label(text, css: "row-note", selectable: false)
            gtk_widget_set_hexpand(label, 1)
            gtk_box_append(ptr(line), label)
        } else {
            if let project = facets.project {
                let text = chip == nil ? project : "· \(project)"
                let label = Gtk.label(text, css: "row-project", selectable: false)
                gtk_box_append(ptr(line), label)
            }
            if let origin = facets.origin {
                let text = chip == nil && facets.project == nil ? origin : "· \(origin)"
                let label = Gtk.label(text, css: "row-detail", selectable: false)
                gtk_widget_set_hexpand(label, 1)
                gtk_box_append(ptr(line), label)
            }
        }
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(line), spacer)
        let age = Gtk.label(facets.age, css: "row-age", selectable: false)
        gtk_label_set_ellipsize(op(age), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_xalign(op(age), 1)
        gtk_widget_set_size_request(age, 30, -1)
        gtk_box_append(ptr(line), age)
        return line
    }

    /// The mark itself: quiet until the pointer is over the row or the chat is actually marked,
    /// so a list nobody is selecting in does not wear a column of empty boxes. It states which it
    /// is in its accessible name too — an opacity is not a label a screen reader can read.
    private static func makeMark(
        marked: Bool, onMark: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "row-mark")
        if marked { Gtk.addClass(button, "row-mark-on") }
        let glyph = Gtk.label(marked ? "☑" : "☐", css: "row-mark-glyph", selectable: false)
        gtk_label_set_ellipsize(op(glyph), PANGO_ELLIPSIZE_NONE)
        gtk_button_set_child(ptr(button), glyph)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        let label =
            marked ? Localized.text("Marked — click to unmark") : Localized.text("Mark this chat")
        gtk_widget_set_tooltip_text(button, label)
        tailscode_set_accessible_label(button, label)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onMark)
        return button
    }

    private static func makePill(_ text: String, css: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "pill", selectable: false)
        Gtk.addClass(label, css)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        return label
    }

    /// The model wearing its family's hue and the effort wearing its heat, as the coloured words
    /// the detail line opens with. Typography, not chrome: pills on this list mean *state*, and a
    /// bordered box repeated down every row shouts over the titles it sits under — the identity
    /// is two emphasised words whose colour is the fact. Ultracode is not a heat, so its word is
    /// set letter by letter from the shared rainbow — the same stops the aura runs — held to the
    /// canvas's own contrast floor.
    static func modelLabel(_ chip: ModelChip) -> UnsafeMutablePointer<GtkWidget> {
        let palette = MatrixTheme.palette
        let family = ModelTint.identityHex(family: chip.family, name: chip.name, in: palette)
        var markup =
            "<span foreground=\"\(family)\" weight=\"600\">\(PangoMarkdown.escape(chip.name))</span>"
        if let effort = chip.effort {
            markup += " "
            if chip.isUltracode {
                let colors = ModelTint.rainbow(letters: effort.count, onCanvas: palette.canvas)
                markup += zip(effort, colors)
                    .map { "<span foreground=\"\($1)\" weight=\"600\">\($0)</span>" }
                    .joined()
            } else {
                let heat = ModelTint.effortHex(effort, in: palette) ?? palette.textDim
                markup +=
                    "<span foreground=\"\(heat)\" weight=\"600\">\(PangoMarkdown.escape(effort))</span>"
            }
        }
        let label = Gtk.markupLabel(markup, css: "row-model", wrap: false)
        gtk_label_set_selectable(op(label), 0)
        return label
    }
}
