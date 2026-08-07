import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The New Conversation modal, drawn.
///
/// A new chat is two questions — which machine, which folder — and the old form asked them as a
/// text field with six unranked buttons under it. This asks them as one ranked list: the folders
/// this device already knows for the chosen server, each saying where it came from and how many
/// chats already work there, with the typed path always offered as a row of its own. Nothing here
/// decides anything — the ranking, the cursor, the two modes and every key come from the shared
/// `NewChatChooser`, so what the phone shows and what this shows are one list rendered twice.
///
/// The keyboard is claimed from the window in the capture phase, before the entry sees it, and
/// focus is moved into and out of the entry to follow `chooser.mode`: the field must own the
/// letters while a path is being typed, and must never own them once the letters are verbs.
final class NewChatWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var open: NewChatWindow?

    private var chooser: NewChatChooser
    private let entries: [SessionEntry]
    private let onStart: @Sendable (String, String?) -> Void
    private let onBrowse: @Sendable (String, String, @escaping @Sendable (String) -> Void) -> Void

    private let window: UnsafeMutablePointer<GtkWidget>
    private let entry: UnsafeMutablePointer<GtkWidget>
    private let heading: UnsafeMutablePointer<GtkWidget>
    private let hint: UnsafeMutablePointer<GtkWidget>
    private let list: UnsafeMutablePointer<GtkWidget>
    private let scroller: UnsafeMutablePointer<GtkWidget>
    private var rowWidgets: [UInt] = []

    /// - Parameter onBrowse: how this client opens a folder picker, given the server's profile id,
    ///   what has been typed so far — the picker opens where the field points when that is a real
    ///   folder — and what to do with the path. Only a local server ever asks; a remote one has no
    ///   browse row, because a native picker would offer this disk's folders on its behalf.
    static func present(
        servers: [NewChatServer], entries: [SessionEntry], preferredServer: String?,
        parent: UnsafeMutablePointer<GtkWidget>?,
        onBrowse: @escaping @Sendable (String, String, @escaping @Sendable (String) -> Void) ->
            Void,
        onStart: @escaping @Sendable (String, String?) -> Void
    ) {
        guard !servers.isEmpty else { return }
        open?.close()
        open = NewChatWindow(
            servers: servers, entries: entries, preferredServer: preferredServer, parent: parent,
            onBrowse: onBrowse, onStart: onStart)
    }

    private init(
        servers: [NewChatServer], entries: [SessionEntry], preferredServer: String?,
        parent: UnsafeMutablePointer<GtkWidget>?,
        onBrowse: @escaping @Sendable (String, String, @escaping @Sendable (String) -> Void) ->
            Void,
        onStart: @escaping @Sendable (String, String?) -> Void
    ) {
        self.entries = entries
        self.onStart = onStart
        self.onBrowse = onBrowse
        chooser = NewChatChooser(
            servers: servers,
            directories: Self.gather(servers: servers, entries: entries),
            entries: entries, preferredServer: preferredServer)

        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("New conversation"))
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 560, 540)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(column, top: 14, bottom: 12, leading: 14, trailing: 14)
        gtk_window_set_child(ptr(window), column)

        heading = Gtk.label(chooser.heading, css: "section-header", selectable: false)
        gtk_box_append(ptr(column), heading)

        entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(
            ptr(entry), Localized.text("Where the agent works, e.g. ~/Dev/thing"))
        Gtk.addClass(entry, "model-search")
        gtk_box_append(ptr(column), entry)

        scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(scroller, 1)
        list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_focusable(list, 1)
        gtk_scrolled_window_set_child(op(scroller), list)
        gtk_box_append(ptr(column), scroller)

        hint = Gtk.label(chooser.hint, css: "chooser-hint", selectable: false)
        gtk_box_append(ptr(column), hint)
        gtk_box_append(ptr(column), makeButtons())

        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.queryChanged() }
        }
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self else { return false }
            return self.key(keyval: keyval, state: state)
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            Gtk.onMain { NewChatWindow.open = nil }
        }

        render()
        gtk_window_present(ptr(window))
        applyMode()
    }

    /// A hand still gets both verbs. Enter and escape are the fast way through this window, but a
    /// query that matches nothing has no row left to click, and a folder typed out in full must
    /// still be startable without learning which key does it.
    private func makeButtons() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(row, GTK_ALIGN_END)
        gtk_box_append(
            ptr(row),
            Gtk.button(Localized.text("Cancel")) { [weak self] in
                Gtk.onMain { [weak self] in self?.close() }
            })
        gtk_box_append(
            ptr(row),
            Gtk.button(Localized.text("Start"), css: ["suggested-action"]) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, let outcome = self.chooser.activate() else { return }
                    self.apply(outcome)
                }
            })
        return row
    }

    private static func gather(servers: [NewChatServer], entries: [SessionEntry])
        -> [String: NewChatDirectories]
    {
        var gathered: [String: NewChatDirectories] = [:]
        for server in servers {
            gathered[server.profileID] = NewChatDirectories.gather(
                profileID: server.profileID, entries: entries)
        }
        return gathered
    }

    private func close() {
        Self.open = nil
        gtk_window_destroy(ptr(window))
    }

    /// The field's own edits, and only those. GTK's `changed` also fires for the writes this
    /// window makes itself — a tab completion, `x`, a folder back from the picker — and those
    /// arrive one idle hop later than any flag could guard, so what the field says is compared
    /// against what the model already holds instead: an echo of the model is not a query.
    private func queryChanged() {
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        let typed = String(cString: raw)
        guard typed != chooser.query else { return }
        chooser.type(typed)
        render()
    }

    /// Puts the model's own text into the field, caret at the end, so the next letter continues
    /// the path rather than landing in the middle of it.
    private func writeQuery(_ text: String) {
        guard let raw = gtk_editable_get_text(op(entry)), String(cString: raw) != text else {
            return
        }
        gtk_editable_set_text(op(entry), text)
        gtk_editable_set_position(op(entry), -1)
    }

    /// The field owns the letters in `.typing` and owns nothing in `.normal`. Focus is what makes
    /// that true rather than a flag the entry could disagree with: a caret still blinking in a
    /// field whose letters are verbs is a modal nobody can read.
    private func applyMode() {
        switch chooser.mode {
        case .typing: gtk_widget_grab_focus(entry)
        case .normal: gtk_widget_grab_focus(list)
        }
    }

    private func key(keyval: UInt32, state: UInt32) -> Bool {
        guard let chord = KeyChord.canonical(keyval: keyval, state: state),
            let command = NewChatChooser.command(for: chord, mode: chooser.mode)
        else { return false }
        let before = chooser.mode
        let result = chooser.handle(command)
        guard result.handled else { return false }
        if let outcome = result.outcome {
            apply(outcome)
            return true
        }
        writeQuery(chooser.query)
        render()
        if chooser.mode != before { applyMode() }
        return true
    }

    private func apply(_ outcome: NewChatOutcome) {
        switch outcome {
        case .dismiss:
            close()
        case .start(let profileID, let directory):
            start(profileID: profileID, directory: directory)
        case .browse(let profileID):
            browse(profileID: profileID)
        case .favorite(let profileID, let path):
            _ = FileBrowserFavorites.toggle(path, for: profileID)
            SettingsFile.capture()
            restate()
        }
    }

    /// A folder that was worked in is a folder worth offering next time, so starting there records
    /// it before the window goes — the modal must never hand back a directory it then forgets.
    private func start(profileID: String, directory: String?) {
        if let directory, !directory.isEmpty {
            FileBrowserRecents.record(directory, for: profileID)
            SettingsFile.capture()
        }
        let handler = onStart
        close()
        handler(profileID, directory?.isEmpty == false ? directory : nil)
    }

    private func browse(profileID: String) {
        onBrowse(profileID, chooser.query) { [weak self] picked in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.chooser.type(picked)
                self.writeQuery(picked)
                self.render()
                self.applyMode()
            }
        }
    }

    /// A star just set or cleared: the same question, re-gathered, with the person's place carried
    /// across so the row they were on does not move out from under them.
    private func restate() {
        chooser = chooser.restated(
            directories: Self.gather(servers: chooser.servers, entries: entries), entries: entries)
        render()
    }

    private func render() {
        gtk_label_set_text(op(heading), chooser.heading)
        gtk_label_set_text(op(hint), chooser.hint)
        Gtk.removeChildren(of: list)
        rowWidgets = []
        guard !chooser.rows.isEmpty else {
            let notice = Gtk.label(
                chooser.query.isEmpty
                    ? Localized.text(
                        "No folder to offer for this server yet — type where the agent should work")
                    : Localized.text(
                        "Nothing here matches “%@” — enter starts there anyway", chooser.query),
                css: "row-detail", wrap: true, selectable: false)
            Gtk.margins(notice, top: 24, bottom: 24, leading: 6, trailing: 6)
            gtk_box_append(ptr(list), notice)
            return
        }
        for (index, row) in chooser.rows.enumerated() {
            let widget = make(row, index: index)
            rowWidgets.append(UInt(bitPattern: widget))
            gtk_box_append(ptr(list), widget)
        }
        revealCursor()
    }

    private func make(_ row: NewChatRow, index: Int) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        if index == chooser.cursor { Gtk.addClass(button, "row-focused") }

        let number = Gtk.label(
            index < 9 ? "\(index + 1)" : " ", css: "row-detail", selectable: false)
        gtk_label_set_ellipsize(op(number), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_size_request(number, 16, -1)
        gtk_widget_set_valign(number, GTK_ALIGN_START)
        Gtk.margins(number, top: 3)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(row.title, css: "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if let label = row.origin.label {
            let badge = Gtk.label(label.uppercased(), css: "pill", selectable: false)
            Gtk.addClass(badge, row.origin == .favorite ? "pill-saved" : "pill-offline")
            gtk_widget_set_valign(badge, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(titleRow), badge)
        }
        if row.chats > 0 {
            let tally = Gtk.label(
                Localized.text("%@ chats", "\(row.chats)"), css: "row-note", selectable: false)
            gtk_widget_set_valign(tally, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(titleRow), tally)
        }

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(lines), titleRow)
        let detail = Gtk.markupLabel(Self.markup(row), css: "row-detail")
        gtk_label_set_wrap(op(detail), 0)
        gtk_label_set_selectable(op(detail), 0)
        gtk_label_set_ellipsize(op(detail), PANGO_ELLIPSIZE_START)
        gtk_box_append(ptr(lines), detail)
        gtk_widget_set_hexpand(lines, 1)

        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(content, top: 4, bottom: 4, leading: 4, trailing: 4)
        gtk_box_append(ptr(content), number)
        gtk_box_append(ptr(content), lines)
        gtk_button_set_child(ptr(button), content)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.activate(index) }
        }
        return button
    }

    private func activate(_ index: Int) {
        chooser.focus(index)
        guard let outcome = chooser.activate() else { return }
        apply(outcome)
    }

    /// The row under the cursor is brought into view without taking focus off the field — a modal
    /// you type a path into cannot hand the caret to the list every time the cursor moves.
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

    /// The whole path, with the letters the query landed on weighted inside it rather than beside
    /// it — a row that says why it is in the list is a row whose ranking can be trusted. A row
    /// with nothing to browse to (the server's own listing) has no path and shows its address.
    private static func markup(_ row: NewChatRow) -> String {
        guard row.origin != .browse else { return PangoMarkdown.escape(row.detail) }
        guard !row.highlight.isEmpty else { return PangoMarkdown.escape(row.path) }
        let accent = MatrixTheme.palette.accent
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
        for (index, character) in Array(row.path).enumerated() {
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
}
