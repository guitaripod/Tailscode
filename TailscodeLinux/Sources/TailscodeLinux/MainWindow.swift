import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The window: a sidebar of every session on every server, and the conversation next to it.
///
/// State lives here on the GLib main context; everything that talks to a server happens in a
/// detached `Task` and comes back through ``Gtk/onMain(_:)``. There is no `@MainActor` anywhere in
/// this app — `g_application_run` never drains libdispatch's main queue, so awaiting into a
/// main-actor type from a signal handler would suspend forever with no crash and no log line.
final class MainWindow: @unchecked Sendable {
    private var window: UnsafeMutablePointer<GtkWidget>?
    private let sidebarList = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    private let transcriptBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
    private let statusLabel = Gtk.label("", css: "status-line")
    private let entryView = gtk_text_view_new()!
    private let sendButton = gtk_button_new_with_label("Send")!
    private var transcriptScroller: UnsafeMutablePointer<GtkWidget>?

    private var entries: [SessionEntry] = []
    private var selectedID: String?
    private var conversation: AgentConversation?
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    func present(in app: UnsafeMutablePointer<AdwApplication>) {
        Gtk.installStyle()

        let window = adw_application_window_new(ptr(app))!
        gtk_window_set_title(ptr(window), "Tailscode")
        gtk_window_set_default_size(ptr(window), 1180, 760)
        self.window = window

        let split = adw_navigation_split_view_new()!
        adw_navigation_split_view_set_sidebar(
            op(split), makeSidebarPage())
        adw_navigation_split_view_set_content(
            op(split), makeContentPage())
        adw_navigation_split_view_set_min_sidebar_width(op(split), 240)
        adw_navigation_split_view_set_max_sidebar_width(op(split), 380)

        adw_application_window_set_content(ptr(window), split)
        gtk_window_present(ptr(window))

        startRefreshing()
    }

    private func makeSidebarPage() -> UnsafeMutablePointer<AdwNavigationPage> {
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(
            op(header), Gtk.label("Tailscode", css: "sidebar-title", selectable: false))
        adw_toolbar_view_add_top_bar(op(toolbar), header)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(
            op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        Gtk.margins(sidebarList, 6)
        gtk_scrolled_window_set_child(op(scroller), sidebarList)
        gtk_widget_set_vexpand(scroller, 1)
        adw_toolbar_view_set_content(op(toolbar), scroller)

        return adw_navigation_page_new(toolbar, "Servers")!
    }

    private func makeContentPage() -> UnsafeMutablePointer<AdwNavigationPage> {
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(op(toolbar), adw_header_bar_new()!)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(
            op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        Gtk.addClass(transcriptBox, "transcript")
        Gtk.margins(transcriptBox, top: 16, bottom: 16, leading: 24, trailing: 24)
        gtk_scrolled_window_set_child(op(scroller), transcriptBox)
        gtk_widget_set_vexpand(scroller, 1)
        transcriptScroller = scroller
        gtk_box_append(ptr(column), scroller)

        Gtk.margins(statusLabel, leading: 24, trailing: 24)
        gtk_box_append(ptr(column), statusLabel)

        gtk_box_append(ptr(column), makeComposer())
        adw_toolbar_view_set_content(op(toolbar), column)

        return adw_navigation_page_new(toolbar, "Conversation")!
    }

    private func makeComposer() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 8, bottom: 12, leading: 16, trailing: 16)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(
            op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_size_request(scroller, -1, 64)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_text_view_set_wrap_mode(ptr(entryView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_top_margin(ptr(entryView), 6)
        gtk_text_view_set_left_margin(ptr(entryView), 8)
        gtk_text_view_set_right_margin(ptr(entryView), 8)
        gtk_scrolled_window_set_child(op(scroller), entryView)
        Gtk.addClass(scroller, "card")

        Gtk.addClass(sendButton, "suggested-action")
        gtk_widget_set_valign(sendButton, GTK_ALIGN_END)
        Gtk.connect(UnsafeMutableRawPointer(sendButton), "clicked") { [weak self] in
            self?.sendFromComposer()
        }

        gtk_box_append(ptr(row), scroller)
        gtk_box_append(ptr(row), sendButton)
        return row
    }

    private func startRefreshing() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func refresh() async {
        await ServerDirectory.shared.reload()
        let (entries, unreachable) = await ServerDirectory.shared.entries()
        Gtk.onMain { [weak self] in
            self?.applyEntries(entries, unreachable: unreachable)
        }
    }

    private func applyEntries(_ entries: [SessionEntry], unreachable: [String]) {
        self.entries = entries
        Gtk.removeChildren(of: sidebarList)
        if !unreachable.isEmpty {
            let banner = Gtk.label(
                "\(unreachable.joined(separator: ", ")) unreachable", css: "sidebar-detail",
                selectable: false)
            Gtk.margins(banner, top: 4, bottom: 4, leading: 8, trailing: 8)
            gtk_box_append(ptr(sidebarList), banner)
        }
        for (index, entry) in entries.prefix(200).enumerated() {
            gtk_box_append(ptr(sidebarList), makeSidebarRow(entry, index: index))
        }
        if selectedID == nil, !entries.isEmpty { openEntry(at: 0) }
    }

    private func makeSidebarRow(_ entry: SessionEntry, index: Int) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        let title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        let name = Gtk.label(title, css: "sidebar-title", selectable: false)
        let project = entry.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent }
        let detail = Gtk.label(
            [project, entry.profileName].compactMap { $0 }.joined(separator: " · "),
            css: "sidebar-detail", selectable: false)
        gtk_box_append(ptr(column), name)
        gtk_box_append(ptr(column), detail)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        if entry.session.isActive == true {
            let dot = Gtk.label("●", css: "dim", selectable: false)
            gtk_box_append(ptr(row), dot)
        }
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)

        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            self?.openEntry(at: index)
        }
        return button
    }

    private func openEntry(at index: Int) {
        guard index < entries.count else { return }
        let entry = entries[index]
        guard selectedID != entry.session.id else { return }
        selectedID = entry.session.id
        conversation = nil
        streamTask?.cancel()
        renderRows([])
        gtk_label_set_text(op(statusLabel), "")

        streamTask = Task { [weak self] in
            guard let self else { return }
            guard
                let profile = await ServerDirectory.shared.profiles().first(where: {
                    $0.id == entry.profileID
                }), let backend = await ServerDirectory.shared.backend(for: profile)
            else { return }
            let conversation = AgentConversation(
                backend: backend, sessionID: entry.session.id, cache: AppCache.sessionCache)
            self.conversation = conversation
            for await state in await conversation.states() {
                if Task.isCancelled { return }
                let rows = state.messages.flatMap(TranscriptRow.rows(for:))
                let running = state.status == .running
                Gtk.onMain { [weak self] in
                    self?.renderRows(rows)
                    self?.setRunning(running)
                }
            }
        }
    }

    private func setRunning(_ running: Bool) {
        gtk_label_set_text(
            op(statusLabel), running ? Localized.text("Working…") : "")
        gtk_button_set_label(
            ptr(sendButton),
            running ? Localized.text("Queue") : Localized.text("Send"))
    }

    private func renderRows(_ rows: [TranscriptRow]) {
        Gtk.removeChildren(of: transcriptBox)
        for row in rows {
            gtk_box_append(ptr(transcriptBox), row.makeWidget())
        }
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard let scroller = transcriptScroller else { return }
        guard let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) else {
            return
        }
        let raw = UInt(bitPattern: adjustment)
        Gtk.onMain {
            guard let base = UnsafeMutableRawPointer(bitPattern: raw) else { return }
            let adjustment: UnsafeMutablePointer<GtkAdjustment> = ptr(base)
            gtk_adjustment_set_value(
                adjustment,
                gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        }
    }

    private func sendFromComposer() {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return }
        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        g_free(raw)
        guard !text.isEmpty, let conversation else { return }
        gtk_text_buffer_set_text(buffer, "", 0)
        Task { try? await conversation.send(text) }
    }
}
