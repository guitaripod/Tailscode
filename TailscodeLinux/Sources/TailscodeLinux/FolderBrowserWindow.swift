import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// Walking another machine's folders, drawn.
///
/// The desktop's native folder chooser can only ever show this disk, so a chat meant for a server
/// across the tailnet had no way to be pointed at one of its folders except by typing the whole
/// path from memory. This reads the server's own listing instead and lays it out the way a file
/// manager does: a path of crumbs that each jump back, up and back and home, a filter that narrows
/// the folder in view as the letters arrive, the places already worked in as jumps beside it, and
/// one verb that starts the chat in the folder on screen. Nothing here decides anything — every
/// rule, key and word comes from the shared `FolderBrowser`.
///
/// The keyboard is claimed from the window in the capture phase, so the arrows and enter walk the
/// list while the filter keeps the letters.
final class FolderBrowserWindow: @unchecked Sendable {
    nonisolated(unsafe) private static var open: FolderBrowserWindow?

    private var browser: FolderBrowser
    private let entries: [SessionEntry]
    private let onChoose: @Sendable (String, String) -> Void
    private var fetching: Set<FolderRequest> = []

    private let window: UnsafeMutablePointer<GtkWidget>
    private let crumbBar: UnsafeMutablePointer<GtkWidget>
    private let crumbScroller: UnsafeMutablePointer<GtkWidget>
    private let navigation: UnsafeMutablePointer<GtkWidget>
    private let serverBar: UnsafeMutablePointer<GtkWidget>
    private let entry: UnsafeMutablePointer<GtkWidget>
    private let places: UnsafeMutablePointer<GtkWidget>
    private let list: UnsafeMutablePointer<GtkWidget>
    private let scroller: UnsafeMutablePointer<GtkWidget>
    private let summary: UnsafeMutablePointer<GtkWidget>
    private let hint: UnsafeMutablePointer<GtkWidget>
    private let choose: UnsafeMutablePointer<GtkWidget>
    private var rowWidgets: [UInt] = []

    /// - Parameters:
    ///   - servers: the machines that can list their folders; more than one puts a switcher in the
    ///     header and `⌃s` on the keyboard.
    ///   - start: the folder to open on the preferred server, or nil for its home.
    ///   - onChoose: the profile and folder the person picked. The window has already closed.
    static func present(
        servers: [NewChatServer], entries: [SessionEntry], preferredServer: String?,
        start: String?, parent: UnsafeMutablePointer<GtkWidget>?,
        onChoose: @escaping @Sendable (String, String) -> Void
    ) {
        guard !servers.isEmpty else { return }
        open?.close()
        open = FolderBrowserWindow(
            servers: servers, entries: entries, preferredServer: preferredServer, start: start,
            parent: parent, onChoose: onChoose)
    }

    private init(
        servers: [NewChatServer], entries: [SessionEntry], preferredServer: String?,
        start: String?, parent: UnsafeMutablePointer<GtkWidget>?,
        onChoose: @escaping @Sendable (String, String) -> Void
    ) {
        self.entries = entries
        self.onChoose = onChoose
        browser = FolderBrowser(
            servers: servers, directories: Self.gather(servers: servers, entries: entries),
            entries: entries, preferredServer: preferredServer, start: start)

        window = gtk_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Choose a folder"))
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 760, 560)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.margins(column, top: 14, bottom: 12, leading: 14, trailing: 14)
        gtk_window_set_child(ptr(window), column)

        serverBar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_append(ptr(column), serverBar)

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        navigation = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        gtk_box_append(ptr(header), navigation)
        crumbBar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        crumbScroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(crumbScroller), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER)
        gtk_widget_set_hexpand(crumbScroller, 1)
        gtk_scrolled_window_set_child(op(crumbScroller), crumbBar)
        gtk_box_append(ptr(header), crumbScroller)
        gtk_box_append(ptr(column), header)

        entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(
            ptr(entry), Localized.text("Filter this folder — or type a path and press enter"))
        Gtk.addClass(entry, "model-search")
        gtk_box_append(ptr(column), entry)

        let body = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_widget_set_vexpand(body, 1)
        places = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        let placesScroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(placesScroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_size_request(placesScroller, 190, -1)
        gtk_scrolled_window_set_child(op(placesScroller), places)
        gtk_box_append(ptr(body), placesScroller)

        scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_hexpand(scroller, 1)
        list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_widget_set_focusable(list, 1)
        gtk_scrolled_window_set_child(op(scroller), list)
        gtk_box_append(ptr(body), scroller)
        gtk_box_append(ptr(column), body)

        summary = Gtk.label("", css: "row-detail", selectable: false)
        gtk_box_append(ptr(column), summary)
        hint = Gtk.label(browser.hint, css: "chooser-hint", selectable: false)
        gtk_box_append(ptr(column), hint)

        choose = Gtk.button("", css: ["suggested-action"]) {}
        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        gtk_box_append(
            ptr(buttons),
            Gtk.button(Localized.text("Cancel")) { [weak self] in
                Gtk.onMain { [weak self] in self?.close() }
            })
        Gtk.connect(UnsafeMutableRawPointer(choose), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.run(.chooseHere) }
        }
        gtk_box_append(ptr(buttons), choose)
        gtk_box_append(ptr(column), buttons)

        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.filterChanged() }
        }
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self else { return false }
            return self.key(keyval: keyval, state: state)
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            Gtk.onMain { FolderBrowserWindow.open = nil }
        }

        render()
        service()
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(entry)
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

    /// The field's own edits, and only those: the window writes the filter itself on a tab or a
    /// descent, and that echo arrives later than any flag could guard, so the field is compared to
    /// what the model already holds.
    private func filterChanged() {
        guard let raw = gtk_editable_get_text(op(entry)) else { return }
        let typed = String(cString: raw)
        guard typed != browser.filter else { return }
        browser.type(typed)
        renderList()
    }

    private func key(keyval: UInt32, state: UInt32) -> Bool {
        guard let chord = KeyChord.canonical(keyval: keyval, state: state),
            let command = FolderBrowser.command(for: chord, filterIsEmpty: browser.filter.isEmpty)
        else { return false }
        run(command)
        return true
    }

    private func run(_ command: FolderCommand) {
        let before = browser.location
        let result = browser.handle(command)
        guard result.handled else { return }
        if let outcome = result.outcome {
            apply(outcome)
            return
        }
        writeFilter(browser.filter)
        render(places: before != browser.location || command == .nextServer
            || command == .previousServer)
        service()
    }

    private func apply(_ outcome: FolderOutcome) {
        switch outcome {
        case .dismiss:
            close()
        case .choose(let profileID, let path):
            FileBrowserRecents.record(path, for: profileID)
            SettingsFile.capture()
            let deliver = onChoose
            close()
            deliver(profileID, path)
        case .favorite(let profileID, let path):
            _ = FileBrowserFavorites.toggle(path, for: profileID)
            SettingsFile.capture()
            browser = browser.restated(
                directories: Self.gather(servers: browser.servers, entries: entries))
            render()
        }
    }

    private func writeFilter(_ text: String) {
        guard let raw = gtk_editable_get_text(op(entry)), String(cString: raw) != text else {
            return
        }
        gtk_editable_set_text(op(entry), text)
        gtk_editable_set_position(op(entry), -1)
    }

    /// Whatever folder the browser says it is waiting for, read off the server once. The answer
    /// comes back on the main context and is offered to the browser, which drops anything the
    /// person has already walked away from.
    private func service() {
        guard let request = browser.wanted, fetching.insert(request).inserted else { return }
        Task { [weak self] in
            let nodes = await Self.read(request)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.fetching.remove(request)
                self.browser.offer(request, nodes: nodes)
                self.render(places: true)
                self.service()
            }
        }
    }

    private static func read(_ request: FolderRequest) async -> [FileNode]? {
        let directory = ServerDirectory.shared
        guard
            let profile = await directory.profiles().first(where: { $0.id == request.profileID }),
            let backend = await directory.backend(for: profile) as? any FileBrowsingBackend
        else { return nil }
        return try? await backend.listFiles(path: request.path)
    }

    private func render(places redraw: Bool = true) {
        renderServers()
        renderNavigation()
        renderCrumbs()
        if redraw { renderPlaces() }
        renderList()
        gtk_button_set_label(
            ptr(choose), Localized.text("Start in %@", browser.choice.map(FolderBrowser.name(of:)) ?? browser.currentName))
        gtk_widget_set_sensitive(choose, browser.choice == nil ? 0 : 1)
    }

    /// Which machine is being read. A single server needs no switcher; several wear one pill each,
    /// the current one filled, so "which disk is this" is answered above the path rather than
    /// inferred from it.
    private func renderServers() {
        Gtk.removeChildren(of: serverBar)
        gtk_widget_set_visible(serverBar, browser.servers.count > 1 ? 1 : 0)
        guard browser.servers.count > 1 else { return }
        for server in browser.servers {
            let current = server.profileID == browser.server?.profileID
            let pill = Gtk.button(server.title, css: current ? ["suggested-action"] : ["flat"]) {}
            let profileID = server.profileID
            Gtk.connect(UnsafeMutableRawPointer(pill), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.browser.chooseServer(profileID)
                    self.writeFilter("")
                    self.render()
                    self.service()
                }
            }
            gtk_box_append(ptr(serverBar), pill)
        }
    }

    private func renderNavigation() {
        Gtk.removeChildren(of: navigation)
        let verbs: [(String, String, Bool, FolderCommand)] = [
            ("go-previous-symbolic", Localized.text("Back"), browser.canGoBack, .back),
            ("go-up-symbolic", Localized.text("Up"), browser.canGoUp, .ascend),
            ("user-home-symbolic", Localized.text("Home"), true, .home),
        ]
        for (icon, label, enabled, command) in verbs {
            let button = gtk_button_new_from_icon_name(icon)!
            Gtk.addClass(button, "flat")
            gtk_widget_set_sensitive(button, enabled ? 1 : 0)
            gtk_widget_set_tooltip_text(button, label)
            tailscode_set_accessible_label(button, label)
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in self?.run(command) }
            }
            gtk_box_append(ptr(navigation), button)
        }
        let star = gtk_button_new_from_icon_name(
            browser.isStarredHere ? "starred-symbolic" : "non-starred-symbolic")!
        Gtk.addClass(star, "flat")
        let starLabel =
            browser.isStarredHere ? Localized.text("Unstar this folder") : Localized.text("Star this folder")
        gtk_widget_set_tooltip_text(star, starLabel)
        tailscode_set_accessible_label(star, starLabel)
        gtk_widget_set_sensitive(star, browser.current == nil ? 0 : 1)
        Gtk.connect(UnsafeMutableRawPointer(star), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.run(.favoriteHere) }
        }
        gtk_box_append(ptr(navigation), star)
    }

    private func renderCrumbs() {
        Gtk.removeChildren(of: crumbBar)
        let crumbs = browser.crumbs
        if crumbs.isEmpty {
            gtk_box_append(
                ptr(crumbBar),
                Gtk.label(Localized.text("Reading…"), css: "row-detail", selectable: false))
            return
        }
        for (index, crumb) in crumbs.enumerated() {
            if index > 0 {
                gtk_box_append(
                    ptr(crumbBar), Gtk.label("›", css: "row-detail", selectable: false))
            }
            let button = gtk_button_new()!
            Gtk.addClass(button, "flat")
            let title = Gtk.label(
                crumb.title, css: crumb.isCurrent ? "row-title" : "row-detail", selectable: false)
            gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_NONE)
            gtk_button_set_child(ptr(button), title)
            let path = crumb.path
            Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.browser.open(path)
                    self.writeFilter("")
                    self.render(places: false)
                    self.service()
                }
            }
            gtk_box_append(ptr(crumbBar), button)
        }
        let scrollerBits = UInt(bitPattern: crumbScroller)
        Gtk.after(1) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: scrollerBits),
                let adjustment = gtk_scrolled_window_get_hadjustment(op(raw))
            else { return }
            gtk_adjustment_set_value(
                adjustment,
                gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        }
    }

    private func renderPlaces() {
        Gtk.removeChildren(of: places)
        var flat = 0
        for section in browser.placeSections {
            if let title = section.title {
                let header = Gtk.label(title.uppercased(), css: "section-header", selectable: false)
                Gtk.margins(header, top: 10, bottom: 2, leading: 6, trailing: 6)
                gtk_box_append(ptr(places), header)
            }
            for place in section.places {
                let index = flat
                flat += 1
                let button = gtk_button_new()!
                Gtk.addClass(button, "flat")
                Gtk.addClass(button, "session-row")
                let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
                gtk_box_append(
                    ptr(lines), Gtk.label(place.title, css: "row-title", selectable: false))
                if !place.detail.isEmpty {
                    let detail = Gtk.label(place.detail, css: "row-detail", selectable: false)
                    gtk_label_set_ellipsize(op(detail), PANGO_ELLIPSIZE_START)
                    gtk_box_append(ptr(lines), detail)
                }
                Gtk.margins(lines, top: 3, bottom: 3, leading: 4, trailing: 4)
                gtk_button_set_child(ptr(button), lines)
                Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.browser.openPlace(index)
                        self.writeFilter("")
                        self.render(places: false)
                        self.service()
                    }
                }
                gtk_box_append(ptr(places), button)
            }
        }
    }

    private func renderList() {
        Gtk.removeChildren(of: list)
        rowWidgets = []
        gtk_label_set_text(op(summary), browser.summary)
        gtk_label_set_text(op(hint), browser.hint)
        switch browser.phase {
        case .loading:
            gtk_box_append(ptr(list), Self.waitingCard())
            return
        case .failed(let failure):
            gtk_box_append(ptr(list), Self.failureCard(failure))
            return
        case .ready:
            break
        }
        for (index, row) in browser.rows.enumerated() {
            let widget = make(row, index: index)
            rowWidgets.append(UInt(bitPattern: widget))
            gtk_box_append(ptr(list), widget)
        }
        revealCursor()
    }

    private func make(_ row: FolderRow, index: Int) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        if index == browser.cursor { Gtk.addClass(button, "row-focused") }

        let glyph = gtk_image_new_from_icon_name("folder-symbolic")!
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)

        let name = Gtk.markupLabel(Self.markup(row), css: "row-title")
        gtk_label_set_wrap(op(name), 0)
        gtk_label_set_selectable(op(name), 0)
        gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(name, 1)

        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(content, top: 4, bottom: 4, leading: 6, trailing: 6)
        gtk_box_append(ptr(content), glyph)
        gtk_box_append(ptr(content), name)
        if row.starred {
            let star = Gtk.label("★", css: "row-note", selectable: false)
            gtk_widget_set_valign(star, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(content), star)
        }
        if let note = Self.note(row) {
            let tally = Gtk.label(note, css: "row-note", selectable: false)
            gtk_widget_set_valign(tally, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(content), tally)
        }
        gtk_button_set_child(ptr(button), content)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.browser.focus(index)
                self.run(.descend)
            }
        }
        return button
    }

    private static func note(_ row: FolderRow) -> String? {
        if row.chats > 0 { return Localized.text("%@ chats", "\(row.chats)") }
        if row.chatsBelow > 0 { return Localized.text("%@ inside", "\(row.chatsBelow)") }
        return nil
    }

    private static func markup(_ row: FolderRow) -> String {
        guard !row.highlight.isEmpty else { return PangoMarkdown.escape(row.name) }
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
        for (index, character) in Array(row.name).enumerated() {
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

    private static func waitingCard() -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(card, top: 28, bottom: 28, leading: 12, trailing: 12)
        gtk_widget_set_halign(card, GTK_ALIGN_CENTER)
        let glyph = Gtk.label(
            ActivityKind.working.icon.glyph, css: ActivityKind.working.icon.glyphCSS,
            selectable: false)
        ActivityPulse.apply(ActivityKind.working.icon, to: glyph)
        gtk_box_append(ptr(card), glyph)
        gtk_box_append(
            ptr(card),
            Gtk.label(Localized.text("Reading…"), css: "row-detail", selectable: false))
        return card
    }

    /// What went wrong in the place it happened: never a raw error, and always a way on — the
    /// crumbs and the up button stay live above it, so a refused folder strands nobody.
    private static func failureCard(_ failure: FolderPhase.Failure) -> UnsafeMutablePointer<GtkWidget>
    {
        let title: String
        let detail: String
        switch failure {
        case .cannotList:
            title = Localized.text("This server would not list its folders")
            detail = Localized.text(
                "It may be offline, asking for a password, or too old to show its disk. Typing a path in the new-chat field still works.")
        case .missing(let path):
            title = Localized.text("The server could not open that folder")
            detail = Localized.text(
                "%@ is not a folder it can read. Go up, or pick another place.", path)
        }
        let card = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(card, top: 18, bottom: 18, leading: 10, trailing: 10)
        let glyph = Gtk.label("✖", css: "glyph-error", selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        gtk_box_append(ptr(card), glyph)
        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        let heading = Gtk.label(title, css: "row-title", wrap: true, selectable: false)
        gtk_label_set_xalign(op(heading), 0)
        gtk_box_append(ptr(lines), heading)
        let body = Gtk.label(detail, css: "row-detail", wrap: true, selectable: true)
        gtk_label_set_xalign(op(body), 0)
        gtk_box_append(ptr(lines), body)
        gtk_widget_set_hexpand(lines, 1)
        gtk_box_append(ptr(card), lines)
        return card
    }

    private func revealCursor() {
        guard browser.cursor < rowWidgets.count else { return }
        let rowBits = rowWidgets[browser.cursor]
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
}
