import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// How a long chat got here: every chapter its server keeps, one row each — number, title, what it
/// came to, the turns and times it spans, who named it when not the model — the current one lit,
/// and the strip that draws them to scale. A row (arrows, Return or a click) closes the panel and
/// takes the transcript to where that chapter began. Every word is ``ChapterReading``'s; the panel
/// reads again when the conversation's chapters change while it is open.
final class ChaptersPanel: @unchecked Sendable {
    private static let windowWidth: Int32 = 480
    private static let stripWidth = 420
    private static let stripGap = 3

    private nonisolated(unsafe) static var open: ChaptersPanel?

    private let read: () -> ChapterReading?
    private let goTo: @Sendable (String) -> Void
    private let windowBits: UInt
    private let columnBits: UInt
    private var focus: String?
    private var anchors: [String] = []
    private var closed = false

    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, focus: String?,
        goTo: @escaping @Sendable (String) -> Void, read: @escaping () -> ChapterReading?
    ) {
        if let open, !open.closed, let raw = UnsafeMutableRawPointer(bitPattern: open.windowBits) {
            open.focus = focus
            open.render()
            gtk_window_present(ptr(raw))
            open.focusRow()
            return
        }
        let panel = ChaptersPanel(parent: parent, focus: focus, goTo: goTo, read: read)
        open = panel
        panel.render()
        guard let raw = UnsafeMutableRawPointer(bitPattern: panel.windowBits) else { return }
        gtk_window_present(ptr(raw))
        panel.focusRow()
    }

    static var isOpen: Bool { open != nil }

    static func dismiss() {
        guard let open, let raw = UnsafeMutableRawPointer(bitPattern: open.windowBits) else { return }
        gtk_window_destroy(ptr(raw))
        open.release()
    }

    /// The conversation's chapters changed, or it gained a message, while the panel is open: it
    /// reads them again, keeping the row that had the keyboard and the place it was scrolled to.
    static func chaptersChanged() {
        guard let panel = open, !panel.closed else { return }
        let focused = panel.rowBits.firstIndex { bits in
            UnsafeMutableRawPointer(bitPattern: bits).map { gtk_widget_is_focus(ptr($0)) != 0 } ?? false
        }
        let scrolled = UnsafeMutableRawPointer(bitPattern: panel.scrollerBits).flatMap { raw in
            gtk_scrolled_window_get_vadjustment(op(raw)).map { gtk_adjustment_get_value($0) }
        }
        panel.render()
        if let scrolled, let raw = UnsafeMutableRawPointer(bitPattern: panel.scrollerBits),
            let adjustment = gtk_scrolled_window_get_vadjustment(op(raw))
        {
            let bits = UInt(bitPattern: adjustment)
            Gtk.after(0) {
                guard let held = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                gtk_adjustment_set_value(ptr(held), scrolled)
            }
        }
        if let focused, panel.rowBits.indices.contains(focused),
            let raw = UnsafeMutableRawPointer(bitPattern: panel.rowBits[focused])
        {
            gtk_widget_grab_focus(ptr(raw))
        }
    }

    private init(
        parent: UnsafeMutablePointer<GtkWidget>?, focus: String?,
        goTo: @escaping @Sendable (String) -> Void, read: @escaping () -> ChapterReading?
    ) {
        self.read = read
        self.goTo = goTo
        self.focus = focus
        let (window, content, actions) = Dialogs.windowWithActions(
            title: Localized.text("Chapters"), parent: parent, width: Self.windowWidth)
        windowBits = UInt(bitPattern: window)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        columnBits = UInt(bitPattern: column)
        gtk_box_append(ptr(content), column)
        let closing = windowBits
        let dismiss = Gtk.button(Localized.text("Close"), css: []) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: closing) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_box_append(ptr(actions), dismiss)
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            self?.release()
        }
    }

    private func release() {
        closed = true
        if ChaptersPanel.open === self { ChaptersPanel.open = nil }
    }

    private var column: UnsafeMutablePointer<GtkWidget>? {
        UnsafeMutableRawPointer(bitPattern: columnBits).map { ptr($0) }
    }

    private var listBits: UInt = 0
    private var scrollerBits: UInt = 0
    private var rowBits: [UInt] = []

    private func render() {
        guard let column, !closed else { return }
        Gtk.removeChildren(of: column)
        guard let reading = read(), reading.isShown else {
            gtk_box_append(
                ptr(column),
                Gtk.label(Localized.text("This chat is still in its first chapter."), css: "dim",
                    wrap: true, selectable: false))
            anchors = []
            return
        }
        let header = Gtk.label(reading.header, css: "chapters-header", wrap: true, selectable: false)
        gtk_widget_set_halign(header, GTK_ALIGN_START)
        gtk_box_append(ptr(column), header)
        if let strip = reading.strip { gtk_box_append(ptr(column), self.strip(strip)) }
        let list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(list, "chapters-list")
        anchors = reading.lines.map { $0.anchorID ?? "" }
        rowBits = reading.lines.map { line in
            let row = row(line)
            gtk_box_append(ptr(list), row)
            return UInt(bitPattern: row)
        }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_max_content_height(op(scroller), 460)
        gtk_scrolled_window_set_child(op(scroller), list)
        gtk_box_append(ptr(column), scroller)
        listBits = UInt(bitPattern: list)
        scrollerBits = UInt(bitPattern: scroller)
    }

    /// Puts the keyboard on the chapter the panel was opened for — the one a heading named, or the
    /// current one — and shows it.
    func focusRow() {
        let index = focus.flatMap { anchors.firstIndex(of: $0) } ?? max(0, anchors.count - 1)
        guard rowBits.indices.contains(index),
            let raw = UnsafeMutableRawPointer(bitPattern: rowBits[index])
        else { return }
        gtk_widget_grab_focus(ptr(raw))
    }

    private func strip(_ pieces: [ChapterStripPiece]) -> UnsafeMutablePointer<GtkWidget> {
        let strip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: Int32(Self.stripGap))
        let room = Self.stripWidth - Self.stripGap * (pieces.count - 1)
        for piece in pieces {
            let mark = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(mark, "chapter-strip-piece")
            if piece.isCurrent { Gtk.addClass(mark, "chapter-strip-now") }
            gtk_widget_set_size_request(mark, Int32(max(6, Double(room) * piece.share)), 8)
            gtk_box_append(ptr(strip), mark)
        }
        tailscode_set_accessible_hidden(strip, 1)
        return strip
    }

    private func row(_ line: ChapterLine) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let number = Gtk.label("\(line.number)", css: "chapter-num", selectable: false)
        gtk_label_set_xalign(op(number), 0.5)
        gtk_label_set_ellipsize(op(number), PANGO_ELLIPSIZE_NONE)
        if line.isCurrent { Gtk.addClass(number, "chapter-num-current") }
        gtk_widget_set_valign(number, GTK_ALIGN_START)
        gtk_box_append(ptr(row), number)
        let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        gtk_widget_set_hexpand(body, 1)
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(line.title, css: "chapter-row-title", wrap: true, selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(head), title)
        if line.isCurrent {
            let now = Gtk.label(Localized.text("Current"), css: "chapter-row-now", selectable: false)
            gtk_label_set_ellipsize(op(now), PANGO_ELLIPSIZE_NONE)
            gtk_widget_set_valign(now, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(head), now)
        }
        gtk_box_append(ptr(body), head)
        if let gist = line.gist {
            let label = Gtk.label(gist, css: "chapter-row-gist", wrap: true, selectable: false)
            gtk_label_set_xalign(op(label), 0)
            gtk_box_append(ptr(body), label)
        }
        let span = Gtk.label(line.span, css: "chapter-row-span", wrap: true, selectable: false)
        gtk_label_set_xalign(op(span), 0)
        gtk_box_append(ptr(body), span)
        if let note = line.note {
            let label = Gtk.label(note, css: "chapter-row-note", wrap: true, selectable: false)
            gtk_label_set_xalign(op(label), 0)
            gtk_box_append(ptr(body), label)
        }
        gtk_box_append(ptr(row), body)
        let holder = gtk_button_new()!
        Gtk.addClass(holder, "flat")
        Gtk.addClass(holder, "chapter-row")
        if line.isCurrent { Gtk.addClass(holder, "chapter-row-current") }
        gtk_button_set_child(ptr(holder), row)
        gtk_widget_set_cursor_from_name(holder, "pointer")
        tailscode_set_accessible_label(holder, line.spoken)
        if let anchor = line.anchorID {
            let windowHeld = windowBits
            let jump = goTo
            Gtk.connect(UnsafeMutableRawPointer(holder), "clicked") {
                if let raw = UnsafeMutableRawPointer(bitPattern: windowHeld) {
                    gtk_window_destroy(ptr(raw))
                }
                jump(anchor)
            }
        } else {
            gtk_widget_set_sensitive(holder, 0)
        }
        return holder
    }
}
