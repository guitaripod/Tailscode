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
    private let onStart:
        @Sendable (String, String?, @escaping @Sendable (NewChatFailure?) -> Void) -> Void
    private let onFix:
        @Sendable (NewChatFailure.Fix, @escaping @Sendable (NewChatFailure?) -> Void) -> Void
    private let onBrowse: @Sendable (String, String, @escaping @Sendable (String) -> Void) -> Void
    /// What the window is doing. The modal outlives Start now: a chat is minted on another
    /// machine, and a window that vanishes the instant a request goes out cannot tell the person
    /// whether it worked.
    private var phase: NewChatPhase = .asking
    /// What to run again when the failure card's fix has been applied — the same folder on the
    /// same server, so a corrected port lands the person in the chat they asked for.
    private var lastAttempt: (profileID: String, directory: String?)?

    /// Folders already read off a server's disk, kept for the window's life so walking back up a
    /// path never asks the machine twice, and a folder it refused is refused from memory.
    private var listings: [NewChatListingRequest: NewChatListing] = [:]
    private var fetching: Set<NewChatListingRequest> = []

    private let window: UnsafeMutablePointer<GtkWidget>
    private let entry: UnsafeMutablePointer<GtkWidget>
    private let heading: UnsafeMutablePointer<GtkWidget>
    private var defaultsRow: UnsafeMutablePointer<GtkWidget>!
    private let hint: UnsafeMutablePointer<GtkWidget>
    private let list: UnsafeMutablePointer<GtkWidget>
    private let scroller: UnsafeMutablePointer<GtkWidget>
    private var buttons: UnsafeMutablePointer<GtkWidget>!
    private var rowWidgets: [UInt] = []

    /// - Parameter onBrowse: how this client opens a folder picker, given the server's profile id,
    ///   what has been typed so far — the picker opens where the field points when that is a real
    ///   folder — and what to do with the path. Only a local server ever asks; a remote one has no
    ///   browse row, because a native picker would offer this disk's folders on its behalf.
    /// - Parameters:
    ///   - onStart: mints the chat and answers with nothing when it worked, or with the reason it
    ///     did not. The window stays up until that answer arrives.
    ///   - onFix: applies a failure's own remedy — repointing a server at the port its agent is
    ///     actually on, or opening its settings — and answers the same way, so a fixed server
    ///     goes straight back into the chat that was being started.
    static func present(
        servers: [NewChatServer], entries: [SessionEntry], preferredServer: String?,
        parent: UnsafeMutablePointer<GtkWidget>?,
        onBrowse: @escaping @Sendable (String, String, @escaping @Sendable (String) -> Void) ->
            Void,
        onFix: @escaping @Sendable (
            NewChatFailure.Fix, @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void = { _, done in done(nil) },
        onStart: @escaping @Sendable (
            String, String?, @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void
    ) {
        guard !servers.isEmpty else { return }
        open?.close()
        open = NewChatWindow(
            servers: servers, entries: entries, preferredServer: preferredServer, parent: parent,
            onBrowse: onBrowse, onFix: onFix, onStart: onStart)
    }

    private init(
        servers: [NewChatServer], entries: [SessionEntry], preferredServer: String?,
        parent: UnsafeMutablePointer<GtkWidget>?,
        onBrowse: @escaping @Sendable (String, String, @escaping @Sendable (String) -> Void) ->
            Void,
        onFix: @escaping @Sendable (
            NewChatFailure.Fix, @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void,
        onStart: @escaping @Sendable (
            String, String?, @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void
    ) {
        self.entries = entries
        self.onStart = onStart
        self.onFix = onFix
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

        defaultsRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_halign(defaultsRow, GTK_ALIGN_START)
        Gtk.margins(defaultsRow, leading: 8)
        gtk_box_append(ptr(column), defaultsRow)

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
        buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        gtk_box_append(ptr(column), buttons)
        renderButtons()

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
    /// The buttons say what the window is doing: two while the question is open, none but a way
    /// out while a machine is being waited on, and the failure's own remedy once there is one.
    private func renderButtons() {
        Gtk.removeChildren(of: buttons)
        switch phase {
        case .asking:
            gtk_box_append(
                ptr(buttons),
                Gtk.button(Localized.text("Cancel")) { [weak self] in
                    Gtk.onMain { [weak self] in self?.close() }
                })
            gtk_box_append(
                ptr(buttons),
                Gtk.button(Localized.text("Start"), css: ["suggested-action"]) { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self, let outcome = self.chooser.activate() else { return }
                        self.apply(outcome)
                    }
                })
        case .starting:
            gtk_box_append(
                ptr(buttons),
                Gtk.button(Localized.text("Cancel")) { [weak self] in
                    Gtk.onMain { [weak self] in self?.close() }
                })
        case .failed(let failure):
            gtk_box_append(
                ptr(buttons),
                Gtk.button(Localized.text("Back")) { [weak self] in
                    Gtk.onMain { [weak self] in self?.returnToAsking() }
                })
            guard let title = failure.actionTitle else { return }
            gtk_box_append(
                ptr(buttons),
                Gtk.button(title, css: ["suggested-action"]) { [weak self] in
                    Gtk.onMain { [weak self] in self?.applyFix(failure.fix) }
                })
        }
    }

    /// Start, and stay: the window holds the question until the other machine has answered, so a
    /// chat that cannot be created says why in the place it was asked for rather than nowhere.
    private func beginStart(profileID: String, directory: String?) {
        lastAttempt = (profileID, directory)
        let name = chooser.servers.first { $0.profileID == profileID }?.name ?? profileID
        phase = .starting(server: name)
        render()
        onStart(profileID, directory) { [weak self] failure in
            Gtk.onMain { [weak self] in self?.finish(failure) }
        }
    }

    /// The remedy is applied here and the chat is tried again on the spot: a person who pressed
    /// "Use :4098" asked for the conversation, not for a corrected settings screen.
    private func applyFix(_ fix: NewChatFailure.Fix) {
        switch fix {
        case .none:
            close()
        case .retry:
            guard let attempt = lastAttempt else { return returnToAsking() }
            beginStart(profileID: attempt.profileID, directory: attempt.directory)
        case .editServer:
            onFix(fix) { _ in }
            close()
        case .repoint:
            phase = .starting(server: chooser.server?.name ?? "")
            render()
            onFix(fix) { [weak self] failure in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    if let failure {
                        self.finish(failure)
                        return
                    }
                    guard let attempt = self.lastAttempt else { return self.returnToAsking() }
                    self.beginStart(profileID: attempt.profileID, directory: attempt.directory)
                }
            }
        }
    }

    private func finish(_ failure: NewChatFailure?) {
        guard let failure else {
            close()
            return
        }
        phase = .failed(failure)
        render()
    }

    private func returnToAsking() {
        phase = .asking
        render()
        applyMode()
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
        serviceListing()
        render()
    }

    /// The shell half: whatever folder the chooser says it wants, answered from this window's own
    /// memory when it can be, and read off the server once when it cannot. The answer lands on the
    /// main context and is offered back to the chooser, which drops anything the person has
    /// already typed past.
    private func serviceListing() {
        guard let request = chooser.wantedListing else { return }
        if let cached = listings[request] {
            chooser.offer(cached)
            return
        }
        guard fetching.insert(request).inserted else { return }
        Task { [weak self] in
            let folders = await Self.readFolders(request)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.fetching.remove(request)
                let listing = NewChatListing(
                    profileID: request.profileID, parent: request.parent,
                    folders: folders ?? [], failed: folders == nil)
                self.listings[request] = listing
                self.chooser.offer(listing)
                self.serviceListing()
                self.render()
            }
        }
    }

    private static func readFolders(_ request: NewChatListingRequest) async -> [String]? {
        let directory = ServerDirectory.shared
        guard
            let profile = await directory.profiles().first(where: { $0.id == request.profileID }),
            let backend = await directory.backend(for: profile) as? any FileBrowsingBackend,
            let nodes = try? await backend.listFiles(path: request.parent)
        else { return nil }
        return nodes.filter(\.isDirectory).map(\.name)
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

    /// While a machine is being waited on, or a failure is on screen, the chooser's grammar is
    /// not the window's grammar: enter takes the fix, escape steps back one state rather than
    /// closing something that has an unread answer in it.
    private func key(keyval: UInt32, state: UInt32) -> Bool {
        switch phase {
        case .asking:
            break
        case .starting:
            guard keyval == Keymap.escape else { return true }
            close()
            return true
        case .failed(let failure):
            if keyval == Keymap.escape {
                returnToAsking()
                return true
            }
            if keyval == Keymap.enter || keyval == Keymap.keypadEnter {
                applyFix(failure.actionTitle == nil ? .none : failure.fix)
            }
            return true
        }
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
        serviceListing()
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
        beginStart(profileID: profileID, directory: directory?.isEmpty == false ? directory : nil)
    }

    private func browse(profileID: String) {
        onBrowse(profileID, chooser.query) { [weak self] picked in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.chooser.type(picked)
                self.serviceListing()
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
        renderButtons()
        switch phase {
        case .starting(let server):
            gtk_label_set_text(op(heading), Localized.text("Starting on %@…", server))
            gtk_label_set_text(op(hint), Localized.text("esc closes this — the chat still lands in the list"))
            gtk_widget_set_visible(defaultsRow, 0)
            gtk_widget_set_sensitive(entry, 0)
            Gtk.removeChildren(of: list)
            rowWidgets = []
            gtk_box_append(ptr(list), Self.waitingCard())
            return
        case .failed(let failure):
            gtk_label_set_text(op(heading), Localized.text("Could not start the chat"))
            gtk_label_set_text(
                op(hint),
                failure.actionTitle.map { Localized.text("enter %@ · esc goes back", $0) }
                    ?? Localized.text("esc goes back"))
            gtk_widget_set_visible(defaultsRow, 0)
            gtk_widget_set_sensitive(entry, 0)
            Gtk.removeChildren(of: list)
            rowWidgets = []
            gtk_box_append(ptr(list), Self.failureCard(failure))
            return
        case .asking:
            gtk_widget_set_sensitive(entry, 1)
        }
        gtk_label_set_text(op(heading), chooser.heading)
        renderDefaults()
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

    /// Waiting is a state with a face here too: the same swell every busy badge in the app
    /// breathes on, so a modal that is working looks like work rather than like a frozen window.
    private static func waitingCard() -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(card, top: 28, bottom: 28, leading: 12, trailing: 12)
        gtk_widget_set_halign(card, GTK_ALIGN_CENTER)
        let glyph = Gtk.label(ActivityKind.working.icon.glyph, css: ActivityKind.working.icon.glyphCSS, selectable: false)
        ActivityPulse.apply(ActivityKind.working.icon, to: glyph)
        gtk_box_append(ptr(card), glyph)
        gtk_box_append(
            ptr(card),
            Gtk.label(
                Localized.text("Asking the server for a conversation"), css: "row-detail",
                selectable: false))
        return card
    }

    /// The whole failure in the window that caused it: what happened, why, and the one button
    /// that fixes it. Never a raw error string, and never somewhere else on screen.
    private static func failureCard(_ failure: NewChatFailure) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(card, top: 18, bottom: 18, leading: 10, trailing: 10)
        let glyph = Gtk.label(failure.glyph, css: "glyph-error", selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        gtk_box_append(ptr(card), glyph)

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        let title = Gtk.label(failure.title, css: "row-title", wrap: true, selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(lines), title)
        let detail = Gtk.label(failure.detail, css: "row-detail", wrap: true, selectable: true)
        gtk_label_set_xalign(op(detail), 0)
        gtk_box_append(ptr(lines), detail)
        gtk_widget_set_hexpand(lines, 1)
        gtk_box_append(ptr(card), lines)
        return card
    }

    private func activate(_ index: Int) {
        chooser.focus(index)
        guard let outcome = chooser.activate() else { return }
        apply(outcome)
    }

    /// What the chat will start with, worn under the server's name: the model as the same chip the
    /// chat list wears, or the sentence that says the server decides. Re-read on every render so
    /// switching servers re-labels the chat before it exists.
    private func renderDefaults() {
        Gtk.removeChildren(of: defaultsRow)
        guard let defaults = chooser.defaults else {
            gtk_widget_set_visible(defaultsRow, 0)
            return
        }
        let line = Gtk.label(defaults.line, css: "row-detail", selectable: false)
        gtk_box_append(ptr(defaultsRow), line)
        if let chip = defaults.chip {
            gtk_box_append(ptr(defaultsRow), SidebarRow.modelLabel(chip))
        }
        tailscode_set_accessible_label(defaultsRow, defaults.sentence)
        gtk_widget_set_visible(defaultsRow, 1)
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
