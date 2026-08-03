import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The window: the chat list, the conversation, and the project it is working in.
///
/// State lives here on the GLib main context; everything that talks to a server happens in a
/// detached `Task` and comes back through ``Gtk/onMain(_:)``. There is no `@MainActor` anywhere in
/// this app — `g_application_run` never drains libdispatch's main queue, so awaiting into a
/// main-actor type from a signal handler would suspend forever with no crash and no log line.
final class MainWindow: @unchecked Sendable {
    private var window: UnsafeMutablePointer<GtkWidget>?
    private let sidebarList = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let sidebarBanner = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let transcriptBox = Gtk.box(
        GTK_ORIENTATION_VERTICAL, spacing: Preferences.denseRows ? 3 : 10)
    private let pendingBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let authBanner = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    private let statusBand = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    private let bandState = StatusBand.State()
    private var agents: [SubagentSummary] = []
    private var usage: AgentUsage?
    private var contextEstimate: Int?
    private var echoedPrompt: String?
    private var notice: String?
    private let entryView = gtk_text_view_new()!
    private let sendButton = gtk_button_new_with_label("Send")!
    private let stopButton = gtk_button_new_with_label("⏹")!
    private let titleLabel = Gtk.label("", css: "mono", selectable: false)
    private var modelButton: UnsafeMutablePointer<GtkWidget>?
    private var effortButton: UnsafeMutablePointer<GtkWidget>?
    private var commandButton: UnsafeMutablePointer<GtkWidget>?
    private let destinationLabel = Gtk.label("", css: "row-detail", selectable: false)
    private var transcriptScroller: UnsafeMutablePointer<GtkWidget>?
    private let fileTree = FileTree()
    private let terminal = TerminalPane()

    private let searchEntry = gtk_search_entry_new()!
    private let helpOverlay = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)

    private let attachmentsBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private var attachments: [PendingAttachment] = []
    private var pastedImageCount = 0

    private let jumpButton = gtk_button_new()!
    private var unseenRows = 0
    private var followsBottom = true
    private var isAutoScrolling = false
    private var isFillingInChunks = false
    private var pinCorrectorScheduled = false
    private var pendingReveal = false
    private var fillComplete = false
    private var sidebarLimit = 60
    /// How much of a transcript is folded into rows at all — read from the streaming task, so it
    /// is a plain value rather than anything that needs the main context.
    private nonisolated(unsafe) var rowTailMessages = 300

    private let findBar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let findEntry = gtk_search_entry_new()!
    private let findCountLabel = Gtk.label("", css: "row-detail", selectable: false)
    private var findMatches: [Int] = []
    private var findCursor = 0
    private var highlightedRow: UInt = 0
    private var canvasBox: UnsafeMutablePointer<GtkWidget>?
    private var pendingSignature = "\u{0}"

    private let usageBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private var usageTask: Task<Void, Never>?

    private var splitWidget: UnsafeMutablePointer<GtkWidget>?
    private var projectPaned: UnsafeMutablePointer<GtkWidget>?
    private var terminalPaned: UnsafeMutablePointer<GtkWidget>?
    private var sidebarPane: UnsafeMutablePointer<GtkWidget>?
    private var composerScroller: UnsafeMutablePointer<GtkWidget>?
    private var composerHeight: Int32 = 0
    private var isMeasuringComposer = false
    private let vim = VimEngine()
    private let vimBadge = Gtk.label("", css: "vim-badge", selectable: false)
    private let earlierButton = gtk_button_new()!
    private var windowLimit = 400
    private var lastFullRows: [TranscriptRow] = []
    private var lastFullCount = 0
    private var lastSidebar: ([SessionRowModel], [String], String, String)?

    private let context = TranscriptContext()
    private let rowBuilder = TranscriptRowBuilder()
    /// The last full row list per session, so returning to a chat paints it in the first frame —
    /// the network's newer truth then lands as a quiet diff instead of a blank-and-rebuild.
    private var sessionRows: [String: [TranscriptRow]] = [:]
    private var sessionRowOrder: [String] = []
    private var renderedRows: [TranscriptRow] = []
    private var rowWidgets: [UInt] = []
    private var placeholderShown = false
    private var currentPlaceholder: String?
    /// The chat the person just started from the + button: known-empty, so it renders ready
    /// instead of "Connecting…" while its stream catches up — and kept in the list by hand until
    /// the server's own listing carries it, because a bridge that answers `GET /sessions` from a
    /// sweep a second old would otherwise blink the row away.
    private var freshlyCreated: SessionEntry?
    private var inFlightImages: Set<String> = []
    private var inFlightSubagents: Set<String> = []

    private var entries: [SessionEntry] = []
    /// Sessions whose delete is confirmed but not yet acknowledged by the server. Every listing —
    /// the 10-second refresh, the session-list stream, a stale request already in flight — keeps
    /// reporting the session until the delete lands, and each report would resurrect the row; the
    /// tombstone outlives them all and is lifted only once the app's own post-delete refresh has
    /// reconciled, or the delete failed and the row should genuinely return.
    private var pendingDeletes: Set<String> = []
    private var showingArchive = false
    private var sidebarScroller: UnsafeMutablePointer<GtkWidget>?
    private var sidebarScrollTarget: Double?
    private var visible: [SessionRowModel] = []
    private var unreachable: [String] = []
    private var lastQuotas: [(String, UsageQuota)] = []
    private var cursor = 0
    private var filter = ""
    private var pendingChords: [KeyChord] = []
    private var shortcuts = ShortcutSet.load()
    private var helpShown = false
    private var focused: Pane = .chats
    private var selectedID: String?
    private var currentEntry: SessionEntry?
    private var currentBackend: (any CodingAgentBackend)?
    private var conversation: AgentConversation?
    private var lastState: ConversationState?
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var toastOverlay: UnsafeMutablePointer<GtkWidget>?
    private var listStreamTasks: [Task<Void, Never>] = []
    private var agentStreamTask: Task<Void, Never>?
    private var agentStreamSessionID: String?
    private var tickerTask: Task<Void, Never>?
    private var turnStartedAt: Date?

    private var models: [ModelInfo] = []
    private var commands: [AgentCommand] = []
    private var completionPopover: UnsafeMutablePointer<GtkWidget>?
    private var completionMatches: [AgentCommand] = []
    private var completionCursor = 0
    private var chosenModel: ModelSelection?
    private var chosenEffort: String?

    /// The canvas follows the desktop: KDE flipping to dark at sunset restyles the chrome through
    /// libadwaita and lands here, where the palette and the markup baked into prose rows are
    /// traded for the other set. And the chats you had are on screen before the first byte
    /// crosses the tailnet — a server that takes fifteen seconds to list its sessions must not
    /// mean fifteen seconds of empty window — with liveness stripped from the cache, so nothing
    /// shown from it can claim to be running.
    func present(in app: UnsafeMutablePointer<AdwApplication>) {
        Preferences.applyAppearance()
        MatrixTheme.install()
        terminal.applyPalette(MatrixTheme.palette)
        UIScale.apply()
        if let manager = adw_style_manager_get_default() {
            Gtk.onNotify(UnsafeMutableRawPointer(manager), property: "dark") { [weak self] in
                Gtk.onMain { [weak self] in self?.retheme() }
            }
        }
        Task.detached { DesktopIntegration.ensureInstalled() }

        let window = adw_application_window_new(ptr(app))!
        gtk_window_set_title(ptr(window), "Tailscode")
        let size = Preferences.windowSize
        gtk_window_set_default_size(ptr(window), size.width, size.height)
        if Preferences.windowMaximized { gtk_window_maximize(ptr(window)) }
        gtk_window_set_icon_name(ptr(window), DesktopIntegration.appID)
        self.window = window

        let split = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(op(split), makeSidebarPane())
        gtk_paned_set_end_child(op(split), makeContentPane())
        gtk_paned_set_position(op(split), Preferences.divider(.sidebar) ?? 300)
        gtk_paned_set_resize_start_child(op(split), 0)
        gtk_paned_set_shrink_start_child(op(split), 0)
        gtk_paned_set_resize_end_child(op(split), 1)
        splitWidget = split

        let stack = gtk_paned_new(GTK_ORIENTATION_VERTICAL)!
        gtk_paned_set_start_child(op(stack), split)
        gtk_paned_set_end_child(op(stack), terminal.widget)
        gtk_paned_set_position(op(stack), Preferences.divider(.terminal) ?? 600)
        gtk_paned_set_resize_start_child(op(stack), 1)
        gtk_paned_set_shrink_end_child(op(stack), 0)
        terminalPaned = stack

        let overlay = adw_toast_overlay_new()!
        adw_toast_overlay_set_child(op(overlay), stack)
        toastOverlay = overlay
        adw_application_window_set_content(ptr(window), overlay)
        gtk_window_present(ptr(window))

        fileTree.onOpen = { [weak self] path in self?.insertIntoComposer("@\(path) ") }
        wireContext()
        installKeymap(on: window)
        Notifier.shared.attach(app: app) { [weak self] sessionID in
            self?.openSession(withID: sessionID)
        }
        applyPanePreferences()
        let cachedEntries = SessionListCache.load()
        if !cachedEntries.isEmpty { applyEntries(cachedEntries, unreachable: []) }
        startRefreshing()
        startUsagePolling()
        FirstRunDialog.presentIfNeeded(parent: window) { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
        if let seed = ProcessInfo.processInfo.environment["TAILSCODE_COMPOSER"] {
            insertIntoComposer(seed.replacingOccurrences(of: "\\n", with: "\n"))
        }
        installDriver()
    }

    /// `TAILSCODE_DRIVE="2000:open=1;4000:up=400;6000:jump"` — timed UI actions for headless
    /// validation, driving the same code paths a person's clicks and wheel do. An agent cannot
    /// operate a mouse over ssh; it can read a recording of the app driving itself.
    private func installDriver() {
        guard let script = ProcessInfo.processInfo.environment["TAILSCODE_DRIVE"] else { return }
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let delay = UInt32(parts[0]) else { continue }
            let action = String(parts[1])
            Gtk.after(delay) { [weak self] in
                guard let self else { return }
                FileHandle.standardOutput.write(Data("DRIVE \(delay) \(action)\n".utf8))
                let pieces = action.split(separator: "=", maxSplits: 1)
                let verb = String(pieces.first ?? "")
                let argument = pieces.count > 1 ? String(pieces[1]) : ""
                switch verb {
                case "open":
                    if let index = Int(argument), index < self.visible.count {
                        self.open(self.visible[index].entry)
                    }
                case "newchat":
                    Task { [weak self] in
                        let profiles = await ServerDirectory.shared.profiles()
                        guard let profile = profiles.first else { return }
                        Gtk.onMain { [weak self] in
                            self?.createChat(
                                on: profile, directory: argument.isEmpty ? nil : argument)
                        }
                    }
                case "up":
                    self.scroll(by: -(Double(argument) ?? 200))
                case "down":
                    self.scroll(by: Double(argument) ?? 200)
                case "jump":
                    self.jumpToBottom()
                case "settings":
                    self.presentSettings()
                case "usage":
                    self.presentUsage()
                case "type":
                    gtk_widget_grab_focus(self.entryView)
                    self.vim.reset(to: argument, cursor: argument.count, mode: .insert)
                    gtk_text_buffer_set_text(
                        gtk_text_view_get_buffer(ptr(self.entryView)), argument, -1)
                    let names = self.completionMatches.prefix(5).map(\.name)
                    FileHandle.standardOutput.write(
                        Data(
                            "COMPLETION \(self.completionMatches.count) [\(names.joined(separator: ","))] shown=\(self.completionShown)\n"
                                .utf8))
                case "tab":
                    _ = self.handleComposerKey(keyval: Keymap.tab, state: 0)
                    FileHandle.standardOutput.write(
                        Data("COMPOSER \"\(self.composerText())\"\n".utf8))
                case "term":
                    _ = self.perform(.toggleTerminal)
                    Gtk.after(300) { [weak self] in
                        guard let self, let window = self.window else { return }
                        FileHandle.standardOutput.write(
                            Data("TERMFOCUS \(self.terminal.ownsFocus(in: window))\n".utf8))
                    }
                case "agents":
                    self.bandState.openMenu(id: "agents")
                case "toast":
                    self.toast(Localized.text("Command copied"))
                case "reader":
                    self.context.presentText?(
                        "Compaction summary", "COMPACTED · 527.8k → 24.8k · 2m 4s",
                        """
                        ## 1. Primary Request and Intent

                        The user asked for a **full performance remaster** of the Linux app, with
                        *proper* theming and `TranscriptRow` rebuilt off-main.

                        - Tail-first fill so the visible screenful lands in one frame
                        - Disk-cached images keyed by their server path
                        - A pin that runs outside layout, never inside `changed`

                        ```swift
                        func schedulePinCorrector() {
                            Gtk.onMain { self.pinToBottom() }
                        }
                        ```

                        > A frozen frame is worse than a slow answer.

                        See [the docs](https://docs.gtk.org/gtk4/) for `GtkViewport` details.
                        """,
                        false)
                case "scale":
                    Preferences.setScale((Double(argument) ?? 100) / 100, for: .prose)
                    Preferences.setScale((Double(argument) ?? 100) / 100, for: .mono)
                    MatrixTheme.install()
                    self.applyLayoutPreferences()
                case "state":
                    let adjustment = self.transcriptScroller.flatMap {
                        gtk_scrolled_window_get_vadjustment(op($0))
                    }
                    let value = adjustment.map { gtk_adjustment_get_value($0) } ?? -1
                    let upper = adjustment.map {
                        gtk_adjustment_get_upper($0) - gtk_adjustment_get_page_size($0)
                    } ?? -1
                    FileHandle.standardOutput.write(
                        Data(
                            "STATE follows=\(self.followsBottom) rows=\(self.renderedRows.count)/\(self.lastFullRows.count) value=\(Int(value)) bottom=\(Int(upper)) unseen=\(self.unseenRows)\n"
                            .utf8))
                default:
                    break
                }
            }
        }
    }

    private func makeSidebarPane() -> UnsafeMutablePointer<GtkWidget> {
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        adw_header_bar_set_show_end_title_buttons(op(header), 0)
        adw_header_bar_set_title_widget(
            op(header), Gtk.label("TAILSCODE", css: "section-header", selectable: false))
        adw_header_bar_pack_start(
            op(header),
            Gtk.button("+", css: ["flat"]) { [weak self] in self?.presentNewChat() })
        adw_header_bar_pack_end(
            op(header),
            Gtk.menuButton("⚙", css: ["flat"]) { [weak self] in
                let settings: @Sendable () -> Void = { [weak self] in
                    Gtk.onMain { [weak self] in self?.presentSettings() }
                }
                let servers: @Sendable () -> Void = { [weak self] in
                    Gtk.onMain { [weak self] in self?.presentServers() }
                }
                return [
                    (Localized.text("Settings…"),
                     Localized.text("Type sizes, the prompt box, vim mode, layout"), settings),
                    (Localized.text("Servers…"),
                     Localized.text("Add, probe, update or remove a server"), servers),
                ]
            })
        adw_toolbar_view_add_top_bar(op(toolbar), header)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_search_entry_set_placeholder_text(op(searchEntry), Localized.text("Filter chats  /"))
        Gtk.margins(searchEntry, top: 4, bottom: 4, leading: 6, trailing: 6)
        Gtk.connect(UnsafeMutableRawPointer(searchEntry), "search-changed") { [weak self] in
            self?.applyFilterFromEntry()
        }
        gtk_box_append(ptr(column), searchEntry)
        gtk_box_append(ptr(column), sidebarBanner)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        Gtk.margins(sidebarList, top: 2, bottom: 8, leading: 6, trailing: 6)
        gtk_scrolled_window_set_child(op(scroller), sidebarList)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(ptr(column), scroller)
        sidebarScroller = scroller

        gtk_widget_set_visible(usageBox, 0)
        Gtk.addClass(usageBox, "usage-footer")
        Gtk.margins(usageBox, top: 6, bottom: 8, leading: 10, trailing: 10)
        gtk_widget_set_cursor_from_name(usageBox, "pointer")
        gtk_widget_set_tooltip_text(usageBox, Localized.text("The full quota picture"))
        Gtk.onRelease(usageBox) { [weak self] in self?.presentUsage() }
        gtk_box_append(ptr(column), usageBox)

        adw_toolbar_view_set_content(op(toolbar), column)
        Gtk.addClass(toolbar, "sidebar-pane")
        sidebarPane = toolbar
        return toolbar
    }

    /// Conversation on the left of the content area, the project it works in on the right: the
    /// files the agent is editing and a shell in the same directory, because reading what it just
    /// changed and running the thing it just built are the two moves that otherwise send you back
    /// to a terminal. Both panes may be squeezed below their natural width: without that, a pane
    /// whose content is naturally wide — a long status segment, a deep file path — makes the
    /// split wider than the window, and GTK resolves that by drawing the conversation off the
    /// left edge, underneath the chat list.
    private func makeContentPane() -> UnsafeMutablePointer<GtkWidget> {
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        adw_header_bar_set_show_start_title_buttons(op(header), 0)
        adw_header_bar_set_title_widget(op(header), titleLabel)
        adw_header_bar_pack_start(
            op(header),
            Gtk.button("☰", css: ["flat"]) { [weak self] in self?.togglePane(.sidebar) })
        adw_header_bar_pack_end(op(header), makeActionsButton())
        adw_header_bar_pack_end(
            op(header),
            Gtk.button("▥", css: ["flat"]) { [weak self] in self?.togglePane(.files) })
        adw_header_bar_pack_end(
            op(header),
            Gtk.button("⌨", css: ["flat"]) { [weak self] in self?.togglePane(.terminal) })
        adw_toolbar_view_add_top_bar(op(toolbar), header)

        let panes = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(op(panes), makeConversationColumn())
        gtk_paned_set_end_child(op(panes), makeProjectColumn())
        gtk_paned_set_position(op(panes), Preferences.divider(.project) ?? 800)
        gtk_paned_set_resize_start_child(op(panes), 1)
        gtk_paned_set_shrink_start_child(op(panes), 1)
        gtk_paned_set_shrink_end_child(op(panes), 1)
        projectPaned = panes

        adw_toolbar_view_set_content(op(toolbar), panes)
        return toolbar
    }

    /// The vadjustment's `changed` signal fires when the content's extent moves — including while
    /// the window is unfocused and doing no other work — which is the only moment at which "stay
    /// at the bottom" can be honoured correctly. The pin must never run inside that signal: it
    /// fires during the viewport's own allocation, and a value written mid-layout is accepted but
    /// never drawn — the scrollbar says bottom while the pixels stay put until the window is
    /// disturbed — so the pin runs on the next idle, outside layout, where the viewport reacts to
    /// it the ordinary way.
    private func makeConversationColumn() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(column, "canvas")
        gtk_widget_set_size_request(column, 320, -1)

        Gtk.addClass(authBanner, "banner-auth")
        gtk_widget_set_visible(authBanner, 0)
        gtk_box_append(ptr(column), authBanner)

        gtk_box_append(ptr(column), makeFindBar())

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        let canvas = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Preferences.denseRows ? 4 : 10)
        Gtk.addClass(canvas, "transcript")
        canvasBox = canvas
        gtk_widget_set_visible(earlierButton, 0)
        Gtk.addClass(earlierButton, "flat")
        Gtk.addClass(earlierButton, "dim")
        Gtk.connect(UnsafeMutableRawPointer(earlierButton), "clicked") { [weak self] in
            guard let self, let state = self.lastState else { return }
            self.windowLimit += 400
            self.rowTailMessages += 600
            self.apply(state: state, rows: self.lastFullRows)
            Task { [weak self] in await self?.conversation?.reconnect() }
        }
        gtk_box_append(ptr(canvas), earlierButton)
        gtk_box_append(ptr(canvas), transcriptBox)
        Gtk.margins(pendingBox, top: 8)
        gtk_box_append(ptr(canvas), pendingBox)
        gtk_scrolled_window_set_child(op(scroller), canvas)
        gtk_widget_set_vexpand(scroller, 1)
        transcriptScroller = scroller

        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), scroller)
        gtk_widget_set_vexpand(overlay, 1)
        Gtk.addClass(jumpButton, "jump-pill")
        gtk_widget_set_halign(jumpButton, GTK_ALIGN_END)
        gtk_widget_set_valign(jumpButton, GTK_ALIGN_END)
        Gtk.margins(jumpButton, bottom: 14, trailing: 22)
        gtk_widget_set_visible(jumpButton, 0)
        Gtk.connect(UnsafeMutableRawPointer(jumpButton), "clicked") { [weak self] in
            self?.jumpToBottom()
        }
        gtk_overlay_add_overlay(op(overlay), jumpButton)
        gtk_box_append(ptr(column), overlay)

        if let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) {
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "changed") { [weak self] in
                guard let self, self.followsBottom else { return }
                self.schedulePinCorrector()
            }
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "value-changed") { [weak self] in
                guard let self, !self.isAutoScrolling else { return }
                let atBottom = self.isNearBottom()
                self.followsBottom = atBottom
                if atBottom { self.clearUnseen() }
            }
        }

        gtk_widget_set_visible(helpOverlay, 0)
        Gtk.addClass(helpOverlay, "canvas")
        Gtk.margins(helpOverlay, top: 8, bottom: 8, leading: 26, trailing: 26)
        rebuildHelpOverlay()
        gtk_box_append(ptr(column), helpOverlay)

        Gtk.addClass(statusBand, "status-band")
        gtk_box_append(ptr(column), statusBand)
        gtk_widget_set_visible(attachmentsBox, 0)
        Gtk.margins(attachmentsBox, top: 4, leading: 26, trailing: 26)
        gtk_box_append(ptr(column), attachmentsBox)
        gtk_box_append(ptr(column), makeComposer())
        gtk_box_append(ptr(column), makePillRow())
        return column
    }

    private func makeProjectColumn() -> UnsafeMutablePointer<GtkWidget> {
        gtk_widget_set_size_request(fileTree.widget, 180, -1)
        return fileTree.widget
    }

    /// Dropping files on the prompt box attaches them, which is how a file gets from a file
    /// manager into a conversation without a dialog in between.
    private func makeComposer() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 10, bottom: 4, leading: 26, trailing: 26)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_hexpand(scroller, 1)
        composerScroller = scroller
        gtk_text_view_set_wrap_mode(ptr(entryView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_monospace(ptr(entryView), 1)
        gtk_text_view_set_top_margin(ptr(entryView), 8)
        gtk_text_view_set_left_margin(ptr(entryView), 10)
        gtk_text_view_set_right_margin(ptr(entryView), 10)
        gtk_scrolled_window_set_child(op(scroller), entryView)
        Gtk.addClass(scroller, "composer")
        Gtk.connect(
            UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(entryView))), "changed"
        ) { [weak self] in
            self?.growComposer()
            self?.updateSlashCompletion()
        }

        Gtk.addClass(sendButton, "suggested-action")
        gtk_widget_set_valign(sendButton, GTK_ALIGN_END)
        Gtk.connect(UnsafeMutableRawPointer(sendButton), "clicked") { [weak self] in
            self?.sendFromComposer()
        }

        let attach = Gtk.menuButton("📎", css: ["flat"]) { [weak self] in
            self?.attachRows() ?? []
        }
        gtk_widget_set_valign(attach, GTK_ALIGN_END)

        gtk_box_append(ptr(row), scroller)
        gtk_box_append(ptr(row), attach)
        gtk_box_append(ptr(row), sendButton)

        Gtk.acceptFileDrops(on: row) { [weak self] paths in
            self?.attach(paths: paths)
        }
        return row
    }

    /// The transcript's own search, over what the rows say rather than what the server indexes:
    /// it works offline, on a saved copy, and mid-turn.
    private func makeFindBar() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(findBar, "find-bar")
        gtk_widget_set_visible(findBar, 0)
        Gtk.margins(findBar, top: 4, bottom: 4, leading: 26, trailing: 26)

        gtk_search_entry_set_placeholder_text(
            op(findEntry), Localized.text("Find in this conversation"))
        gtk_widget_set_hexpand(findEntry, 1)
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "search-changed") { [weak self] in
            self?.runFind(retarget: true)
        }
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "activate") { [weak self] in
            self?.stepFind(by: 1)
        }
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "stop-search") { [weak self] in
            self?.setFindShown(false)
        }
        gtk_box_append(ptr(findBar), findEntry)
        gtk_box_append(ptr(findBar), findCountLabel)
        gtk_box_append(
            ptr(findBar), Gtk.button("↑", css: ["flat"]) { [weak self] in self?.stepFind(by: -1) })
        gtk_box_append(
            ptr(findBar), Gtk.button("↓", css: ["flat"]) { [weak self] in self?.stepFind(by: 1) })
        gtk_box_append(
            ptr(findBar),
            Gtk.button("✕", css: ["flat"]) { [weak self] in self?.setFindShown(false) })
        return findBar
    }

    /// The line under the composer that says where the next prompt goes and how: destination,
    /// model, effort, the command palette, and stop. The CLI's status line, made clickable.
    private func makePillRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(row, "pill-row")

        gtk_widget_set_visible(vimBadge, 0)
        gtk_box_append(ptr(row), vimBadge)
        gtk_box_append(ptr(row), destinationLabel)

        let model = Gtk.menuButton(Localized.text("model")) { [weak self] in
            self?.modelRows() ?? []
        }
        modelButton = model
        gtk_box_append(ptr(row), model)

        let effort = Gtk.menuButton(Localized.text("effort")) { [weak self] in
            self?.effortRows() ?? []
        }
        effortButton = effort
        gtk_box_append(ptr(row), effort)

        let palette = Gtk.menuButton("/") { [weak self] in
            self?.commandRows() ?? []
        }
        commandButton = palette
        gtk_box_append(ptr(row), palette)

        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(row), spacer)

        gtk_widget_set_visible(stopButton, 0)
        Gtk.addClass(stopButton, "destructive-action")
        Gtk.connect(UnsafeMutableRawPointer(stopButton), "clicked") { [weak self] in
            self?.stopTurn()
        }
        gtk_box_append(ptr(row), stopButton)
        return row
    }

    private func makeActionsButton() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.menuButton("⋯", css: ["flat"]) { [weak self] in
            self?.actionRows() ?? []
        }
    }

    /// Opening the last row grows the transcript below the fold; if the person was at the bottom,
    /// the bottom must follow them to what they just opened.
    private func wireContext() {
        context.onToggle = { [weak self] key, open in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if open { self.context.expanded.insert(key) } else {
                    self.context.expanded.remove(key)
                }
                if open, self.followsBottom { self.schedulePinCorrector() }
            }
        }
        context.requestImage = { [weak self] reference, key in
            Gtk.onMain { [weak self] in self?.fetchImage(reference, key: key) }
        }
        context.requestSubagent = { [weak self] call in
            Gtk.onMain { [weak self] in self?.fetchSubagent(call) }
        }
        context.openImage = { [weak self] key, name in
            Gtk.onMain { [weak self] in self?.presentImage(key: key, name: name) }
        }
        context.toast = { [weak self] text in
            Gtk.onMain { [weak self] in self?.toast(text) }
        }
        context.presentText = { [weak self] title, subtitle, body, mono in
            Gtk.onMain { [weak self] in
                Dialogs.reader(
                    title: title, subtitle: subtitle, body: body, mono: mono,
                    parent: self?.window)
            }
        }
    }

    /// A two-second floating confirmation — the answer to "did my click do anything".
    func toast(_ text: String) {
        guard let toastOverlay else { return }
        let toast = adw_toast_new(text)
        adw_toast_set_timeout(toast, 2)
        adw_toast_overlay_add_toast(op(toastOverlay), toast)
    }

    /// Opens the gallery over every picture in the conversation, landed on the one clicked.
    private func presentImage(key: String, name: String) {
        let items: [ImageGallery.Item] = lastFullRows.compactMap { row in
            guard case .file(let reference) = row.kind,
                (reference.mime ?? "").hasPrefix("image/")
            else { return nil }
            let name =
                reference.filename
                ?? reference.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "image"
            return ImageGallery.Item(key: row.key, name: name, reference: reference)
        }
        guard !items.isEmpty else { return }
        ImageGallery.present(
            items: items, startKey: key, parent: window, context: context,
            fetch: { [weak self] reference, key in
                Gtk.onMain { [weak self] in self?.fetchImage(reference, key: key) }
            },
            notice: { [weak self] text in
                Gtk.onMain { [weak self] in self?.setNotice(text) }
            })
    }

    private func startRefreshing() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        startListStreams()
    }

    /// A proto-2 bridge pushes list changes the moment they happen; the 10-second poll survives
    /// only as reachability detection and as the whole story for older servers.
    private func startListStreams() {
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            for profile in profiles {
                guard let backend = await ServerDirectory.shared.backend(for: profile),
                    let streaming = backend as? SessionListStreaming,
                    let changes = await streaming.sessionListChanges()
                else { continue }
                let task = Task { [weak self] in
                    for await change in changes {
                        guard let self else { return }
                        Gtk.onMain { [weak self] in self?.applyListChange(change, profile: profile) }
                    }
                }
                Gtk.onMain { [weak self] in self?.listStreamTasks.append(task) }
            }
        }
    }

    private func applyListChange(_ change: SessionListChange, profile: ConnectionProfile) {
        switch change {
        case .upsert(let session):
            let entry = SessionEntry(
                profileID: profile.id, profileName: profile.name,
                host: profile.baseURL.host ?? profile.name,
                backendType: profile.backend, session: session)
            var next = entries.filter {
                !($0.profileID == profile.id && $0.session.id == session.id)
            }
            next.append(entry)
            next.sort { $0.session.updatedAt > $1.session.updatedAt }
            entries = next
            if !next.isEmpty { SessionListCache.save(next) }
            renderSidebar()
            if session.id == selectedID { refreshPills() }
        case .remove(let id):
            entries.removeAll { $0.profileID == profile.id && $0.session.id == id }
            renderSidebar()
        case .invalidated:
            Task { [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        await ServerDirectory.shared.reload()
        let (entries, unreachable) = await ServerDirectory.shared.entries()
        if !entries.isEmpty { SessionListCache.save(entries) }
        Gtk.onMain { [weak self] in
            self?.rememberDividers()
            self?.applyEntries(entries, unreachable: unreachable)
            SettingsFile.capture()
        }
    }

    /// Opens the conversation that was open last, not merely the newest one: reopening where you
    /// were is the difference between a window that restores and a window that resets.
    private func applyEntries(_ entries: [SessionEntry], unreachable: [String]) {
        self.entries = entries
        self.unreachable = unreachable
        if let fresh = freshlyCreated {
            if entries.contains(where: { $0.session.id == fresh.session.id }) {
                freshlyCreated = nil
            } else {
                self.entries.insert(fresh, at: 0)
            }
        }
        renderSidebar()
        guard selectedID == nil, !entries.isEmpty else { return }
        let remembered = Preferences.lastSession.flatMap { id in
            entries.first { $0.session.id == id }
        }
        open(remembered ?? entries[0])
    }

    /// Rebuilding two hundred rows of widgets is a visible stutter, and the 10-second refresh
    /// would do it whether or not anything changed — so nothing is touched unless what the list
    /// would say actually differs from what it says now. Two hundred chats is also two hundred
    /// rows of widgets, and building them all is the freeze you feel at launch: only the first
    /// screenful or two are built, the rest arrive when asked for, and the filter still searches
    /// every chat.
    private func renderSidebar() {
        Trace.mark("renderSidebar begin \(entries.count) entries")
        defer { Trace.mark("renderSidebar end") }
        let savedChats = SavedChatStore.all()
        let saved = Set(savedChats.map(\.sessionID))
        let unread = SessionSeenStore.unreadEvaluator()
        let needle = filter.lowercased()
        var rows = entries.filter { !pendingDeletes.contains($0.session.id) }.map {
            SessionRowModel(
                entry: $0,
                unreachable: unreachable.contains(
                    ServerLabel.display(name: $0.profileName, backend: $0.backendType)),
                unread: unread($0.session.id, $0.session.updatedAt),
                saved: saved.contains($0.session.id))
        }
        rows += Self.orphanedSavedRows(savedChats, listed: entries)
        Notifier.shared.observeListing(
            rows.map {
                ActivityObservation(
                    profileID: $0.entry.profileID, sessionID: $0.entry.session.id,
                    title: $0.title, isActive: $0.entry.session.isActive == true)
            },
            openSessionID: selectedID, windowActive: windowIsActive)
        let archivedKeys = ArchivedChatStore.all()
        let isArchived: (SessionRowModel) -> Bool = {
            archivedKeys.contains(ArchivedChatStore.key($0.entry.profileID, $0.entry.session.id))
        }
        let archivedTotal = rows.filter(isArchived).count
        let matching = rows.filter {
            needle.isEmpty || $0.title.lowercased().contains(needle)
                || $0.detail.lowercased().contains(needle)
        }
        let active = matching.filter {
            !isArchived($0) || $0.state == .live || $0.state == .awaitingApproval
        }
        let sections: [(String, [SessionRowModel])] =
            showingArchive
            ? [(Localized.text("ARCHIVED"), matching.filter(isArchived))].filter { !$0.1.isEmpty }
            : groupIntoSections(active).map { ($0.0.title, $0.1) }
        visible = sections.flatMap(\.1)
        syncCursorToSelection()

        let snapshot = (
            visible, unreachable, filter,
            "\(selectedID ?? "")|\(sidebarLimit)|\(showingArchive)|\(archivedTotal)"
        )
        if let last = lastSidebar, last == snapshot { return }
        lastSidebar = snapshot

        let scrollTarget = sidebarScrollTarget ?? sidebarScrollValue()
        sidebarScrollTarget = nil
        defer { restoreSidebarScroll(scrollTarget) }

        Gtk.removeChildren(of: sidebarBanner)
        if !unreachable.isEmpty {
            gtk_box_append(
                ptr(sidebarBanner),
                SidebarRow.banner(
                    Localized.text("%@ unreachable — showing what was last seen",
                        unreachable.joined(separator: ", "))))
        }

        Gtk.removeChildren(of: sidebarList)
        if showingArchive {
            gtk_box_append(
                ptr(sidebarList),
                Gtk.button(Localized.text("← All chats"), css: ["flat", "dim"]) { [weak self] in
                    Gtk.onMain { [weak self] in self?.setArchiveShown(false) }
                })
        }
        guard !visible.isEmpty else {
            gtk_box_append(
                ptr(sidebarList),
                SidebarRow.empty(
                    showingArchive
                        ? Localized.text("Nothing archived")
                        : filter.isEmpty
                            ? Localized.text("No conversations yet")
                            : Localized.text("Nothing matches “%@”", filter)))
            appendArchiveFooter(archivedTotal)
            return
        }

        var built = 0
        for (title, members) in sections {
            guard built < sidebarLimit else { break }
            gtk_box_append(
                ptr(sidebarList), SidebarRow.header(title, count: members.count))
            for row in members {
                guard built < sidebarLimit else { break }
                gtk_box_append(
                    ptr(sidebarList),
                    SidebarRow.make(
                        row, focused: row.entry.session.id == selectedID,
                        onOpen: { [weak self] in
                            self?.open(row.entry)
                        },
                        onMenu: { [weak self] bits, x, y in
                            self?.presentRowMenu(row, rowBits: bits, x: x, y: y)
                        }))
                built += 1
            }
        }
        let remaining = visible.count - built
        if remaining > 0 {
            let more = Gtk.button(
                Localized.text("%@ more chats", "\(remaining)"), css: ["flat", "dim"]
            ) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.sidebarLimit += 200
                    self.lastSidebar = nil
                    self.renderSidebar()
                }
            }
            Gtk.margins(more, top: 6, bottom: 10)
            gtk_box_append(ptr(sidebarList), more)
        }
        appendArchiveFooter(archivedTotal)
    }

    /// The archive's one entry point: a quiet count at the foot of the list. Absent while
    /// nothing is archived, so the feature costs no room until it is used.
    private func appendArchiveFooter(_ archivedTotal: Int) {
        guard !showingArchive, archivedTotal > 0 else { return }
        let button = Gtk.button(
            Localized.text("%@ archived", "\(archivedTotal)"), css: ["flat", "dim"]
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.setArchiveShown(true) }
        }
        Gtk.margins(button, top: 6, bottom: 10)
        gtk_box_append(ptr(sidebarList), button)
    }

    private func toggleArchived(_ entry: SessionEntry) {
        ArchivedChatStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
        SettingsFile.capture()
        renderSidebar()
    }

    private func setArchiveShown(_ shown: Bool) {
        guard showingArchive != shown else { return }
        showingArchive = shown
        cursor = 0
        lastSidebar = nil
        sidebarScrollTarget = 0
        renderSidebar()
    }

    private func sidebarScrollValue() -> Double {
        guard let sidebarScroller else { return 0 }
        return gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(op(sidebarScroller)))
    }

    /// Rebuilding the list resets the scroll to the top, which turns every click deep in a long
    /// list into a lost place. The old offset is put back from an idle callback — after GTK's
    /// resize pass, so the fresh rows have a height for the adjustment to clamp against.
    private func restoreSidebarScroll(_ value: Double) {
        guard value > 0, let sidebarScroller else { return }
        let bits = UInt(bitPattern: sidebarScroller)
        Gtk.onMain {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            gtk_adjustment_set_value(gtk_scrolled_window_get_vadjustment(op(raw)), value)
        }
    }

    /// The highlight follows the conversation that is open, never a position: the list re-sorts on
    /// every refresh — a chat going live jumps to the top — so a row index means something
    /// different a second later. The keyboard cursor is re-derived from the open chat here so J/K
    /// continues from where the eye is, in the order the list is actually drawn.
    private func syncCursorToSelection() {
        guard !visible.isEmpty else {
            cursor = 0
            return
        }
        if let selectedID, let index = visible.firstIndex(where: { $0.entry.session.id == selectedID }) {
            cursor = index
        } else {
            cursor = min(cursor, visible.count - 1)
        }
    }

    private func applyFilterFromEntry() {
        guard let raw = gtk_editable_get_text(op(searchEntry)) else { return }
        filter = String(cString: raw)
        cursor = 0
        renderSidebar()
    }

    /// A bookmark must still list and explain itself when its server is unreachable, its session
    /// deleted, or its profile removed — the saved list never depends on a live listing. Rows for
    /// chats the listing no longer covers are rebuilt from the bookmark's own snapshot.
    private static func orphanedSavedRows(
        _ savedChats: [SavedChat], listed: [SessionEntry]
    ) -> [SessionRowModel] {
        let listedIDs = Set(listed.map(\.session.id))
        return savedChats.filter { !listedIDs.contains($0.sessionID) }.map { chat in
            let session = AgentSession(
                id: chat.sessionID, agentType: chat.backend, title: chat.displayTitle,
                directory: chat.directory, createdAt: chat.savedAt, updatedAt: chat.updatedAt)
            let entry = SessionEntry(
                profileID: chat.profileID, profileName: chat.profileName,
                host: chat.profileName, backendType: chat.backend, session: session)
            return SessionRowModel(entry: entry, unreachable: true, unread: false, saved: true)
        }
    }

    private var windowIsActive: Bool {
        guard let window else { return false }
        return gtk_window_is_active(ptr(window)) != 0
    }

    /// A notification tap arrives here: raise the window, then open the session it names —
    /// refreshing first when the listing does not carry it yet.
    func openSession(withID id: String) {
        if let window { gtk_window_present(ptr(window)) }
        if let entry = entries.first(where: { $0.session.id == id }) {
            open(entry)
            return
        }
        Task { [weak self] in
            await self?.refresh()
            Gtk.onMain { [weak self] in
                guard let self, let entry = self.entries.first(where: { $0.session.id == id })
                else { return }
                self.open(entry)
            }
        }
    }

    /// Switching chats resets per-conversation state, with deliberate exceptions and orderings.
    /// Decoded textures survive the switch — a picture decoded once is a picture that never pops
    /// in again — while subagent transcripts do not, because they can still be running. A session
    /// created a heartbeat ago is empty by definition: its ready state paints now and the
    /// composer takes focus, while the stream settles in behind it. The profile store is loaded
    /// on demand rather than assumed, because a chat opened straight from the cache can arrive
    /// before the profile list has been read off disk. And rows are built only for the tail the
    /// window can show, only off the GLib main context, and only for messages that changed — the
    /// builder remembers the rest — with the paint going out before the context estimate is
    /// computed: the transcript appearing must never wait on a statistic about it.
    private func open(_ entry: SessionEntry, freshlyCreated: Bool = false) {
        guard selectedID != entry.session.id else { return }
        Trace.mark("open begin \(entry.session.id.prefix(8))")
        self.freshlyCreated = freshlyCreated ? entry : nil
        stashDraft()
        selectedID = entry.session.id
        currentEntry = entry
        conversation = nil
        currentBackend = nil
        lastState = nil
        models = []
        commands = []
        chosenModel = nil
        chosenEffort = nil
        turnStartedAt = nil
        context.expanded = []
        context.subagentRows = [:]
        inFlightImages = []
        inFlightSubagents = []
        attachments = []
        pastedImageCount = 0
        echoedPrompt = nil
        renderAttachments()
        clearUnseen()
        windowLimit = 400
        rowTailMessages = 300
        lastFullRows = []
        lastFullCount = 0
        followsBottom = true
        gtk_widget_set_visible(earlierButton, 0)
        if gtk_widget_get_visible(findBar) != 0 { setFindShown(false) }
        restoreDraft(for: entry.session.id)
        streamTask?.cancel()
        if let remembered = sessionRows[entry.session.id] {
            placeholderShown = true
            lastFullRows = remembered
            lastFullCount = remembered.count
            let limit = max(windowLimit, Preferences.transcriptWindow)
            let windowed =
                remembered.count > limit ? Array(remembered.suffix(limit)) : remembered
            applyRows(windowed)
        } else if freshlyCreated {
            showPlaceholder(Localized.text("Nothing here yet. Say something."))
            gtk_widget_grab_focus(entryView)
        } else {
            showPlaceholder(Localized.text("Connecting…"))
        }
        pendingSignature = "\u{0}"
        Gtk.removeChildren(of: pendingBox)
        gtk_widget_set_visible(authBanner, 0)
        gtk_label_set_text(
            op(titleLabel),
            entry.session.hasPlaceholderTitle
                ? Localized.text("New conversation") : entry.session.title)
        refreshPills()
        SessionSeenStore.markSeen(entry.session.id)
        terminal.setDirectory(entry.session.directory)
        agents = []
        usage = nil
        notice = nil
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
        Trace.mark("open pane ready")
        Gtk.onMain { [weak self] in self?.renderSidebar() }

        streamTask = Task { [weak self] in
            guard let self else { return }
            if await ServerDirectory.shared.profiles().isEmpty {
                await ServerDirectory.shared.reload()
            }
            guard
                let profile = await ServerDirectory.shared.profiles().first(where: {
                    $0.id == entry.profileID
                }), let backend = await ServerDirectory.shared.backend(for: profile)
            else {
                Gtk.onMain { [weak self] in
                    self?.showPlaceholder(Localized.text("That server is not configured."))
                }
                return
            }
            Gtk.onMain { [weak self] in
                self?.currentBackend = backend
                self?.fileTree.show(directory: entry.session.directory, on: backend)
            }
            self.loadSessionExtras(backend: backend, directory: entry.session.directory)
            let conversation = AgentConversation(
                backend: backend, sessionID: entry.session.id, cache: AppCache.sessionCache)
            self.conversation = conversation
            var countedMessages = -1
            let tracing = ProcessInfo.processInfo.environment["TAILSCODE_DRIVE"] != nil
            for await state in await conversation.states() {
                if Task.isCancelled { return }
                let tail = self.rowTailMessages
                let messages = state.messages.count > tail
                    ? Array(state.messages.suffix(tail)) : state.messages
                let started = Date()
                let rows = self.rowBuilder.rows(for: messages)
                if tracing {
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    FileHandle.standardOutput.write(
                        Data("BUILD \(messages.count) messages -> \(rows.count) rows in \(ms)ms\n".utf8))
                }
                Gtk.onMain { [weak self] in
                    self?.apply(state: state, rows: rows)
                }
                if state.messages.count != countedMessages {
                    countedMessages = state.messages.count
                    let estimate = StatusFacts.estimateContextTokens(state.messages)
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.contextEstimate = estimate
                        self.updateStatus()
                    }
                }
            }
        }
    }

    /// Everything worth knowing about the session besides its transcript, fetched once per open:
    /// the models the server offers, the commands it resolves, and whether its Claude is signed in.
    private func loadSessionExtras(backend: any CodingAgentBackend, directory: String?) {
        Task { [weak self] in
            let models = (try? await backend.availableModels()) ?? []
            let commands = (try? await backend.availableCommands(directory: directory)) ?? []
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.models = models
                self.commands = commands
                self.refreshPills()
                self.refreshTurnFacts()
            }
        }
        if let authenticating = backend as? any AuthenticatingBackend {
            Task { [weak self] in
                guard let auth = try? await authenticating.authStatus() else { return }
                Gtk.onMain { [weak self] in
                    self?.renderAuthBanner(auth, backend: authenticating)
                }
            }
        }
    }

    private func renderAuthBanner(_ auth: ServerAuth, backend: any AuthenticatingBackend) {
        Gtk.removeChildren(of: authBanner)
        guard !auth.loggedIn else {
            gtk_widget_set_visible(authBanner, 0)
            return
        }
        let name = currentEntry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) } ?? "server"
        let label = Gtk.label(
            Localized.text("⚠ Claude is signed out on %@ — every turn will refuse until it signs in.", name),
            css: "banner-auth", wrap: true, selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(authBanner), label)
        let rootBits = window.map { UInt(bitPattern: $0) } ?? 0
        gtk_box_append(
            ptr(authBanner),
            Gtk.button(Localized.text("Sign in")) { [weak self] in
                let parent = UnsafeMutableRawPointer(bitPattern: rootBits).map {
                    raw -> UnsafeMutablePointer<GtkWidget> in ptr(raw)
                }
                SignInDialog.present(
                    parent: parent, serverName: name, backend: backend
                ) { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        gtk_widget_set_visible(self.authBanner, 0)
                    }
                }
            })
        gtk_widget_set_visible(authBanner, 1)
    }

    /// The transcript renders a tail window, not the whole history: a widget per row is fine for
    /// four hundred rows and a multi-second lockup for four thousand. The rest waits behind one
    /// button that widens the window — the full rows are kept, so nothing is refetched. The
    /// locally echoed prompt stands only until the transcript carries the same words back.
    private func apply(state: ConversationState, rows: [TranscriptRow]) {
        Trace.mark(
            "apply state loaded=\(state.hasLoadedTranscript) rows=\(rows.count) status=\(state.status)")
        lastState = state
        if let currentEntry {
            Notifier.shared.observeConversation(
                profileID: currentEntry.profileID, sessionID: currentEntry.session.id,
                title: currentEntry.session.hasPlaceholderTitle
                    ? Localized.text("New conversation") : currentEntry.session.title,
                state: state, windowActive: windowIsActive)
        }
        var rows = rows
        if let echoedPrompt {
            if state.messages.contains(where: {
                $0.role == .user && $0.text.contains(echoedPrompt.prefix(80))
            }) {
                self.echoedPrompt = nil
            } else {
                if !rows.isEmpty {
                    rows.append(TranscriptRow(key: "echo:break", kind: .turnBreak))
                }
                rows.append(TranscriptRow(key: "echo:prompt", kind: .userText(echoedPrompt)))
            }
        }
        lastFullRows = rows
        if let selectedID { rememberRows(rows, for: selectedID) }
        let appended = max(0, rows.count - lastFullCount)
        lastFullCount = rows.count
        let limit = max(windowLimit, Preferences.transcriptWindow)
        let windowed = rows.count > limit ? Array(rows.suffix(limit)) : rows
        let hiddenCount = rows.count - windowed.count
        gtk_widget_set_visible(earlierButton, hiddenCount > 0 ? 1 : 0)
        if hiddenCount > 0 {
            gtk_button_set_label(
                ptr(earlierButton),
                Localized.text("… %@ earlier rows — show more", "\(hiddenCount)"))
        }
        let placeholder: String? =
            rows.isEmpty
            ? (state.hasLoadedTranscript || selectedID == freshlyCreated?.session.id
                ? Localized.text("Nothing here yet. Say something.") : Localized.text("Loading…"))
            : nil
        if let placeholder {
            showPlaceholder(placeholder)
        } else {
            applyRows(windowed, appended: appended)
        }
        renderPendingCards(state)
        refreshPills()
        updateStatus()
        updateTicker(running: state.status == .running || state.compaction?.isRunning == true)
    }

    private func showPlaceholder(_ text: String) {
        if placeholderShown, currentPlaceholder == text { return }
        currentPlaceholder = text
        Gtk.removeChildren(of: transcriptBox)
        renderedRows = []
        rowWidgets = []
        highlightedRow = 0
        placeholderShown = true
        pendingReveal = false
        gtk_widget_set_opacity(transcriptBox, 1)
        let label = Gtk.label(text, css: "dim", selectable: false)
        Gtk.margins(label, top: 24, bottom: 24, leading: 4, trailing: 4)
        gtk_box_append(ptr(transcriptBox), label)
    }

    /// The rendering path, shaped around what a person is looking at. On first paint the tail —
    /// the rows the window actually shows — goes up immediately, built invisible so the first
    /// frame anyone sees is the settled bottom of the conversation, never the top of it sliding
    /// down into place; everything earlier backfills above it newest-first, one chunk per idle,
    /// so a huge conversation is readable in one frame instead of after a ten-chunk climb — and
    /// the backfill also runs on a remembered transcript before the server has said a word. While
    /// streaming, everything before the first changed row keeps its widget — and its disclosure
    /// state, its selection, its scroll cost — and a token appended to the last message rebuilds
    /// one row, not the conversation. Whether to follow is what the person last chose, not where
    /// the scrollbar happens to be: an unfocused window does not lay out, so its position is
    /// stale exactly when new rows arrive.
    ///
    /// `renderedRows` is always a contiguous slice of the applied row list that reaches its end;
    /// where that slice starts is re-found by key on every pass, because the window slides. Rows
    /// that fall off the window's front while the screen still shows them are trimmed from the
    /// top — their widgets removed, everything else kept — rather than treated as a reason to
    /// rebuild; only a window that shares nothing with the screen starts over.
    private func applyRows(_ rows: [TranscriptRow], appended: Int = 0) {
        let initialFill = placeholderShown
        if placeholderShown {
            Gtk.removeChildren(of: transcriptBox)
            renderedRows = []
            rowWidgets = []
            highlightedRow = 0
            placeholderShown = false
            currentPlaceholder = nil
            gtk_widget_set_opacity(transcriptBox, 0)
            pendingReveal = true
        }
        let stick = initialFill || followsBottom
        let growth = initialFill ? 0 : appended
        let chunk = 40

        var start = 0
        if !renderedRows.isEmpty {
            var indexByKey = [String: Int](minimumCapacity: rows.count)
            for (index, row) in rows.enumerated() where indexByKey[row.key] == nil {
                indexByKey[row.key] = index
            }
            var anchor: (rendered: Int, row: Int)?
            for (rendered, row) in renderedRows.enumerated() {
                if let index = indexByKey[row.key] {
                    anchor = (rendered, index)
                    break
                }
            }
            if let anchor {
                for bits in rowWidgets[..<anchor.rendered] {
                    guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
                    if bits == highlightedRow { highlightedRow = 0 }
                    gtk_box_remove(ptr(transcriptBox), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
                }
                rowWidgets.removeSubrange(..<anchor.rendered)
                renderedRows.removeSubrange(..<anchor.rendered)
                start = anchor.row
            } else {
                tearDownAllRows()
            }
        }

        if renderedRows.isEmpty {
            start = max(0, rows.count - chunk)
            appendRowWidgets(rows[start...])
        } else {
            var same = 0
            while same < renderedRows.count, start + same < rows.count,
                renderedRows[same] == rows[start + same]
            {
                same += 1
            }
            for bits in rowWidgets[same...] {
                guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
                if bits == highlightedRow { highlightedRow = 0 }
                gtk_box_remove(ptr(transcriptBox), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
            }
            rowWidgets.removeSubrange(same...)
            renderedRows.removeSubrange(same...)
            let tailFrom = start + renderedRows.count
            let tailEnd = min(rows.count, tailFrom + chunk)
            appendRowWidgets(rows[tailFrom..<tailEnd])
        }

        let tailDone = start + renderedRows.count >= rows.count
        if tailDone, start > 0 {
            let from = max(0, start - chunk)
            var previous: UnsafeMutablePointer<GtkWidget>?
            var bits: [UInt] = []
            for row in rows[from..<start] {
                let widget = row.makeWidget(context: context)
                gtk_box_insert_child_after(ptr(transcriptBox), widget, previous)
                previous = widget
                bits.append(UInt(bitPattern: widget))
            }
            renderedRows.insert(contentsOf: rows[from..<start], at: 0)
            rowWidgets.insert(contentsOf: bits, at: 0)
            start = from
        }

        let complete = tailDone && start == 0
        fillComplete = complete
        if !complete {
            if stick { followsBottom = true }
            if !isFillingInChunks {
                isFillingInChunks = true
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.isFillingInChunks = false
                    if let state = self.lastState {
                        self.apply(state: state, rows: self.lastFullRows)
                    } else {
                        let limit = max(self.windowLimit, Preferences.transcriptWindow)
                        let rows = self.lastFullRows
                        self.applyRows(rows.count > limit ? Array(rows.suffix(limit)) : rows)
                    }
                }
            }
        }

        if stick {
            scrollToBottom()
        } else {
            noteAppendedWhileScrolledUp(growth)
        }
        if complete, gtk_widget_get_visible(findBar) != 0 { runFind(retarget: false) }
    }

    private func appendRowWidgets(_ rows: ArraySlice<TranscriptRow>) {
        for row in rows {
            let widget = row.makeWidget(context: context)
            gtk_box_append(ptr(transcriptBox), widget)
            rowWidgets.append(UInt(bitPattern: widget))
            renderedRows.append(row)
        }
    }

    /// At most a handful of transcripts are kept renderable; the oldest falls out so a long day
    /// of chats does not become a memory of every one of them.
    private func rememberRows(_ rows: [TranscriptRow], for sessionID: String) {
        if sessionRows[sessionID] == nil {
            sessionRowOrder.append(sessionID)
            if sessionRowOrder.count > 6 {
                let evicted = sessionRowOrder.removeFirst()
                sessionRows[evicted] = nil
            }
        }
        sessionRows[sessionID] = rows
    }

    private func tearDownAllRows() {
        for bits in rowWidgets {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            gtk_box_remove(ptr(transcriptBox), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
        }
        renderedRows = []
        rowWidgets = []
        highlightedRow = 0
    }

    /// A cache arrival (a decoded picture, a fetched subagent transcript) redraws exactly the rows
    /// it belongs to, in place: the widget is swapped where it stands, every other row keeps its
    /// state, and nothing scrolls. It is not new content — the unseen counter never moves.
    private func replaceRows(where predicate: (TranscriptRow) -> Bool) {
        guard !placeholderShown else { return }
        for index in renderedRows.indices where predicate(renderedRows[index]) {
            guard index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            if rowWidgets[index] == highlightedRow { clearFindHighlight() }
            let old: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let previous: UnsafeMutablePointer<GtkWidget>? =
                index > 0
                ? UnsafeMutableRawPointer(bitPattern: rowWidgets[index - 1]).map { ptr($0) } : nil
            gtk_box_remove(ptr(transcriptBox), old)
            let widget = renderedRows[index].makeWidget(context: context)
            gtk_box_insert_child_after(ptr(transcriptBox), widget, previous)
            rowWidgets[index] = UInt(bitPattern: widget)
        }
    }

    /// What the turn is waiting on, docked where the CLI's prompt would sit: approvals first,
    /// then questions. Rebuilt only when what is pending actually changes — this runs on every
    /// streamed token, and cards that flicker under a click swallow the click.
    private func renderPendingCards(_ state: ConversationState) {
        let signature = (state.pendingPermissions.map(\.id) + state.pendingQuestions.map(\.id))
            .joined(separator: "|") + "|" + (state.compaction?.failure ?? "")
        guard signature != pendingSignature else { return }
        pendingSignature = signature
        Gtk.removeChildren(of: pendingBox)
        for permission in state.pendingPermissions {
            gtk_box_append(
                ptr(pendingBox),
                PendingCards.permission(permission) { [weak self] decision in
                    self?.respond(to: permission, decision: decision)
                })
        }
        for question in state.pendingQuestions {
            gtk_box_append(
                ptr(pendingBox),
                PendingCards.question(question) { [weak self] answers in
                    self?.answer(question, answers: answers)
                })
        }
        if let compaction = state.compaction, let failure = compaction.failure {
            let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
            Gtk.addClass(card, "card")
            gtk_box_append(
                ptr(card),
                Gtk.label(
                    Localized.text("Compaction failed: %@", failure), css: "glyph-error",
                    wrap: true))
            gtk_box_append(ptr(pendingBox), card)
        }
    }

    private func respond(to permission: PermissionRequest, decision: PermissionDecision) {
        guard let conversation else { return }
        Task { try? await conversation.respond(to: permission, decision: decision) }
    }

    /// Claude answers by message, so the answer goes out through the ordinary send path — a
    /// bridge busy with a live turn refuses a side-channel call but queues a message. The card
    /// stops asking immediately either way.
    private func answer(_ question: QuestionRequest, answers: [[String]]) {
        guard let conversation else { return }
        let byMessage = currentBackend?.capabilities.answersQuestionsByMessage == true
        Task {
            if byMessage {
                await conversation.markAnswered(question)
                try? await conversation.send(question.answerMessage(answers))
            } else {
                try? await conversation.answer(question, answers: answers)
            }
        }
    }

    /// The band above the prompt box: what the turn is doing, which agents are out, how much of
    /// the context is spent, what the goal is — every fact clickable, so reading the status and
    /// steering the turn are one gesture rather than two.
    private func updateStatus() {
        guard let state = lastState else { return }
        let running = state.status == .running || state.compaction?.isRunning == true
        if running {
            if turnStartedAt == nil { turnStartedAt = Date() }
        } else {
            turnStartedAt = nil
        }
        let facts = StatusFacts.from(
            state: state, turnStartedAt: turnStartedAt, agents: agents, usage: usage,
            attachments: attachments.count, contextTokens: contextEstimate)
        StatusBand.render(into: statusBand, state: bandState, facts: facts, notice: notice) {
            [weak self] action in
            Gtk.onMain { [weak self] in self?.perform(bandAction: action) }
        }
        gtk_button_set_label(
            ptr(sendButton), running ? Localized.text("Queue") : Localized.text("Send"))
        gtk_widget_set_visible(stopButton, running ? 1 : 0)
    }

    private func perform(bandAction action: StatusFacts.Action) {
        switch action {
        case .stop: stopTurn()
        case .compact: presentCompactPreflight()
        case .goal: insertIntoComposer("/goal ")
        case .scrollToPending: scroll(toEnd: true)
        case .scrollToAgents: scrollToNewestAgent()
        case .agent(let id): scrollToAgent(id)
        case .reconnect:
            guard let conversation else { return }
            Task { await conversation.reconnect() }
        }
    }

    /// The card for one named agent — matched to the tool call that spawned it, which is the id
    /// the summary carries — and its transcript opened on arrival.
    private func scrollToAgent(_ id: String) {
        for (index, row) in renderedRows.enumerated() {
            guard case .subagent(let call) = row.kind, call.id == id else { continue }
            context.expanded.insert(row.key)
            replaceRows { $0.key == row.key }
            fetchSubagent(call)
            scrollToRow(at: index)
            return
        }
        scrollToNewestAgent()
    }

    private func scrollToRow(at index: Int) {
        guard index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
        else { return }
        let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        let offset = tailscode_widget_offset_y(widget, canvasBox ?? transcriptBox)
        guard offset >= 0, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        followsBottom = false
        let page = gtk_adjustment_get_page_size(adjustment)
        gtk_adjustment_set_value(
            adjustment,
            min(max(0, offset - page * 0.3), max(0, gtk_adjustment_get_upper(adjustment) - page)))
    }

    private func scrollToNewestAgent() {
        for (index, row) in renderedRows.enumerated().reversed() {
            guard case .subagent = row.kind, index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let offset = tailscode_widget_offset_y(widget, canvasBox ?? transcriptBox)
            guard offset >= 0, let scroller = transcriptScroller,
                let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
            else { return }
            let page = gtk_adjustment_get_page_size(adjustment)
            gtk_adjustment_set_value(
                adjustment,
                min(max(0, offset - page * 0.3), max(0, gtk_adjustment_get_upper(adjustment) - page)))
            return
        }
        scroll(toEnd: true)
    }

    /// A notice is transient — the last thing the app did on your behalf — and it lives at the far
    /// end of the band so it never pushes a live fact off it.
    private func setNotice(_ text: String) {
        notice = text
        updateStatus()
    }

    /// A proto-2 bridge pushes each fan-out's live facts as they change; older servers are
    /// polled. Started lazily on the first turn tick after a chat opens.
    private func startAgentStreamIfAvailable() {
        guard agentStreamSessionID != currentEntry?.session.id else { return }
        guard let backend = currentBackend, let entry = currentEntry else { return }
        agentStreamSessionID = entry.session.id
        let sessionID = entry.session.id
        agentStreamTask?.cancel()
        agentStreamTask = Task { [weak self] in
            guard let streaming = backend as? SubagentStreaming,
                let changes = await streaming.subagentChanges(for: sessionID)
            else {
                Gtk.onMain { [weak self] in self?.agentStreamSessionID = nil }
                return
            }
            for await agents in changes {
                Gtk.onMain { [weak self] in
                    guard let self, self.currentEntry?.session.id == sessionID else { return }
                    self.applyAgentFacts(agents)
                }
            }
        }
    }

    private func applyAgentFacts(_ agents: [SubagentSummary]) {
        self.agents = agents
        var facts: [String: SubagentSummary] = [:]
        for agent in agents {
            if let toolUseID = agent.toolUseID { facts[toolUseID] = agent }
        }
        let changed = facts.keys.filter { context.agentFacts[$0] != facts[$0] }
        let vanished = context.agentFacts.keys.filter { facts[$0] == nil }
        context.agentFacts = facts
        let stale = Set(changed + vanished)
        if !stale.isEmpty {
            replaceRows {
                if case .subagent(let call) = $0.kind { return stale.contains(call.id) }
                return false
            }
        }
        updateStatus()
    }

    /// Subagents and cost are polled rather than streamed: the bridge reports both on request
    /// only, and a fan-out is worth watching while it runs.
    private func refreshTurnFacts() {
        guard let backend = currentBackend, let entry = currentEntry else { return }
        startAgentStreamIfAvailable()
        let sessionID = entry.session.id
        let skipAgents = agentStreamSessionID == sessionID && agentStreamTask != nil
        Task { [weak self] in
            let agents = skipAgents ? nil : ((try? await backend.subagents(for: sessionID)) ?? [])
            let usage = (try? await backend.sessionUsage(sessionID)) ?? nil
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.usage = usage
                if let agents {
                    self.applyAgentFacts(agents)
                } else {
                    self.updateStatus()
                }
            }
        }
    }

    /// A once-a-second nudge while a turn runs, so elapsed time moves without any state event.
    /// When the turn ends, one last look settles the agents list on "done" instead of freezing
    /// mid-flight glyphs.
    private func updateTicker(running: Bool) {
        if running, tickerTask == nil {
            tickerTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    tick += 1
                    let facts = tick % 5 == 0
                    Gtk.onMain { [weak self] in
                        self?.updateStatus()
                        if facts { self?.refreshTurnFacts() }
                    }
                }
            }
        } else if !running {
            if tickerTask != nil {
                tickerTask?.cancel()
                tickerTask = nil
                refreshTurnFacts()
            }
        }
    }

    private func refreshPills() {
        let entry = currentEntry
        let destination = [
            entry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) },
            entry?.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
        ].compactMap { $0 }.joined(separator: " · ")
        gtk_label_set_text(op(destinationLabel), destination)

        if let modelButton {
            gtk_menu_button_set_label(op(modelButton), modelPillText())
        }
        if let effortButton {
            gtk_menu_button_set_label(op(effortButton), effortPillText())
        }
    }

    /// What the chat is actually being answered by, which is not always what the session record
    /// says: a `/model` typed into the CLI changes the model for every later turn without the
    /// server's stored session ever hearing about it. The transcript is the authority — the last
    /// assistant message names the model that wrote it — and the session record is the fallback
    /// for a chat that has no answer in it yet.
    private func modelPillText() -> String {
        if let chosenModel { return ModelBadge.label(model: chosenModel, effort: nil) }
        if let observed = observedModelID() {
            return ModelBadge.label(model: ModelSelection(providerID: "server", modelID: observed), effort: nil)
        }
        if let stored = currentEntry?.session.model {
            return ModelBadge.label(model: ModelSelection(providerID: "server", modelID: stored), effort: nil)
        }
        return Localized.text("model")
    }

    private func observedModelID() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let id = message.modelID, !id.isEmpty { return id }
        }
        return nil
    }

    private func effortPillText() -> String {
        if let chosenEffort { return chosenEffort }
        if let stored = currentEntry?.session.reasoningEffort, !stored.isEmpty { return stored }
        if let observed = observedEffort() { return observed }
        guard !effortOptions().isEmpty else { return Localized.text("no effort control") }
        return Localized.text("server effort")
    }

    private func observedEffort() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let effort = message.reasoningEffort, !effort.isEmpty { return effort }
        }
        return nil
    }

    /// Effort is a property of the model on servers whose catalog says so (opencode's variants
    /// differ per model); the backend-wide list is the fallback for agents like Claude Code
    /// where every model takes the same levels.
    private func effortOptions() -> [String] {
        let active = chosenModel?.modelID ?? observedModelID() ?? currentEntry?.session.model
        if let active, let variants = models.first(where: { $0.id == active })?.variants,
            !variants.isEmpty
        {
            return variants
        }
        return currentBackend?.reasoningEffortOptions ?? []
    }

    private func modelRows() -> [(String, String?, @Sendable () -> Void)] {
        guard !models.isEmpty else {
            return [(Localized.text("This server lists no models"), nil, {})]
        }
        var rows: [(String, String?, @Sendable () -> Void)] = [
            (Localized.text("Server default"), nil, { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.chosenModel = nil
                    self?.refreshPills()
                }
            })
        ]
        for model in models {
            let selection = model.selection
            rows.append(
                (model.name, model.providerID, { [weak self] in
                    Gtk.onMain { [weak self] in
                        self?.chosenModel = selection
                        self?.refreshPills()
                    }
                }))
        }
        return rows
    }

    private func effortRows() -> [(String, String?, @Sendable () -> Void)] {
        let options = effortOptions()
        guard !options.isEmpty else {
            return [(Localized.text("This agent has no effort control"), nil, {})]
        }
        var rows: [(String, String?, @Sendable () -> Void)] = [
            (Localized.text("Server default"), nil, { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.chosenEffort = nil
                    self?.refreshPills()
                }
            })
        ]
        for option in options {
            rows.append(
                (option, nil, { [weak self] in
                    Gtk.onMain { [weak self] in
                        self?.chosenEffort = option
                        self?.refreshPills()
                    }
                }))
        }
        return rows
    }

    /// On the server first — what this machine will actually resolve — then what the app itself
    /// can do. Picking one drops it into the composer so arguments can follow; `/compact` keeps
    /// its preflight.
    private func commandRows() -> [(String, String?, @Sendable () -> Void)] {
        var rows: [(String, String?, @Sendable () -> Void)] = []
        rows.append(
            ("/compact", Localized.text("Trade the transcript for a summary — with a preflight"),
             { [weak self] in Gtk.onMain { [weak self] in self?.presentCompactPreflight() } }))
        rows.append(
            ("/goal", Localized.text("Set a standing goal the agent pursues"),
             { [weak self] in Gtk.onMain { [weak self] in self?.insertIntoComposer("/goal ") } }))
        for command in commands where command.name != "compact" && command.name != "goal" {
            let insertion = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
            rows.append(
                ("/\(command.name)", command.details.isEmpty ? command.source.rawValue : command.details,
                 { [weak self] in Gtk.onMain { [weak self] in self?.insertIntoComposer(insertion) } }))
        }
        return rows
    }

    private func actionRows() -> [(String, String?, @Sendable () -> Void)] {
        guard let entry = currentEntry else { return [] }
        let capabilities = currentBackend?.capabilities
        var rows: [(String, String?, @Sendable () -> Void)] = []

        let saved = SavedChatStore.contains(entry)
        rows.append(
            (saved ? Localized.text("Unsave") : Localized.text("Save"),
             Localized.text("A saved chat lists itself even when its server is unreachable"),
             { [weak self] in Gtk.onMain { [weak self] in self?.toggleSaved() } }))

        if capabilities?.supportsRenaming == true {
            rows.append(
                (Localized.text("Rename…"), nil,
                 { [weak self] in Gtk.onMain { [weak self] in self?.presentRename() } }))
        }
        if capabilities?.supportsForking == true {
            rows.append(
                (Localized.text("Fork"),
                 Localized.text("A new session with this history, for a different direction"),
                 { [weak self] in Gtk.onMain { [weak self] in self?.forkCurrent() } }))
        }
        if capabilities?.supportsCompaction == true {
            rows.append(
                (Localized.text("Compact…"),
                 Localized.text("Irreversible, takes minutes"),
                 { [weak self] in Gtk.onMain { [weak self] in self?.presentCompactPreflight() } }))
        }
        if capabilities?.supportsClearing == true {
            rows.append(
                (Localized.text("Clear…"), Localized.text("Empty the conversation in place"),
                 { [weak self] in Gtk.onMain { [weak self] in self?.presentClear() } }))
        }
        rows.append(
            (Localized.text("Delete…"), Localized.text("Remove the session from its server"),
             { [weak self] in Gtk.onMain { [weak self] in self?.presentDelete() } }))
        return rows
    }

    private func presentNewChat() {
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            let localAddresses = Self.localAddresses
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard !profiles.isEmpty else {
                    self.presentServers()
                    return
                }
                var seen = Set<String>()
                let recents = self.entries.compactMap(\.session.directory).filter {
                    seen.insert($0).inserted
                }
                Dialogs.newChat(
                    parent: self.window, profiles: profiles, recentDirectories: recents,
                    localAddresses: localAddresses
                ) { [weak self] profile, directory in
                    self?.createChat(on: profile, directory: directory)
                }
            }
        }
    }

    /// Read once, off the main context: `tailscale status` is a subprocess, and the answer —
    /// which addresses mean "this machine" — does not change within a run.
    private static let localAddresses: Set<String> = {
        var hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        var name = [CChar](repeating: 0, count: 256)
        if gethostname(&name, 255) == 0 { hosts.insert(String(cString: name).lowercased()) }
        if let address = TailnetStatusLinux.read().address { hosts.insert(address) }
        return hosts
    }()

    /// The one round trip that mints the session id is all the new chat waits for. The sidebar
    /// row is seeded from the answer and the conversation opens on the spot; the full list
    /// refresh reconciles behind it, because a person who just started a chat is looking at the
    /// composer, not at the list.
    private func createChat(on profile: ConnectionProfile, directory: String?) {
        Trace.mark("createChat begin")
        Task { [weak self] in
            guard let backend = await ServerDirectory.shared.backend(for: profile) else { return }
            do {
                let session = try await backend.createSession(title: nil, directory: directory)
                Trace.mark("createChat session created")
                let entry = SessionEntry(
                    profileID: profile.id, profileName: profile.name,
                    host: profile.baseURL.host ?? profile.name,
                    backendType: profile.backend, session: session)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    if !self.entries.contains(where: { $0.session.id == entry.session.id }) {
                        self.entries.insert(entry, at: 0)
                    }
                    self.lastSidebar = nil
                    self.renderSidebar()
                    self.open(entry, freshlyCreated: true)
                }
                await self?.refresh()
                Trace.mark("createChat refresh done")
            } catch {
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.setNotice(
                            Localized.text("Could not start a session: %@", "\(error)"))
                }
            }
        }
    }

    private func presentServers() {
        let manager = ServerManager { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
        manager.present(parent: window)
    }

    private func presentRename() {
        guard let entry = currentEntry, let backend = currentBackend else { return }
        presentRename(entry: entry, backend: backend)
    }

    private func presentRename(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        Dialogs.prompt(
            title: Localized.text("Rename this conversation"), body: nil,
            placeholder: Localized.text("Title"),
            initial: entry.session.hasPlaceholderTitle ? "" : entry.session.title,
            confirmLabel: Localized.text("Rename"), parent: window
        ) { [weak self] title in
            guard !title.isEmpty else { return }
            Task { [weak self] in
                try? await backend.renameSession(sessionID, title: title)
                await self?.refresh()
                Gtk.onMain { [weak self] in
                    guard let self, self.selectedID == sessionID else { return }
                    gtk_label_set_text(op(self.titleLabel), title)
                }
            }
        }
    }

    private func forkCurrent() {
        guard let entry = currentEntry, let backend = currentBackend else { return }
        fork(entry: entry, backend: backend)
    }

    private func fork(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        Task { [weak self] in
            guard let session = try? await backend.forkSession(sessionID) else { return }
            let forked = SessionEntry(
                profileID: entry.profileID, profileName: entry.profileName, host: entry.host,
                backendType: entry.backendType, session: session)
            await self?.refresh()
            Gtk.onMain { [weak self] in self?.open(forked) }
        }
    }

    private func presentCompactPreflight(initialInstruction: String = "") {
        guard let conversation else { return }
        Dialogs.compactPreflight(
            parent: window, initialInstruction: initialInstruction
        ) { instruction in
            Task { try? await conversation.compact(instructions: instruction) }
        }
    }

    private func presentClear() {
        guard let entry = currentEntry, let backend = currentBackend else { return }
        let sessionID = entry.session.id
        Dialogs.confirm(
            title: Localized.text("Clear this conversation?"),
            body: Localized.text("Everything in it goes away, on the server, for every device."),
            confirmLabel: Localized.text("Clear"), parent: window
        ) { [weak self] in
            Task { [weak self] in
                try? await backend.clearConversation(sessionID)
                await self?.refresh()
            }
        }
    }

    private func presentDelete() {
        guard let entry = currentEntry, let backend = currentBackend else { return }
        presentDelete(entry: entry, backend: backend)
    }

    /// Optimistic on confirm: the row disappears and the next chat opens before the server has
    /// answered — the person already decided, and the round trip is not theirs to wait for. The
    /// refresh behind the request reconciles either way, so a delete the server refused simply
    /// puts the row back, with a notice saying why.
    private func presentDelete(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        Dialogs.confirm(
            title: Localized.text("Delete this conversation?"),
            body: Localized.text(
                "It is removed from %@ for every device. A saved copy on this machine survives.",
                entry.profileName),
            confirmLabel: Localized.text("Delete"), parent: window
        ) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.pendingDeletes.insert(sessionID)
                self.entries.removeAll {
                    $0.profileID == entry.profileID && $0.session.id == sessionID
                }
                if self.freshlyCreated?.session.id == sessionID { self.freshlyCreated = nil }
                if self.selectedID == sessionID {
                    self.selectedID = nil
                    self.currentEntry = nil
                    if let next = self.entries.first { self.open(next) }
                }
                self.renderSidebar()
            }
            Task { [weak self] in
                let failure: String?
                do {
                    try await backend.deleteSession(sessionID)
                    failure = nil
                } catch {
                    failure = "\(error)"
                }
                if failure == nil { await self?.refresh() }
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.pendingDeletes.remove(sessionID)
                    if let failure {
                        self.setNotice(Localized.text("Could not delete: %@", failure))
                        self.renderSidebar()
                    }
                }
                if failure != nil { await self?.refresh() }
            }
        }
    }

    private func toggleSaved() {
        guard let entry = currentEntry else { return }
        toggleSaved(entry)
    }

    private func toggleSaved(_ entry: SessionEntry) {
        _ = SavedChatStore.toggle(entry)
        SettingsFile.capture()
        renderSidebar()
    }

    /// The right-click menu on a chat row. The menu anchors to the sidebar's own box — a widget
    /// that outlives any re-render — with the click's position translated at press time, while
    /// the row it happened on is still alive; the backend lookup that gates rename, fork and
    /// delete happens on the way, so an unreachable server's row still offers what works offline.
    private func presentRowMenu(_ row: SessionRowModel, rowBits: UInt, x: Double, y: Double) {
        guard let raw = UnsafeMutableRawPointer(bitPattern: rowBits) else { return }
        let offsetY = tailscode_widget_offset_y(ptr(raw), sidebarList)
        guard offsetY >= 0 else { return }
        let anchorX = x + 4
        let anchorY = offsetY + y
        let entry = row.entry
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            var backend: (any CodingAgentBackend)?
            if let profile = profiles.first(where: { $0.id == entry.profileID }) {
                backend = await ServerDirectory.shared.backend(for: profile)
            }
            let resolved = backend
            Gtk.onMain { [weak self] in
                guard let self else { return }
                Gtk.contextMenu(
                    on: self.sidebarList, x: anchorX, y: anchorY,
                    rows: self.rowMenuRows(row, backend: resolved))
            }
        }
    }

    private func rowMenuRows(
        _ row: SessionRowModel, backend: (any CodingAgentBackend)?
    ) -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        let entry = row.entry
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
        if entry.session.id != selectedID {
            rows.append(
                (Localized.text("Open"), nil,
                 { [weak self] in Gtk.onMain { [weak self] in self?.open(entry) } }))
        }
        let saved = SavedChatStore.contains(entry)
        rows.append(
            (saved ? Localized.text("Unsave") : Localized.text("Save"),
             Localized.text("A saved chat lists itself even when its server is unreachable"),
             { [weak self] in Gtk.onMain { [weak self] in self?.toggleSaved(entry) } }))
        let archived = ArchivedChatStore.contains(
            profileID: entry.profileID, sessionID: entry.session.id)
        rows.append(
            (archived ? Localized.text("Unarchive") : Localized.text("Archive"),
             archived
                 ? Localized.text("Back into the chat list")
                 : Localized.text("Out of the list, kept on the server"),
             { [weak self] in Gtk.onMain { [weak self] in self?.toggleArchived(entry) } }))
        rows.append(
            (row.unread ? Localized.text("Mark as read") : Localized.text("Mark as unread"), nil,
             { [weak self] in
                 Gtk.onMain { [weak self] in
                     if row.unread {
                         SessionSeenStore.markSeen(entry.session.id)
                     } else {
                         SessionSeenStore.markUnread(
                             entry.session.id, updatedAt: entry.session.updatedAt)
                     }
                     self?.renderSidebar()
                 }
             }))
        if let backend {
            if backend.capabilities.supportsRenaming {
                rows.append(
                    (Localized.text("Rename…"), nil,
                     { [weak self] in
                         Gtk.onMain { [weak self] in
                             self?.presentRename(entry: entry, backend: backend)
                         }
                     }))
            }
            if backend.capabilities.supportsForking {
                rows.append(
                    (Localized.text("Fork"),
                     Localized.text("A new session with this history, for a different direction"),
                     { [weak self] in
                         Gtk.onMain { [weak self] in self?.fork(entry: entry, backend: backend) }
                     }))
            }
        }
        rows.append(
            (Localized.text("Copy session ID"), entry.session.id,
             { Gtk.onMain { Gtk.copyToClipboard(entry.session.id) } }))
        if let directory = entry.session.directory {
            rows.append(
                (Localized.text("Copy project path"), directory,
                 { Gtk.onMain { Gtk.copyToClipboard(directory) } }))
        }
        if let backend {
            rows.append(
                (Localized.text("Delete…"), Localized.text("Remove the session from its server"),
                 { [weak self] in
                     Gtk.onMain { [weak self] in
                         self?.presentDelete(entry: entry, backend: backend)
                     }
                 }))
        }
        return rows
    }

    /// Disk first, tailnet second: a picture this machine has ever shown comes back in one frame,
    /// and only a genuinely new one crosses the network — then joins the cache. The decode
    /// happens off the main context — `GdkTexture` is immutable and thread-safe to create, and a
    /// large PNG decoded on the UI loop is a visible freeze.
    private func fetchImage(_ reference: FileReference, key: String) {
        guard !inFlightImages.contains(key) else { return }
        inFlightImages.insert(key)
        let backend = currentBackend
        Task { [weak self] in
            var data = ImageCache.load(reference)
            if data == nil, let backend {
                data = try? await backend.attachmentData(reference)
                if let data { ImageCache.save(data, for: reference) }
            }
            guard let data else { return }
            let bits: UInt = data.withUnsafeBytes { buffer in
                guard
                    let texture = tailscode_texture_from_bytes(
                        buffer.baseAddress, gsize(buffer.count))
                else { return UInt(0) }
                return UInt(bitPattern: texture)
            }
            guard bits != 0 else { return }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.context.store(textureBits: bits, data: data, forKey: key)
                self.replaceRows { $0.key == key }
            }
        }
    }

    private func fetchSubagent(_ call: ToolCall) {
        guard let backend = currentBackend, let entry = currentEntry,
            !inFlightSubagents.contains(call.id)
        else { return }
        inFlightSubagents.insert(call.id)
        let sessionID = entry.session.id
        Task { [weak self] in
            let agents = (try? await backend.subagents(for: sessionID)) ?? []
            let match = agents.first { $0.toolUseID == call.id }
            let messages: [ChatMessage]
            if let match {
                messages = (try? await backend.subagentMessages(
                    sessionID: sessionID, agentID: match.id)) ?? []
            } else {
                messages = []
            }
            let rows = TranscriptRow.rows(for: messages)
            let callID = call.id
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.context.subagentRows[callID] = rows
                self.replaceRows {
                    if case .subagent(let spawned) = $0.kind { return spawned.id == callID }
                    return false
                }
            }
        }
    }

    /// Normal mode owns the letters; focusing anything that takes text hands them back, and the
    /// terminal keeps everything but Ctrl+Shift and zoom — a shell's own Ctrl+B or Ctrl+E is not
    /// the app's to take. Every binding has a thing you can also click, so the keyboard is a
    /// shortcut rather than the only way in.
    private func installKeymap(on window: UnsafeMutablePointer<GtkWidget>) {
        let root = UInt(bitPattern: window)
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self, let base = UnsafeMutableRawPointer(bitPattern: root) else {
                return false
            }
            let window: UnsafeMutablePointer<GtkWidget> = ptr(base)
            if let handled = self.handleComposerKey(keyval: keyval, state: state) {
                return handled
            }
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                return false
            }
            let context: KeyContext =
                self.terminal.ownsFocus(in: window)
                ? .terminal : Gtk.focusTakesText(window) ? .insert : .normal
            let awaiting =
                context == .normal && !(self.lastState?.pendingPermissions.isEmpty ?? true)
            let resolution = self.shortcuts.resolve(
                chord, context: context, pending: self.pendingChords, awaitingApproval: awaiting)
            switch resolution {
            case .run(let action):
                self.pendingChords = []
                return self.perform(action)
            case .pending(let chords):
                self.pendingChords = chords
                return true
            case .unbound:
                self.pendingChords = []
                return false
            }
        }
        if !shortcuts.issues.isEmpty {
            setNotice(
                Localized.text(
                    "Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    /// Re-reads the rebinding file and rebuilds everything derived from it, live: the resolver,
    /// the cheatsheet, and the notice line if the file has something wrong in it.
    func reloadShortcuts() {
        shortcuts = ShortcutSet.load()
        pendingChords = []
        rebuildHelpOverlay()
        if shortcuts.issues.isEmpty {
            toast(Localized.text("Shortcuts reloaded"))
        } else {
            setNotice(
                Localized.text(
                    "Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    /// The cheatsheet is generated from the registry, so it always tells the truth — overrides
    /// included. Two columns, because forty rows in one column is a scroll, not a glance.
    private func rebuildHelpOverlay() {
        Gtk.removeChildren(of: helpOverlay)
        let sections = shortcuts.helpSections()
        let columns = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 44)
        let left = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let right = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(left, 1)
        gtk_widget_set_hexpand(right, 1)
        gtk_widget_set_valign(left, GTK_ALIGN_START)
        gtk_widget_set_valign(right, GTK_ALIGN_START)
        let total = sections.reduce(0) { $0 + $1.rows.count + 2 }
        var used = 0
        for section in sections {
            let target = used < (total + 1) / 2 ? left : right
            used += section.rows.count + 2
            let header = Gtk.label(section.title, css: "section-header", selectable: false)
            Gtk.margins(header, top: 8, bottom: 2)
            gtk_box_append(ptr(target), header)
            for row in section.rows {
                let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
                let keys = Gtk.label(row.keys, css: "tool-name", selectable: false)
                gtk_widget_set_size_request(keys, 150, -1)
                gtk_box_append(ptr(line), keys)
                gtk_box_append(
                    ptr(line), Gtk.label(row.what, css: "row-detail", selectable: false))
                gtk_box_append(ptr(target), line)
            }
        }
        gtk_box_append(ptr(columns), left)
        gtk_box_append(ptr(columns), right)
        gtk_box_append(ptr(helpOverlay), columns)
        let hint = Gtk.label(
            Localized.text(
                "Rebind any of these: %@ · Settings → Keyboard", ShortcutSet.configURL.path),
            css: "dim", selectable: false)
        Gtk.margins(hint, top: 10)
        gtk_box_append(ptr(helpOverlay), hint)
    }

    /// Ctrl+C over a selection means copy everywhere else on the desktop; only with nothing
    /// selected does the stop binding mean "stop the turn".
    private func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .focus(let pane): focus(pane)
        case .cycleForward: focus(nextPane(after: focused, by: 1))
        case .cycleBackward: focus(nextPane(after: focused, by: -1))
        case .selectNext: move(by: 1)
        case .selectPrevious: move(by: -1)
        case .selectFirst: cursor = 0; openCursor()
        case .selectLast: cursor = max(0, visible.count - 1); openCursor()
        case .openSelected: openCursor()
        case .scrollDown: scroll(by: 60)
        case .scrollUp: scroll(by: -60)
        case .halfPageDown: scroll(byPages: 0.5)
        case .halfPageUp: scroll(byPages: -0.5)
        case .scrollTop: scroll(toEnd: false)
        case .scrollBottom: scroll(toEnd: true)
        case .insert: focus(.transcript); gtk_widget_grab_focus(entryView)
        case .leaveInsert:
            if gtk_widget_get_visible(findBar) != 0 { setFindShown(false) }
            dismissCompletion()
            gtk_widget_grab_focus(sidebarList)
            setHelp(false)
        case .search: gtk_widget_grab_focus(searchEntry)
        case .send: sendFromComposer()
        case .stop:
            if let window, let focused = tailscode_focused_widget(window),
                let selection = tailscode_label_selection(focused)
            {
                Gtk.copyToClipboard(String(cString: selection))
                g_free(selection)
                toast(Localized.text("Copied"))
            } else {
                stopTurn()
            }
        case .toggleHelp: setHelp(!helpShown)
        case .reload: Task { [weak self] in await self?.refresh() }
        case .allowOnce: respondToFirstPermission(.once)
        case .allowAlways: respondToFirstPermission(.always)
        case .deny: respondToFirstPermission(.reject)
        case .newChat: presentNewChat()
        case .toggleSaved: toggleSaved()
        case .findInConversation: setFindShown(true)
        case .zoomIn: UIScale.step(0.1)
        case .zoomOut: UIScale.step(-0.1)
        case .zoomReset: UIScale.reset()
        case .toggleSidebar: togglePane(.sidebar)
        case .toggleFiles: togglePane(.files)
        case .toggleTerminal: togglePane(.terminal)
        case .commandPalette:
            if let commandButton { gtk_menu_button_popup(op(commandButton)) }
        case .archiveSelected:
            if let entry = currentEntry { toggleArchived(entry) }
        case .toggleArchiveView: setArchiveShown(!showingArchive)
        case .toggleUnreadSelected: toggleUnreadSelected()
        case .renameSelected:
            if currentBackend?.capabilities.supportsRenaming == true { presentRename() }
        case .forkSelected:
            if currentBackend?.capabilities.supportsForking == true { forkCurrent() }
        case .deleteSelected: presentDelete()
        case .copySessionID:
            if let entry = currentEntry {
                Gtk.copyToClipboard(entry.session.id)
                toast(Localized.text("Copied"))
            }
        case .copyProjectPath:
            if let directory = currentEntry?.session.directory {
                Gtk.copyToClipboard(directory)
                toast(Localized.text("Copied"))
            }
        }
        return true
    }

    private func toggleUnreadSelected() {
        guard let entry = currentEntry else { return }
        let unread = SessionSeenStore.unreadEvaluator()(entry.session.id, entry.session.updatedAt)
        if unread {
            SessionSeenStore.markSeen(entry.session.id)
        } else {
            SessionSeenStore.markUnread(entry.session.id, updatedAt: entry.session.updatedAt)
        }
        renderSidebar()
    }

    private func respondToFirstPermission(_ decision: PermissionDecision) {
        guard let permission = lastState?.pendingPermissions.first else { return }
        respond(to: permission, decision: decision)
    }

    private func nextPane(after pane: Pane, by delta: Int) -> Pane {
        let all = Pane.allCases
        let index = (all.firstIndex(of: pane) ?? 0) + delta
        return all[(index % all.count + all.count) % all.count]
    }

    private func focus(_ pane: Pane) {
        focused = pane
        if pane != .transcript { dismissCompletion() }
        switch pane {
        case .chats: gtk_widget_grab_focus(sidebarList)
        case .transcript: gtk_widget_grab_focus(transcriptBox)
        case .files: gtk_widget_grab_focus(fileTree.widget)
        case .terminal: terminal.takeFocus()
        }
    }

    private func move(by delta: Int) {
        guard !visible.isEmpty else { return }
        cursor = max(0, min(visible.count - 1, cursor + delta))
        if cursor >= sidebarLimit { sidebarLimit = cursor + 60 }
        openCursor()
    }

    private func openCursor() {
        guard cursor < visible.count else { return }
        open(visible[cursor].entry)
    }

    private func setHelp(_ shown: Bool) {
        helpShown = shown
        gtk_widget_set_visible(helpOverlay, shown ? 1 : 0)
    }

    /// Every pane closes: the chat list collapses into the split view, the file tree and the
    /// terminal give their space back to the conversation. The choice survives relaunch — a
    /// window someone shaped once should open shaped that way.
    private enum ClosablePane: String, CaseIterable {
        case sidebar
        case files
        case terminal

        var key: String { "tailscode.pane.\(rawValue)" }
    }

    private func paneShown(_ pane: ClosablePane) -> Bool {
        UserDefaults.standard.object(forKey: pane.key) as? Bool ?? true
    }

    /// A terminal someone just opened is a terminal they want to type into; focus follows the
    /// reveal, on idle so the widget is on screen by the time focus lands.
    private func togglePane(_ pane: ClosablePane) {
        SettingsFile.set(!paneShown(pane), forKey: pane.key)
        applyPane(pane)
        if pane == .terminal, paneShown(.terminal) {
            Gtk.onMain { [weak self] in self?.focus(.terminal) }
        }
    }

    private func applyPane(_ pane: ClosablePane) {
        let shown = paneShown(pane)
        switch pane {
        case .sidebar:
            guard let sidebarPane else { return }
            gtk_widget_set_visible(sidebarPane, shown ? 1 : 0)
        case .files:
            gtk_widget_set_visible(fileTree.widget, shown ? 1 : 0)
        case .terminal:
            gtk_widget_set_visible(terminal.widget, shown ? 1 : 0)
        }
    }

    private func applyPanePreferences() {
        for pane in ClosablePane.allCases { applyPane(pane) }
        applyLayoutPreferences()
    }

    /// Everything the settings window can change that is not a colour: pane sizes, the prompt
    /// box's height, the terminal's own font, and how much transcript is kept on screen. Compact
    /// and dense change what a row *is*, so the transcript is rebuilt rather than restyled: the
    /// diff that keeps streaming cheap would otherwise keep the old rows.
    private func applyLayoutPreferences() {
        if let splitWidget {
            gtk_paned_set_position(op(splitWidget), Preferences.divider(.sidebar) ?? 300)
        }
        if let projectPaned {
            gtk_paned_set_position(op(projectPaned), Preferences.divider(.project) ?? 800)
        }
        if let terminalPaned {
            gtk_paned_set_position(op(terminalPaned), Preferences.divider(.terminal) ?? 600)
        }
        composerHeight = 0
        growComposer()
        terminal.setFontScale(Preferences.terminalScale)
        terminal.applyPalette(MatrixTheme.palette)
        windowLimit = max(windowLimit, Preferences.transcriptWindow)
        gtk_box_set_spacing(ptr(transcriptBox), Preferences.denseRows ? 3 : 10)
        updateVimBadge()
        tearDownAllRows()
        placeholderShown = true
        rebuildTranscriptRows()
    }

    /// The desktop's dark preference flipped: reload the stylesheet for the other palette and
    /// re-derive the rows, whose prose markup carries the palette's colors baked in. Row folding
    /// runs off the main context; only prose rows differ, so everything else keeps its widget.
    private func retheme() {
        MatrixTheme.install()
        terminal.applyPalette(MatrixTheme.palette)
        rebuildTranscriptRows()
    }

    /// Rows for the current state, folded off the GLib main context — a ten-thousand-message
    /// conversation must never be re-parsed where the frame clock lives.
    private func rebuildTranscriptRows() {
        guard let state = lastState else { return }
        let tail = rowTailMessages
        Task.detached { [weak self] in
            guard let self else { return }
            let messages =
                state.messages.count > tail ? Array(state.messages.suffix(tail)) : state.messages
            let rows = self.rowBuilder.rows(for: messages)
            Gtk.onMain { [weak self] in self?.apply(state: state, rows: rows) }
        }
    }

    /// The dividers are read back rather than watched: `notify::position` carries three arguments
    /// the shim's trampoline cannot marshal, and a size that is saved a few seconds after the drag
    /// is indistinguishable from one saved during it.
    /// A position saved on a wide window would leave nothing for the other pane on a narrow one,
    /// so every divider is pulled back inside the window it is actually in before it is saved.
    private func clampDividers() {
        for paned in [splitWidget, projectPaned].compactMap({ $0 }) {
            let width = gtk_widget_get_width(paned)
            guard width > 400 else { continue }
            let position = gtk_paned_get_position(op(paned))
            let ceiling = width - 200
            if position > ceiling { gtk_paned_set_position(op(paned), ceiling) }
        }
        if let terminalPaned {
            let height = gtk_widget_get_height(terminalPaned)
            guard height > 300 else { return }
            let position = gtk_paned_get_position(op(terminalPaned))
            if position > height - 120 { gtk_paned_set_position(op(terminalPaned), height - 120) }
        }
    }

    /// The window's own shape, read back on the same slow tick as the dividers: `notify::` on
    /// size and maximization carries arguments the shim's trampoline cannot marshal, and a shape
    /// saved a few seconds after a drag is indistinguishable from one saved during it.
    private func rememberWindow() {
        guard let window else { return }
        let maximized = gtk_window_is_maximized(ptr(window)) != 0
        Preferences.setWindowMaximized(maximized)
        guard !maximized else { return }
        Preferences.setWindowSize(
            width: gtk_widget_get_width(window), height: gtk_widget_get_height(window))
    }

    private func rememberDividers() {
        clampDividers()
        rememberWindow()
        Preferences.setLastSession(selectedID)
        if let splitWidget, gtk_widget_get_visible(sidebarPane ?? splitWidget) != 0 {
            Preferences.setDivider(.sidebar, position: gtk_paned_get_position(op(splitWidget)))
        }
        if let projectPaned, gtk_widget_get_visible(fileTree.widget) != 0 {
            Preferences.setDivider(.project, position: gtk_paned_get_position(op(projectPaned)))
        }
        if let terminalPaned, gtk_widget_get_visible(terminal.widget) != 0 {
            Preferences.setDivider(.terminal, position: gtk_paned_get_position(op(terminalPaned)))
        }
    }

    private func presentSettings() {
        SettingsDialog.present(
            parent: window,
            onLayoutChanged: { [weak self] in
                Gtk.onMain { [weak self] in self?.applyLayoutPreferences() }
            },
            onReloadShortcuts: { [weak self] in
                Gtk.onMain { [weak self] in self?.reloadShortcuts() }
            })
    }

    /// Alongside the badge, the caret itself says which mode this is: it blinks only in insert.
    /// In normal and visual it is hidden — the letters belong to commands, and a blinking beam
    /// would promise typing the composer will not do.
    private func updateVimBadge() {
        guard Preferences.vimComposer else {
            gtk_text_view_set_cursor_visible(ptr(entryView), 1)
            gtk_widget_set_visible(vimBadge, 0)
            if let composerScroller {
                gtk_widget_remove_css_class(composerScroller, "composer-normal")
                gtk_widget_remove_css_class(composerScroller, "composer-visual")
            }
            return
        }
        gtk_text_view_set_cursor_visible(ptr(entryView), vim.mode == .insert ? 1 : 0)
        gtk_widget_set_visible(vimBadge, 1)
        gtk_label_set_text(op(vimBadge), vim.mode.label)
        gtk_widget_remove_css_class(vimBadge, "vim-badge-visual")
        gtk_widget_remove_css_class(vimBadge, "vim-badge-insert")
        switch vim.mode {
        case .insert: Gtk.addClass(vimBadge, "vim-badge-insert")
        case .visual, .visualLine: Gtk.addClass(vimBadge, "vim-badge-visual")
        case .normal: break
        }
        guard let composerScroller else { return }
        gtk_widget_remove_css_class(composerScroller, "composer-normal")
        gtk_widget_remove_css_class(composerScroller, "composer-visual")
        switch vim.mode {
        case .normal: Gtk.addClass(composerScroller, "composer-normal")
        case .visual, .visualLine: Gtk.addClass(composerScroller, "composer-visual")
        case .insert: break
        }
    }

    private func composerHasFocus() -> Bool {
        guard let window, let focused = tailscode_focused_widget(window) else { return false }
        return focused == entryView
    }

    /// The prompt box's own key handling: vim first when it is on, then Return-to-send. Both are
    /// decided here rather than in the text view so the same keystroke means the same thing
    /// whether a person typed it or a binding sent it.
    private func handleComposerKey(keyval: UInt32, state: UInt32) -> Bool? {
        guard composerHasFocus() else { return nil }
        let control = state & Keymap.control != 0
        let shift = state & Keymap.shift != 0

        if completionShown {
            switch keyval {
            case Keymap.tab: acceptCompletion(at: completionCursor); return true
            case Keymap.shiftTab: moveCompletion(by: -1); return true
            case Keymap.down: moveCompletion(by: 1); return true
            case Keymap.up: moveCompletion(by: -1); return true
            case Keymap.escape: dismissCompletion(); return true
            default:
                if control, Keymap.scalar(keyval) == "n" { moveCompletion(by: 1); return true }
                if control, Keymap.scalar(keyval) == "p" { moveCompletion(by: -1); return true }
            }
        }

        if Preferences.vimComposer {
            let key = VimKey(
                character: Keymap.scalar(keyval),
                isEscape: keyval == Keymap.escape,
                isEnter: keyval == Keymap.enter || keyval == Keymap.keypadEnter,
                isBackspace: keyval == 0xFF08,
                control: control)
            if vim.mode == .insert, key.isEscape || (control && Keymap.scalar(keyval) == "[") {
                applyVim(vim.handle(VimKey(isEscape: true), text: composerText(), cursor: composerCursor()))
                return true
            }
            if vim.mode != .insert {
                return composerNormalKey(key, keyval: keyval, state: state)
            }
        }

        let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
        if isReturn, !shift, Preferences.sendOnReturn || control {
            sendFromComposer()
            return true
        }
        if isReturn, shift || !Preferences.sendOnReturn { return false }
        return nil
    }

    /// The composer's normal mode is the app's normal mode: every key answers to the shortcut
    /// table first — j scrolls, J switches chats, ? opens the cheatsheet — while vim keeps what
    /// makes it vim: the visual modes whole, insert and visual entries, Enter to send, and every
    /// key of a command already in flight, so `3x`, `diw` and `ct)` still land. A key neither
    /// side binds goes back to vim rather than to the text view, so no stray letter types itself
    /// into the draft.
    private func composerNormalKey(
        _ key: VimKey, keyval: UInt32, state: UInt32
    ) -> Bool? {
        if key.control, Keymap.scalar(keyval) == "c", copyComposerSelection() { return true }
        guard let chord = KeyChord.canonical(keyval: keyval, state: state) else { return nil }
        let awaiting = !(lastState?.pendingPermissions.isEmpty ?? true)
        if awaiting, !chord.control, !chord.alt, pendingChords.isEmpty,
            let action = shortcuts.approval[chord.token]
        {
            pendingChords = []
            return perform(action)
        }
        if key.isEnter, chord.control {
            pendingChords = []
            sendFromComposer()
            return true
        }
        let plain = !chord.control && !chord.alt
        let entries: Set<Character> = ["i", "a", "o", "v", "V"]
        let entersVimMode = plain && (Keymap.scalar(keyval).map { entries.contains($0) } ?? false)
        if vim.mode != .normal || vim.awaitsMore || entersVimMode || (plain && key.isEnter) {
            pendingChords = []
            applyVim(vim.handle(key, text: composerText(), cursor: composerCursor()))
            return true
        }
        let resolution = shortcuts.resolve(
            chord, context: .normal, pending: pendingChords, awaitingApproval: false)
        switch resolution {
        case .run(let action):
            pendingChords = []
            return perform(action)
        case .pending(let chords):
            pendingChords = chords
            return true
        case .unbound:
            pendingChords = []
            applyVim(vim.handle(key, text: composerText(), cursor: composerCursor()))
            return true
        }
    }

    private func copyComposerSelection() -> Bool {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        guard gtk_text_buffer_get_selection_bounds(buffer, &start, &end) != 0,
            let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0)
        else { return false }
        Gtk.copyToClipboard(String(cString: raw))
        g_free(raw)
        toast(Localized.text("Copied"))
        return true
    }

    private func applyVim(_ outcome: VimOutcome) {
        switch outcome {
        case .passThrough, .handled:
            if case .handled = outcome { writeComposer(vim.document, selection: vim.selection) }
        case .send:
            sendFromComposer()
        }
        updateVimBadge()
    }

    /// The prompt box is as tall as what is in it: one line when empty, taller as the text wraps
    /// or a paragraph is pasted, and it stops growing at the height the settings window sets —
    /// after which it scrolls, so the transcript is never squeezed off the screen.
    /// Measured on the next idle, never inline: a text view that was just emptied still reports
    /// the height it had until GTK lays it out again, which is why the box stayed tall after a
    /// send until the next keystroke nudged it.
    private func growComposer() {
        guard !isMeasuringComposer else { return }
        isMeasuringComposer = true
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.isMeasuringComposer = false
            self.measureComposer()
        }
    }

    /// An empty prompt box is one line, whatever the last layout still believes.
    private func measureComposer() {
        guard let composerScroller else { return }
        let line = 20.0 * Preferences.scale(.mono)
        let ceiling = Int32(line * Double(Preferences.composerLines) + 18)
        let floor = Int32(line + 18)

        var minimum: Int32 = 0
        var natural: Int32 = 0
        let width = gtk_widget_get_width(entryView)
        gtk_widget_measure(
            entryView, GTK_ORIENTATION_VERTICAL, width > 0 ? width : -1, &minimum, &natural,
            nil, nil)
        let wanted = composerText().isEmpty ? floor : max(floor, min(ceiling, natural + 18))
        guard wanted != composerHeight else { return }
        composerHeight = wanted
        gtk_widget_set_size_request(composerScroller, -1, wanted)
    }

    private func composerCursor() -> Int {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &iter, gtk_text_buffer_get_insert(buffer))
        return Int(gtk_text_iter_get_offset(&iter))
    }

    private func writeComposer(_ document: VimDocument, selection: Range<Int>?) {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        if composerText() != document.text {
            gtk_text_buffer_set_text(buffer, document.text, -1)
        }
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &caret, Int32(document.cursor))
        if let selection {
            var start = GtkTextIter()
            var end = GtkTextIter()
            gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(selection.lowerBound))
            gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(selection.upperBound))
            gtk_text_buffer_select_range(buffer, &end, &start)
        } else {
            gtk_text_buffer_place_cursor(buffer, &caret)
        }
        gtk_text_view_scroll_to_mark(
            ptr(entryView), gtk_text_buffer_get_insert(buffer), 0, 0, 0, 0)
    }

    private func stopTurn() {
        guard let conversation else { return }
        Task { try? await conversation.cancelCurrentTurn() }
    }

    private func isNearBottom() -> Bool {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return true }
        let value = gtk_adjustment_get_value(adjustment)
        let ceiling = gtk_adjustment_get_upper(adjustment)
            - gtk_adjustment_get_page_size(adjustment)
        return value >= ceiling - 60
    }

    /// Following is a decision, not a measurement. A window that is not focused stops laying out,
    /// so the scroll extent a "go to the bottom" would read is the extent from before the new rows
    /// — which is why an unfocused chat drifts up as it streams. Instead the intent is held here
    /// and re-applied whenever the extent actually changes, focused or not.
    private func setFollowing(_ following: Bool) {
        followsBottom = following
        if following { pinToBottom() }
    }

    /// Setting a value the adjustment already has still emits `changed`, and this runs from the
    /// `changed` handler — writing unconditionally spins the main loop at full tilt.
    private func pinToBottom() {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let target = max(
            gtk_adjustment_get_lower(adjustment),
            gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        guard abs(gtk_adjustment_get_value(adjustment) - target) > 0.5 else { return }
        isAutoScrolling = true
        gtk_adjustment_set_value(adjustment, target)
        isAutoScrolling = false
    }

    private func scrollToBottom() {
        setFollowing(true)
        schedulePinCorrector()
    }

    /// Runs outside layout, after the current pass has settled: pins, then queues an allocation
    /// on the viewport — the widget that actually applies the scroll offset to its child — so the
    /// pixels always match the adjustment. This is the difference between "at the bottom" and
    /// "says it is at the bottom until the window moves". It is also the moment a freshly-filled
    /// transcript is revealed: built invisible, it first appears already settled at the bottom
    /// rather than sliding into place.
    private func schedulePinCorrector() {
        guard !pinCorrectorScheduled else { return }
        pinCorrectorScheduled = true
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.pinCorrectorScheduled = false
            if self.followsBottom { self.pinToBottom() }
            if let scroller = self.transcriptScroller {
                gtk_widget_queue_allocate(scroller)
                if let viewport = gtk_widget_get_first_child(scroller) {
                    gtk_widget_queue_allocate(viewport)
                }
            }
            if self.pendingReveal, self.fillComplete {
                self.pendingReveal = false
                gtk_widget_set_opacity(self.transcriptBox, 1)
            }
        }
    }

    private func scroll(by amount: Double) {
        adjust { $0 + amount }
    }

    private func scroll(byPages fraction: Double) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let page = gtk_adjustment_get_page_size(adjustment) * fraction
        adjust { $0 + page }
    }

    private func scroll(toEnd bottom: Bool) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let limit =
            bottom
            ? gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
            : gtk_adjustment_get_lower(adjustment)
        adjust { _ in limit }
    }

    private func adjust(_ transform: (Double) -> Double) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let ceiling = gtk_adjustment_get_upper(adjustment)
            - gtk_adjustment_get_page_size(adjustment)
        let next = min(max(gtk_adjustment_get_lower(adjustment),
            transform(gtk_adjustment_get_value(adjustment))), max(0, ceiling))
        gtk_adjustment_set_value(adjustment, next)
    }

    /// Typing `/word` offers what it could become, right above the prompt box: filtered as
    /// letters arrive, stepped with the arrows or Ctrl+N/P, taken with Tab, dismissed with
    /// Escape. The popover never takes focus — it is a suggestion, not a dialog — so typing
    /// simply continues underneath it.
    private var completionShown: Bool {
        completionPopover.map { gtk_widget_get_visible($0) != 0 } ?? false
    }

    private func updateSlashCompletion() {
        let typing = !Preferences.vimComposer || vim.mode == .insert
        guard typing, let query = SlashCompletion.query(in: composerText()) else {
            dismissCompletion()
            return
        }
        var matches = SlashCompletion.matches(commands, query: query)
        if matches.count == 1, matches[0].name.lowercased() == query.lowercased() {
            matches = []
        }
        completionMatches = matches
        completionCursor = 0
        guard !matches.isEmpty else {
            dismissCompletion()
            return
        }
        renderCompletion()
    }

    private func moveCompletion(by delta: Int) {
        let count = completionMatches.count
        guard count > 0 else { return }
        completionCursor = ((completionCursor + delta) % count + count) % count
        renderCompletion()
    }

    private func acceptCompletion(at index: Int) {
        guard index < completionMatches.count else { return }
        let command = completionMatches[index]
        let text = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        gtk_text_buffer_set_text(buffer, text, -1)
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_place_cursor(buffer, &end)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        updateVimBadge()
        gtk_widget_grab_focus(entryView)
    }

    private func dismissCompletion() {
        guard let completionPopover, gtk_widget_get_visible(completionPopover) != 0 else {
            return
        }
        gtk_popover_popdown(ptr(completionPopover))
    }

    /// At most eight rows, windowed around the selection so the highlight can never scroll off,
    /// with a count for what the window hides.
    private func renderCompletion() {
        guard let anchor = composerScroller else { return }
        let popover: UnsafeMutablePointer<GtkWidget>
        if let existing = completionPopover {
            popover = existing
        } else {
            popover = gtk_popover_new()!
            gtk_widget_set_parent(popover, anchor)
            gtk_popover_set_autohide(ptr(popover), 0)
            gtk_popover_set_has_arrow(ptr(popover), 0)
            gtk_popover_set_position(ptr(popover), GTK_POS_TOP)
            completionPopover = popover
        }
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let start = max(0, min(completionCursor - 3, completionMatches.count - 8))
        let end = min(completionMatches.count, start + 8)
        for index in start..<end {
            let command = completionMatches[index]
            let item = gtk_button_new()!
            Gtk.addClass(item, "flat")
            if index == completionCursor { Gtk.addClass(item, "completion-selected") }
            let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            gtk_box_append(
                ptr(lines), Gtk.label("/\(command.name)", css: "row-title", selectable: false))
            if !command.details.isEmpty {
                let detail = Gtk.label(command.details, css: "row-detail", selectable: false)
                gtk_label_set_max_width_chars(op(detail), 64)
                gtk_box_append(ptr(lines), detail)
            }
            gtk_button_set_child(ptr(item), lines)
            Gtk.connect(UnsafeMutableRawPointer(item), "clicked") { [weak self] in
                Gtk.onMain { [weak self] in self?.acceptCompletion(at: index) }
            }
            gtk_box_append(ptr(column), item)
        }
        if start > 0 || end < completionMatches.count {
            let hidden = completionMatches.count - (end - start)
            gtk_box_append(
                ptr(column), Gtk.label("… \(hidden) more", css: "row-detail", selectable: false))
        }
        gtk_popover_set_child(ptr(popover), column)
        gtk_popover_popup(ptr(popover))
    }

    private func insertIntoComposer(_ text: String) {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_insert(buffer, &end, text, -1)
        gtk_widget_grab_focus(entryView)
    }

    private func composerText() -> String {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    /// Half-typed prompts follow their conversation, not the window: switching chats stashes what
    /// was in the composer and restores whatever was stashed for the chat being opened.
    private func stashDraft() {
        guard let selectedID else { return }
        let text = composerText()
        let key = "tailscode.draft.\(selectedID)"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsFile.set(trimmed.isEmpty ? nil : text, forKey: key)
    }

    private func restoreDraft(for sessionID: String) {
        let draft = UserDefaults.standard.string(forKey: "tailscode.draft.\(sessionID)") ?? ""
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), draft, -1)
        vim.reset(to: draft, cursor: draft.count, mode: .insert)
        updateVimBadge()
    }

    /// The prompt is on screen before the server has heard of it: a busy bridge can take seconds
    /// to answer, and a composer that empties into silence reads as a hang.
    private func sendFromComposer() {
        let text = composerText().trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = attachments
        guard !text.isEmpty || !outgoing.isEmpty, let conversation else { return }
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        gtk_text_buffer_set_text(buffer, "", 0)
        if let selectedID {
            SettingsFile.set(nil, forKey: "tailscode.draft.\(selectedID)")
        }
        vim.reset(to: "", cursor: 0, mode: .insert)
        updateVimBadge()
        if handleSlashCommand(text) { return }
        echoedPrompt = text
        if let state = lastState { apply(state: state, rows: lastFullRows) }
        attachments = []
        renderAttachments()
        let model = chosenModel
        let effort = chosenEffort
        Task {
            try? await conversation.send(
                text, model: model, reasoningEffort: effort,
                attachments: outgoing.map(\.prompt))
        }
    }

    private func attachRows() -> [(String, String?, @Sendable () -> Void)] {
        guard currentBackend?.capabilities.supportsAttachments != false else {
            return [(Localized.text("This server does not take attachments"), nil, {})]
        }
        return [
            (Localized.text("Attach files…"), Localized.text("Up to 8 MB each"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pickAttachments() } }),
            (Localized.text("Paste image"), Localized.text("From the clipboard, as PNG"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pasteImageAttachment() } }),
        ]
    }

    private func pickAttachments() {
        Gtk.openFiles(parent: window) { [weak self] paths in
            self?.attach(paths: paths)
        }
    }

    private func attach(paths: [String]) {
        for path in paths {
            switch AttachmentIntake.read(path: path) {
            case .success(let attachment):
                attachments.append(attachment)
            case .failure(let refusal):
                setNotice(refusal.message)
            }
        }
        renderAttachments()
    }

    private func pasteImageAttachment() {
        Gtk.readClipboardImage { [weak self] data in
            guard let self else { return }
            guard let data else {
                self.setNotice(
                            Localized.text("The clipboard holds no picture."))
                return
            }
            guard data.count <= AttachmentIntake.byteCap else {
                self.setNotice(
                            Localized.text(
                        "That picture is %@ — the cap is 8 MB",
                        AttachmentIntake.sizeText(data.count)))
                return
            }
            self.pastedImageCount += 1
            self.attachments.append(
                PendingAttachment(
                    name: "pasted-\(self.pastedImageCount).png", mime: "image/png", data: data))
            self.renderAttachments()
        }
    }

    private func renderAttachments() {
        Gtk.removeChildren(of: attachmentsBox)
        gtk_widget_set_visible(attachmentsBox, attachments.isEmpty ? 0 : 1)
        for attachment in attachments {
            let title = "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))  ✕"
            let id = attachment.id
            gtk_box_append(
                ptr(attachmentsBox),
                Gtk.button(title, css: ["chip"]) { [weak self] in
                    guard let self else { return }
                    self.attachments.removeAll { $0.id == id }
                    self.renderAttachments()
                })
        }
    }

    private func jumpToBottom() {
        scrollToBottom()
        clearUnseen()
    }

    private func clearUnseen() {
        unseenRows = 0
        gtk_widget_set_visible(jumpButton, 0)
    }

    private func noteAppendedWhileScrolledUp(_ count: Int) {
        guard count > 0 else { return }
        unseenRows += count
        gtk_button_set_label(ptr(jumpButton), "↓ \(unseenRows)")
        gtk_widget_set_visible(jumpButton, 1)
    }

    private func setFindShown(_ shown: Bool) {
        gtk_widget_set_visible(findBar, shown ? 1 : 0)
        if shown {
            gtk_widget_grab_focus(findEntry)
            runFind(retarget: false)
        } else {
            gtk_editable_set_text(op(findEntry), "")
            clearFindHighlight()
            findMatches = []
            gtk_label_set_text(op(findCountLabel), "")
            gtk_widget_grab_focus(transcriptBox)
        }
    }

    private func findQuery() -> String {
        guard let raw = gtk_editable_get_text(op(findEntry)) else { return "" }
        return String(cString: raw)
    }

    private func runFind(retarget: Bool) {
        let needle = findQuery().lowercased()
        clearFindHighlight()
        guard !needle.isEmpty else {
            findMatches = []
            gtk_label_set_text(op(findCountLabel), "")
            return
        }
        findMatches = renderedRows.indices.filter {
            renderedRows[$0].searchText.lowercased().contains(needle)
        }
        if retarget { findCursor = 0 }
        if findCursor >= findMatches.count { findCursor = max(0, findMatches.count - 1) }
        updateFindCount()
        guard !findMatches.isEmpty else { return }
        applyFindHighlight(scroll: retarget)
    }

    private func stepFind(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        findCursor = ((findCursor + delta) % count + count) % count
        updateFindCount()
        applyFindHighlight(scroll: true)
    }

    private func updateFindCount() {
        gtk_label_set_text(
            op(findCountLabel),
            findMatches.isEmpty
                ? Localized.text("No matches") : "\(findCursor + 1)/\(findMatches.count)")
    }

    /// Marks the current match, and on an explicit jump scrolls it to the upper third so the eye
    /// lands on the hit rather than hunting for it. The offset is measured against the widget the
    /// adjustment actually scrolls — the padded canvas — not the transcript box inside it.
    private func applyFindHighlight(scroll: Bool) {
        guard findMatches.indices.contains(findCursor) else { return }
        let index = findMatches[findCursor]
        guard index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
        else { return }
        clearFindHighlight()
        let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        Gtk.addClass(widget, "find-hit")
        highlightedRow = rowWidgets[index]
        guard scroll else { return }
        let offset = tailscode_widget_offset_y(widget, canvasBox ?? transcriptBox)
        guard offset >= 0, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let page = gtk_adjustment_get_page_size(adjustment)
        let ceiling = max(0, gtk_adjustment_get_upper(adjustment) - page)
        gtk_adjustment_set_value(adjustment, min(max(0, offset - page * 0.3), ceiling))
    }

    private func clearFindHighlight() {
        guard highlightedRow != 0,
            let raw = UnsafeMutableRawPointer(bitPattern: highlightedRow)
        else { return }
        gtk_widget_remove_css_class(ptr(raw) as UnsafeMutablePointer<GtkWidget>, "find-hit")
        highlightedRow = 0
    }

    /// Quota is account state, not session state: polled on its own slow cadence and rendered in
    /// the sidebar footer, the way the phone keeps it on the Home board.
    private func startUsagePolling() {
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                let settled = await self?.refreshUsage() ?? true
                try? await Task.sleep(for: .seconds(settled ? 120 : 15))
            }
        }
    }

    /// False while the profile list has not been seeded yet — the poll retries quickly then,
    /// rather than leaving the footer empty for its whole slow cadence after a cold start.
    private func refreshUsage() async -> Bool {
        let profiles = await ServerDirectory.shared.profiles()
        guard !profiles.isEmpty else { return false }
        let snapshot = await Self.collectQuotas(profiles: profiles)
        Gtk.onMain { [weak self] in
            self?.lastQuotas = snapshot
            self?.renderUsage(snapshot)
        }
        return true
    }

    /// Every quota every server can speak for: the agent's own, plus whatever other providers
    /// the machine holds accounts for (a bridge also reports Grok). One machine answering for a
    /// provider is enough — a second profile on the same host must not double the card.
    private static func collectQuotas(profiles: [ConnectionProfile]) async -> [(String, UsageQuota)]
    {
        var quotas: [(String, UsageQuota)] = []
        var seen = Set<String>()
        for profile in profiles {
            guard let backend = await ServerDirectory.shared.backend(for: profile) else { continue }
            var collected: [UsageQuota] = []
            if let quota = (try? await backend.usageQuota()) ?? nil { collected.append(quota) }
            collected += (try? await backend.additionalUsageQuotas()) ?? []
            for quota in collected where seen.insert("\(quota.providerName)|\(quota.source)").inserted {
                quotas.append((profile.name, quota))
            }
        }
        return quotas
    }

    private func presentUsage() {
        UsagePanel.present(parent: sidebarPane, initial: lastQuotas) {
            await Self.collectQuotas(profiles: await ServerDirectory.shared.profiles())
        }
    }

    /// Quota as a glance, not a paragraph: one thin bar per gauge, the number beside it, and the
    /// reset countdown tucked under the row that actually resets. The bar carries the severity —
    /// quiet until 60%, amber past it, red near the wall — so a full sidebar footer still reads
    /// in half a second.
    private func renderUsage(_ quotas: [(String, UsageQuota)]) {
        Gtk.removeChildren(of: usageBox)
        gtk_widget_set_visible(usageBox, quotas.isEmpty ? 0 : 1)
        for (name, quota) in quotas {
            let slug = ProviderBrand.slug(quota.providerName)
            let header = Gtk.label(
                "\(quota.providerName) · \(name)", css: "section-header", selectable: false)
            if let slug { Gtk.addClass(header, "brand-\(slug)") }
            gtk_box_append(ptr(usageBox), header)
            for gauge in quota.gauges {
                let fraction = min(max(gauge.fraction, 0), 1)
                let severity = fraction > 0.85 ? "danger" : fraction >= 0.6 ? "warn" : "ok"

                let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
                let title = Gtk.label(gauge.label, css: "gauge-\(severity)", selectable: false)
                gtk_widget_set_hexpand(title, 1)
                gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
                gtk_box_append(ptr(row), title)

                let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
                Gtk.addClass(track, "gauge-track")
                gtk_widget_set_size_request(track, 72, 5)
                gtk_widget_set_valign(track, GTK_ALIGN_CENTER)
                gtk_widget_set_hexpand(track, 0)
                let fill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
                Gtk.addClass(fill, ProviderBrand.fillClass(severity: severity, slug: slug))
                gtk_widget_set_size_request(fill, Int32((fraction * 72).rounded()), 5)
                gtk_box_append(ptr(track), fill)
                gtk_box_append(ptr(row), track)

                let percent = Gtk.label(
                    "\(Int((fraction * 100).rounded()))%", css: "gauge-\(severity)",
                    selectable: false)
                gtk_widget_set_size_request(percent, 34, -1)
                gtk_label_set_xalign(op(percent), 1)
                gtk_box_append(ptr(row), percent)
                gtk_box_append(ptr(usageBox), row)

                if let resets = gauge.resetsAt, gauge.trustedReset, fraction >= 0.6 {
                    let detail = Gtk.label(
                        Localized.text("resets in %@", Self.countdown(to: resets)),
                        css: "gauge-reset", selectable: false)
                    gtk_box_append(ptr(usageBox), detail)
                }
            }
        }
    }

    private static func countdown(to date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return Localized.text("moments") }
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// A typed slash command goes where the palette would send it: `/compact` to its preflight,
    /// a known server command to the command route when the server wants one, and anything
    /// unknown out as plain text — the server is the authority on its own grammar.
    private func handleSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let name = String(text.dropFirst().prefix(while: { !$0.isWhitespace }))
        let arguments = String(text.dropFirst(1 + name.count)).trimmingCharacters(
            in: .whitespaces)
        if name == "compact" {
            presentCompactPreflight(initialInstruction: arguments)
            return true
        }
        guard let command = commands.first(where: { $0.name == name }),
            let conversation
        else { return false }
        if currentBackend?.resolvesCommandsFromPromptText == true { return false }
        Task {
            try? await conversation.run(command, arguments: arguments.isEmpty ? nil : arguments)
        }
        return true
    }
}
