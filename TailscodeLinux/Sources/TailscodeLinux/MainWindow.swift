import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The window: the chat list, the tiling tree of conversations, and the project they work in.
///
/// State lives here on the GLib main context; everything that talks to a server happens in a
/// detached `Task` and comes back through ``Gtk/onMain(_:)``. There is no `@MainActor` anywhere in
/// this app — `g_application_run` never drains libdispatch's main queue, so awaiting into a
/// main-actor type from a signal handler would suspend forever with no crash and no log line.
///
/// A conversation itself lives in a ``ChatPane``; this class owns only what is genuinely the
/// window's — the sidebar, the file tree and terminal beside the tree, the shortcut dispatcher,
/// and the dialogs — and reaches the conversation through ``SplitHost``'s focused pane.
final class MainWindow: @unchecked Sendable {
    private var window: UnsafeMutablePointer<GtkWidget>?
    private let sidebarList = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let sidebarBanner = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let titleLabel = Gtk.label("", css: "mono", selectable: false)
    private let fileTree = FileTree()
    private let terminal = TerminalPane()

    private let searchEntry = gtk_search_entry_new()!

    private var sidebarLimit = 60
    private let usageBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private var usageTask: Task<Void, Never>?

    private var splitWidget: UnsafeMutablePointer<GtkWidget>?
    private var projectPaned: UnsafeMutablePointer<GtkWidget>?
    private var terminalPaned: UnsafeMutablePointer<GtkWidget>?
    private var sidebarPane: UnsafeMutablePointer<GtkWidget>?
    private var lastSidebar: ([SessionRowModel], [String], String, String)?

    /// The last full row list per session, shared across every pane so a chat reopened anywhere —
    /// same pane, another pane, a second pane on the same session — paints in the first frame.
    private var sessionRows: [String: [TranscriptRow]] = [:]
    private var sessionRowOrder: [String] = []

    private var entries: [SessionEntry] = []
    /// The configured servers, kept on the main context so an empty pane can ask its question in
    /// the same frame the split happens rather than after a hop through the directory actor.
    private var knownProfiles: [ConnectionProfile] = []
    /// Sessions whose delete is confirmed but not yet acknowledged by the server. Every listing
    /// keeps reporting the session until the delete lands, and each report would resurrect the
    /// row; the tombstone outlives them all.
    private var pendingDeletes: Set<String> = []
    private var showingArchive = false
    private var sidebarScroller: UnsafeMutablePointer<GtkWidget>?
    private var sidebarColumn: UnsafeMutablePointer<GtkWidget>?
    private var sidebarScrollTarget: Double?
    private var visible: [SessionRowModel] = []
    private var unreachable: [String] = []
    private var lastQuotas: [(String, UsageQuota)] = []

    /// Quotas the panes read for used-up surfaces — same numbers the sidebar footer shows.
    func quotasForStatus() -> [UsageQuota] { lastQuotas.map(\.1) }
    private var cursor = 0
    private var filter = ""
    var pendingChords: [KeyChord] = []
    private(set) var shortcuts = ShortcutSet.load()
    private var focused: Pane = .chats
    /// The chat the person just started from the + button: known-empty, kept in the list by hand
    /// until the server's own listing carries it.
    private var freshlyCreated: SessionEntry?
    private var refreshTask: Task<Void, Never>?
    private var toastOverlay: UnsafeMutablePointer<GtkWidget>?
    private var listStreamTasks: [Task<Void, Never>] = []

    private var splitHost: SplitHost!
    /// What each restored pane was showing, until the listing carries the session and the pane
    /// can open it for real.
    private var pendingBindings: [PaneID: SplitPaneSession] = [:]
    private var listedFromNetwork = false

    var windowWidget: UnsafeMutablePointer<GtkWidget>? { window }

    var activePane: ChatPane { splitHost.activePane }

    /// The canvas follows the desktop, and the chats you had are on screen before the first byte
    /// crosses the tailnet — with liveness stripped from the cache, so nothing shown from it can
    /// claim to be running. The tiling tree is restored before the first paint for the same
    /// reason: the window's shape is local state and must never wait on a server.
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

        splitHost = SplitHost(host: self)
        if let raw = UserDefaults.standard.string(forKey: SplitSnapshot.defaultsKey),
            let snapshot = SplitSnapshot.decode(raw)
        {
            pendingBindings = splitHost.restore(snapshot)
        }

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

        fileTree.onOpen = { [weak self] path in
            self?.activePane.insertIntoComposer("@\(path) ")
        }
        splitHost.eachPane { $0.rebuildHelpOverlay() }
        installKeymap(on: window)
        installPressRouting(on: window)
        Notifier.shared.attach(app: app) { [weak self] sessionID in
            self?.openSession(withID: sessionID)
        }
        applyPanePreferences()
        let cachedEntries = SessionListCache.load()
        if !cachedEntries.isEmpty { applyEntries(cachedEntries, unreachable: [], fromNetwork: false) }
        startRefreshing()
        startUsagePolling()
        FirstRunDialog.presentIfNeeded(parent: window) { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
        if let seed = ProcessInfo.processInfo.environment["TAILSCODE_COMPOSER"] {
            activePane.insertIntoComposer(seed.replacingOccurrences(of: "\\n", with: "\n"))
        }
        installDriver()
    }

    /// `TAILSCODE_DRIVE="2000:open=1;4000:up=400;6000:jump"` — timed UI actions for headless
    /// validation, driving the same code paths a person's clicks and wheel do.
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
                case "openid":
                    if let match = self.visible.first(where: { $0.entry.session.id == argument }) {
                        self.open(match.entry)
                    } else {
                        let ids = self.visible.prefix(6).map { $0.entry.session.id }
                        FileHandle.standardOutput.write(
                            Data(
                                "OPENID missing \(argument) of \(self.visible.count): \(ids.joined(separator: ","))\n"
                                    .utf8))
                    }
                case "workflowdemo":
                    self.activePane.driverWorkflowDemo()
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
                    self.activePane.scroll(by: -(Double(argument) ?? 200))
                case "down":
                    self.activePane.scroll(by: Double(argument) ?? 200)
                case "jump":
                    self.activePane.jumpToBottom()
                case "settings":
                    self.presentSettings()
                case "usage":
                    self.presentUsage()
                case "type":
                    let pane = self.activePane
                    pane.driverType(argument)
                    let names = pane.completionMatches.prefix(5).map(\.name)
                    FileHandle.standardOutput.write(
                        Data(
                            "COMPLETION \(pane.completionMatches.count) [\(names.joined(separator: ","))] shown=\(pane.completionShown)\n"
                                .utf8))
                    FileHandle.standardOutput.write(
                        Data("AURA \(pane.auraActive ? "on" : "off")\n".utf8))
                case "tab":
                    _ = self.activePane.handleComposerKey(keyval: Keymap.tab, state: 0)
                    FileHandle.standardOutput.write(
                        Data("COMPOSER \"\(self.activePane.composerText())\"\n".utf8))
                case "files":
                    _ = self.perform(.toggleFiles)
                case "term":
                    _ = self.perform(.toggleTerminal)
                    Gtk.after(300) { [weak self] in
                        guard let self, let window = self.window else { return }
                        FileHandle.standardOutput.write(
                            Data("TERMFOCUS \(self.terminal.ownsFocus(in: window))\n".utf8))
                    }
                case "agents":
                    self.activePane.bandState.openMenu(id: "agents")
                case "toast":
                    self.toast(Localized.text("Command copied"))
                case "reader":
                    self.activePane.context.presentText?(
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
                case "split":
                    _ = self.perform(.splitPane(argument == "down" ? .vertical : .horizontal))
                case "sfocus":
                    _ = self.perform(.focusSplit(SplitDirection(rawValue: argument) ?? .right))
                case "sclose":
                    _ = self.perform(.closeSplit)
                case "szoom":
                    _ = self.perform(.zoomSplit)
                case "sxchg":
                    _ = self.perform(.exchangeSplit)
                case "seq":
                    _ = self.perform(.equalizeSplits)
                case "full":
                    if let window = self.window { gtk_window_fullscreen(ptr(window)) }
                case "handles":
                    guard let window = self.window else { break }
                    var shadowX: Double = 0
                    var shadowY: Double = 0
                    gtk_native_get_surface_transform(op(window), &shadowX, &shadowY)
                    let centers = self.splitHost.handleCenters(in: window)
                        .map { ($0.0, $0.1 + shadowX, $0.2 + shadowY) }
                        .map { String(format: "%.0f,%.0f", $0.1, $0.2) }
                        .sorted()
                    FileHandle.standardOutput.write(
                        Data(
                            "HANDLES \(centers.count) \(centers.joined(separator: " ")) window=\(gtk_widget_get_width(window))x\(gtk_widget_get_height(window))\n"
                                .utf8))
                case "geom":
                    guard let window = self.window else { break }
                    var shadowX: Double = 0
                    var shadowY: Double = 0
                    gtk_native_get_surface_transform(op(window), &shadowX, &shadowY)
                    let described = self.splitHost.orderedPanes.enumerated().map {
                        index, pane -> String in
                        let bounds = Gtk.bounds(of: pane.root, in: window) ?? (0, 0, 0, 0)
                        let composer =
                            pane.composerScroller.flatMap { Gtk.bounds(of: $0, in: window) }
                            ?? (0, 0, 0, 0)
                        return String(
                            format: "%d(%.0f,%.0f %.0fx%.0f composer=%.0f,%.0f)", index,
                            bounds.x + shadowX, bounds.y + shadowY, bounds.width, bounds.height,
                            composer.x + composer.width / 2 + shadowX,
                            composer.y + composer.height / 2 + shadowY)
                    }.joined(separator: " ")
                    FileHandle.standardOutput.write(Data("GEOM \(described)\n".utf8))
                case "chooser":
                    FileHandle.standardOutput.write(
                        Data("CHOOSER \(self.activePane.chooserSummary ?? "-")\n".utf8))
                case "watch":
                    let pane = self.activePane
                    pane.showVideo(VideoTarget.classify(argument))
                    FileHandle.standardOutput.write(
                        Data("WATCH \(pane.videoSummary ?? "-")\n".utf8))
                case "browse":
                    let pane = self.activePane
                    pane.showWeb(WebTarget.classify(argument))
                    FileHandle.standardOutput.write(
                        Data("BROWSE \(pane.webSummary ?? "-")\n".utf8))
                case "web":
                    let described = self.splitHost.orderedPanes.enumerated().map {
                        index, pane in "\(index):\(pane.webSummary ?? "chat")"
                    }.joined(separator: " | ")
                    FileHandle.standardOutput.write(Data("WEB \(described)\n".utf8))
                case "wkey":
                    let keyval: UInt32
                    var state: UInt32 = 0
                    switch argument {
                    case "back": keyval = 0xFF51; state = KeyChord.altMask
                    case "forward": keyval = 0xFF53; state = KeyChord.altMask
                    case "reload": keyval = 0x72; state = KeyChord.controlMask
                    case "address": keyval = 0x6C; state = KeyChord.controlMask
                    default: keyval = argument.unicodeScalars.first.map { UInt32($0.value) } ?? 0
                    }
                    var handled = false
                    if let chord = KeyChord.canonical(keyval: keyval, state: state) {
                        handled = self.activePane.handleWebChord(chord)
                    }
                    FileHandle.standardOutput.write(
                        Data(
                            "WKEY \(argument) handled=\(handled) \(self.activePane.webSummary ?? "-")\n"
                                .utf8))
                case "video":
                    let described = self.splitHost.orderedPanes.enumerated().map {
                        index, pane in "\(index):\(pane.videoSummary ?? "chat")"
                    }.joined(separator: " | ")
                    FileHandle.standardOutput.write(Data("VIDEO \(described)\n".utf8))
                case "vkey":
                    let keyval = argument == "space"
                        ? UInt32(0x20)
                        : (argument.unicodeScalars.first.map { UInt32($0.value) } ?? 0)
                    var handled = false
                    if let chord = KeyChord.canonical(keyval: keyval, state: 0) {
                        handled = self.activePane.handleVideoChord(chord)
                    }
                    FileHandle.standardOutput.write(
                        Data(
                            "VKEY \(argument) handled=\(handled) \(self.activePane.videoSummary ?? "-")\n"
                                .utf8))
                case "ckey":
                    let keyval: UInt32
                    switch argument {
                    case "enter": keyval = Keymap.enter
                    case "esc": keyval = Keymap.escape
                    case "up": keyval = Keymap.up
                    case "down": keyval = Keymap.down
                    default:
                        keyval = argument.unicodeScalars.first.map { UInt32($0.value) } ?? 0
                    }
                    if let chord = KeyChord.canonical(keyval: keyval, state: 0) {
                        let handled = self.activePane.handleChooserChord(chord)
                        FileHandle.standardOutput.write(
                            Data(
                                "CKEY \(argument) handled=\(handled) \(self.activePane.chooserSummary ?? "-")\n"
                                    .utf8))
                    }
                case "drag", "drop":
                    let fields = argument.split(separator: ",").map(String.init)
                    let index = Int(fields.first ?? "") ?? 0
                    let u = Double(fields.count > 1 ? fields[1] : "0.5") ?? 0.5
                    let v = Double(fields.count > 2 ? fields[2] : "0.5") ?? 0.5
                    let sessionID = fields.count > 3 ? fields[3] : self.entries.first?.session.id
                    let panes = self.splitHost.orderedPanes
                    guard panes.indices.contains(index),
                        let id = sessionID,
                        let entry = self.entries.first(where: { $0.session.id.hasPrefix(id) })
                    else {
                        FileHandle.standardOutput.write(Data("DROP no-target\n".utf8))
                        break
                    }
                    let pane = panes[index]
                    let payload = PaneDragPayload(
                        profileID: entry.profileID, sessionID: entry.session.id)
                    let x = u * Double(gtk_widget_get_width(pane.root))
                    let y = v * Double(gtk_widget_get_height(pane.root))
                    if verb == "drag" {
                        self.splitHost.hover(pane, payload: payload, x: x, y: y)
                        FileHandle.standardOutput.write(
                            Data("DRAG \(self.splitHost.dropSummary)\n".utf8))
                    } else {
                        let took = self.splitHost.receiveDrop(payload.encoded, on: pane.id, x: x, y: y)
                        FileHandle.standardOutput.write(
                            Data("DROP took=\(took) panes=\(self.splitHost.paneCount)\n".utf8))
                    }
                case "splits":
                    let layout = self.splitHost.layout
                    let frames = layout.frames()
                    let described = layout.paneIDs.enumerated().map { index, id -> String in
                        let frame = frames[id] ?? SplitRect(x: 0, y: 0, width: 0, height: 0)
                        let mark = id == layout.focusedPane ? "*" : ""
                        let session = self.splitHost.panes[id]?.sessionID?.prefix(8) ?? "-"
                        return String(
                            format: "%d%@(%@ %.2f,%.2f %.2fx%.2f)", index, mark,
                            String(session), frame.x, frame.y, frame.width, frame.height)
                    }.joined(separator: " ")
                    FileHandle.standardOutput.write(
                        Data(
                            "SPLITS \(layout.paneCount) zoom=\(layout.zoomedPane != nil) region=\(self.focused) \(described)\n"
                                .utf8))
                case "state":
                    let pane = self.activePane
                    let adjustment = pane.transcriptScroller.flatMap {
                        gtk_scrolled_window_get_vadjustment(op($0))
                    }
                    let value = adjustment.map { gtk_adjustment_get_value($0) } ?? -1
                    let upper = adjustment.map {
                        gtk_adjustment_get_upper($0) - gtk_adjustment_get_page_size($0)
                    } ?? -1
                    FileHandle.standardOutput.write(
                        Data(
                            "STATE follows=\(pane.followsBottom) rows=\(pane.renderedRows.count)/\(pane.lastFullRows.count) value=\(Int(value)) bottom=\(Int(upper)) unseen=\(pane.unseenRows)\n"
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
        sidebarColumn = column
        Gtk.addClass(toolbar, "sidebar-pane")
        sidebarPane = toolbar
        return toolbar
    }

    /// The tiling tree on the left of the content area, the project it works in on the right.
    /// Both panes may be squeezed below their natural width: without that, a pane whose content
    /// is naturally wide makes the split wider than the window, and GTK resolves that by drawing
    /// the conversation off the left edge.
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
        gtk_paned_set_start_child(op(panes), splitHost.container)
        gtk_paned_set_end_child(op(panes), makeProjectColumn())
        gtk_paned_set_position(op(panes), Preferences.divider(.project) ?? 800)
        gtk_paned_set_resize_start_child(op(panes), 1)
        gtk_paned_set_shrink_start_child(op(panes), 1)
        gtk_paned_set_shrink_end_child(op(panes), 1)
        projectPaned = panes

        adw_toolbar_view_set_content(op(toolbar), panes)
        return toolbar
    }

    private func makeProjectColumn() -> UnsafeMutablePointer<GtkWidget> {
        gtk_widget_set_size_request(fileTree.widget, 180, -1)
        return fileTree.widget
    }

    private func makeActionsButton() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.menuButton("⋯", css: ["flat"]) { [weak self] in
            self?.activePane.actionRows() ?? []
        }
    }

    /// A two-second floating confirmation — the answer to "did my click do anything".
    func toast(_ text: String) {
        guard let toastOverlay else { return }
        let toast = adw_toast_new(text)
        adw_toast_set_timeout(toast, 2)
        adw_toast_overlay_add_toast(op(toastOverlay), toast)
    }

    var windowIsActive: Bool {
        guard let window else { return false }
        return gtk_window_is_active(ptr(window)) != 0
    }

    /// At most a handful of transcripts are kept renderable; the oldest falls out so a long day
    /// of chats does not become a memory of every one of them.
    func rememberRows(_ rows: [TranscriptRow], for sessionID: String) {
        if sessionRows[sessionID] == nil {
            sessionRowOrder.append(sessionID)
            if sessionRowOrder.count > 6 {
                let evicted = sessionRowOrder.removeFirst()
                sessionRows[evicted] = nil
            }
        }
        sessionRows[sessionID] = rows
    }

    func rememberedRows(for sessionID: String) -> [TranscriptRow]? {
        sessionRows[sessionID]
    }

    func scheduleSidebarRender() {
        renderSidebar()
    }

    /// A pane took a conversation: the window chrome follows it only when that pane is the
    /// focused one — an unfocused pane opening in the background must not steal the title bar.
    func paneOpened(_ pane: ChatPane) {
        guard pane === activePane else { return }
        refreshChromeForActivePane()
    }

    /// The focused pane changed — by keyboard, click, or a structural verb. The title bar, the
    /// file tree, the terminal and the remembered last-session all follow the eye.
    func focusedPaneChanged() {
        refreshChromeForActivePane()
        lastSidebar = nil
        renderSidebar()
    }

    /// A press anywhere inside a pane makes it the focused one — the transcript, the prompt box,
    /// the band, a pill, a permission card, the chooser, and either button. It runs in the capture
    /// phase, before the widget under the pointer acts, so a control in a background pane acts on
    /// its own conversation rather than on whichever pane the eye had left behind. GTK has already
    /// placed keyboard focus where the press landed, so nothing is grabbed.
    func paneClicked(_ pane: ChatPane) {
        Trace.mark("paneClicked \(splitHost.orderedPanes.firstIndex(where: { $0 === pane }) ?? -1)")
        focused = .transcript
        splitHost.focus(pane, grabKeyboard: false)
    }

    /// The same rule for the regions beside the tree: pressing in the chat list, the file tree or
    /// the terminal is what makes them the keyboard's region, so Tab cycles from where the hand
    /// actually is. Only the region moves — the press keeps whatever it was going to do, and
    /// nothing is given the keyboard that the press did not already give it.
    private func regionClicked(_ pane: Pane) {
        guard focused != pane else { return }
        focused = pane
        if pane != .transcript { activePane.dismissCompletion() }
    }

    /// One capture-phase watcher on the window itself decides what a press activated. It has to be
    /// the toplevel: a menu button pops its popover on the press, and a gesture on any widget in
    /// between never sees that sequence at all. Nothing is claimed, so the press still does
    /// whatever it was going to do — this only decides what it was aimed at.
    private func installPressRouting(on window: UnsafeMutablePointer<GtkWidget>) {
        let root = UInt(bitPattern: window)
        Gtk.onPressCapture(window) { [weak self] x, y in
            guard let self, let base = UnsafeMutableRawPointer(bitPattern: root) else { return }
            self.pressLanded(x: x, y: y, in: ptr(base))
        }
    }

    private func pressLanded(x: Double, y: Double, in window: UnsafeMutablePointer<GtkWidget>) {
        if let pane = splitHost.pane(at: x, y: y, in: window) {
            paneClicked(pane)
            return
        }
        for (widget, region) in regionTargets
        where widget.map({ Gtk.contains($0, x: x, y: y, in: window) }) == true {
            regionClicked(region)
            return
        }
    }

    private var regionTargets: [(UnsafeMutablePointer<GtkWidget>?, Pane)] {
        [(sidebarColumn, .chats), (fileTree.widget, .files), (terminal.widget, .terminal)]
    }

    private func refreshChromeForActivePane() {
        let pane = activePane
        if let entry = pane.entry {
            gtk_label_set_text(
                op(titleLabel),
                entry.session.hasPlaceholderTitle
                    ? Localized.text("New conversation") : entry.session.title)
            Preferences.setLastSession(entry.session.id)
        } else {
            gtk_label_set_text(op(titleLabel), "")
        }
        workspaceSync(pane)
    }

    /// The file tree and the terminal are workspace chrome, not pane chrome: they point at the
    /// focused pane's project, and follow focus rather than multiplying per pane.
    func workspaceSyncIfFocused(_ pane: ChatPane) {
        guard pane === activePane else { return }
        workspaceSync(pane)
    }

    private func workspaceSync(_ pane: ChatPane) {
        terminal.setDirectory(pane.entry?.session.directory)
        if let backend = pane.backend, let entry = pane.entry {
            fileTree.show(directory: entry.session.directory, on: backend)
        }
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
            splitHost.eachPane { pane in
                if pane.sessionID == session.id { pane.refreshPills() }
            }
        case .remove(let id):
            entries.removeAll { $0.profileID == profile.id && $0.session.id == id }
            renderSidebar()
        case .invalidated:
            Task { [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        await ServerDirectory.shared.reload()
        let profiles = await ServerDirectory.shared.profiles()
        let (entries, unreachable) = await ServerDirectory.shared.entries()
        if !entries.isEmpty { SessionListCache.save(entries) }
        Gtk.onMain { [weak self] in
            self?.knownProfiles = profiles
            self?.warmCatalogs(profiles)
            self?.rememberDividers()
            self?.applyEntries(entries, unreachable: unreachable)
            SettingsFile.capture()
        }
    }

    /// Opens the conversation that was open last, not merely the newest one — and resolves every
    /// restored pane's remembered session as soon as the listing carries it.
    private func applyEntries(
        _ entries: [SessionEntry], unreachable: [String], fromNetwork: Bool = true
    ) {
        self.entries = entries
        self.unreachable = unreachable
        if fromNetwork { listedFromNetwork = true }
        if let fresh = freshlyCreated {
            if entries.contains(where: { $0.session.id == fresh.session.id }) {
                freshlyCreated = nil
            } else {
                self.entries.insert(fresh, at: 0)
            }
        }
        resolvePendingBindings()
        renderSidebar()
        restateChoosers()
        let active = activePane
        guard active.sessionID == nil, pendingBindings[active.id] == nil, !entries.isEmpty,
            !active.isAnswering
        else { return }
        let remembered = Preferences.lastSession.flatMap { id in
            entries.first { $0.session.id == id }
        }
        active.open(remembered ?? entries[0])
    }

    /// A restored pane opens its session the moment the listing carries it. A session the
    /// network-backed listing does not carry gets an explanation, not a collapse — and the
    /// binding is kept, because a server that was unreachable this minute may list it the next.
    private func resolvePendingBindings() {
        guard !pendingBindings.isEmpty else { return }
        for (paneID, binding) in pendingBindings {
            guard let pane = splitHost.panes[paneID] else {
                pendingBindings[paneID] = nil
                continue
            }
            if let entry = entries.first(where: {
                $0.profileID == binding.profileID && $0.session.id == binding.sessionID
            }) {
                pendingBindings[paneID] = nil
                pane.open(entry)
            } else if listedFromNetwork {
                pane.showPlaceholder(
                    Localized.text(
                        "The chat this pane was showing is not in any listing right now."))
            }
        }
    }

    /// Rebuilding two hundred rows of widgets is a visible stutter — nothing is touched unless
    /// what the list would say actually differs from what it says now, and only the first
    /// screenful or two are built.
    private func renderSidebar() {
        Trace.mark("renderSidebar begin \(entries.count) entries")
        defer { Trace.mark("renderSidebar end") }
        let selectedID = activePane.sessionID
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
                saved: saved.contains($0.session.id),
                pinned: SessionPinStore.contains(
                    profileID: $0.profileID, sessionID: $0.session.id))
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
                || ($0.snippet?.lowercased().contains(needle) ?? false)
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
            "\(selectedID ?? "")|\(sidebarLimit)|\(showingArchive)|\(archivedTotal)|\(splitHost.paneCount)"
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

    /// The archive's one entry point: a quiet count at the foot of the list.
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

    /// The old offset is put back from an idle callback — after GTK's resize pass, so the fresh
    /// rows have a height for the adjustment to clamp against.
    private func restoreSidebarScroll(_ value: Double) {
        guard value > 0, let sidebarScroller else { return }
        let bits = UInt(bitPattern: sidebarScroller)
        Gtk.onMain {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            gtk_adjustment_set_value(gtk_scrolled_window_get_vadjustment(op(raw)), value)
        }
    }

    /// The highlight follows the conversation that is open, never a position. The keyboard cursor
    /// is re-derived from the open chat so J/K continues from where the eye is.
    private func syncCursorToSelection() {
        guard !visible.isEmpty else {
            cursor = 0
            return
        }
        if let selectedID = activePane.sessionID,
            let index = visible.firstIndex(where: { $0.entry.session.id == selectedID })
        {
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
    /// deleted, or its profile removed. Rows for chats the listing no longer covers are rebuilt
    /// from the bookmark's own snapshot.
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

    /// What a second launch gets: the window that exists, brought forward. Never a second one —
    /// the first is still holding every session's stream.
    func raise() {
        guard let window else { return }
        gtk_window_present(ptr(window))
    }

    /// A notification tap arrives here: raise the window, then bring the session it names to the
    /// eye — the pane already showing it if one is, else the focused pane.
    func openSession(withID id: String) {
        if let window { gtk_window_present(ptr(window)) }
        if let pane = splitHost.pane(showing: id) {
            splitHost.focus(pane, grabKeyboard: false)
            return
        }
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

    /// Opening from the list always lands in the focused pane; a background pane keeps what it
    /// has, which is the point of having panes.
    private func open(_ entry: SessionEntry) {
        freshlyCreated = nil
        activePane.open(entry)
    }

    /// A pane with nothing in it asks which server, then what on it — the question the chat list
    /// cannot ask, at the moment a split makes it worth asking. The servers may not be loaded yet
    /// on the very first frame, so the chooser goes up with what is known and restates itself the
    /// moment the directory answers.
    func presentChooser(in pane: ChatPane, preferring serverID: String? = nil) {
        pane.showChooser(chooserModel(preferredServer: serverID))
        guard knownProfiles.isEmpty else { return }
        Task { [weak self] in
            if await ServerDirectory.shared.profiles().isEmpty {
                await ServerDirectory.shared.reload()
            }
            let profiles = await ServerDirectory.shared.profiles()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.knownProfiles = profiles
                self.restateChoosers()
            }
        }
    }

    /// The servers a pane may offer beyond its own — the model chooser spans the fleet, and a pane
    /// does not keep the directory itself.
    func fleetProfiles() -> [ConnectionProfile] { knownProfiles }

    /// Asks every server what it runs, once, when the listing lands. The chooser has to be able to
    /// name a machine's models before anyone has opened a chat on it, and a catalog nobody asked
    /// for is the difference between a fleet-wide list and a list of wherever you happen to be.
    private func warmCatalogs(_ profiles: [ConnectionProfile]) {
        for profile in profiles where ModelCatalogStore.cached(profile.id).isEmpty {
            Task {
                guard let backend = await ServerDirectory.shared.backend(for: profile) else {
                    return
                }
                await ModelCatalogStore.refresh(profileID: profile.id, backend: backend)
            }
        }
    }

    /// A pane asking for a chat on another machine, which is what picking that machine's model
    /// means.
    func startChat(on profileID: String, into pane: ChatPane) {
        guard let profile = knownProfiles.first(where: { $0.id == profileID }) else { return }
        presentNewChat(on: profile, into: pane)
    }

    private func chooserModel(preferredServer: String?) -> PaneChooser {
        PaneChooser(
            servers: chooserServers, entries: entries, preferredServer: preferredServer)
    }

    private var chooserServers: [PaneChooserServer] {
        knownProfiles.map { profile in
            PaneChooserServer(
                profileID: profile.id, name: profile.name, backend: profile.backend,
                address: ServerLabel.address(profile),
                reachable: !unreachable.contains(ServerLabel.display(profile)))
        }
    }

    private func restateChoosers() {
        let servers = chooserServers
        splitHost.eachPane { pane in
            guard pane.chooserShown else { return }
            pane.restateChooser(servers: servers, entries: entries)
        }
    }

    /// What a chooser row means once it is chosen. The pane that asked is the pane that fills —
    /// including the new chat, which lands where the question was asked rather than in whichever
    /// pane the focus later wandered to.
    func pane(_ pane: ChatPane, chose action: PaneChooserAction) {
        switch action {
        case .openChat(let profileID, let sessionID):
            guard
                let entry = entries.first(where: {
                    $0.profileID == profileID && $0.session.id == sessionID
                })
            else { return }
            pane.open(entry)
        case .newChat(let profileID):
            guard let profile = knownProfiles.first(where: { $0.id == profileID }) else { return }
            presentNewChat(on: profile, into: pane)
        case .addServer:
            presentServers()
        case .browse:
            pane.showWeb(nil)
            splitHost.focus(pane, grabKeyboard: false)
            splitHost.persist()
        case .watch:
            pane.showVideo(nil)
            splitHost.focus(pane, grabKeyboard: false)
            splitHost.persist()
        case .chooseServer, .allChats, .back:
            break
        }
    }

    /// A slot that started, stopped, or learned the stream's own title. The layout is written back
    /// so a restart reopens what was playing, exactly as it reopens a conversation.
    func videoSlotChanged() {
        splitHost.persist()
    }

    /// What a chat dragged from the list is called, for the caption inside the drop highlight —
    /// the listing first, then the bookmarks, so a chat whose server is unreachable still names
    /// itself while it is being carried.
    func chatTitle(for payload: PaneDragPayload) -> String? {
        if let entry = self.entry(for: payload) {
            return SessionRowModel(entry: entry, unreachable: false, unread: false, saved: false)
                .title
        }
        return SavedChatStore.all().first { $0.sessionID == payload.sessionID }?.title
    }

    private func entry(for payload: PaneDragPayload) -> SessionEntry? {
        entries.first {
            $0.profileID == payload.profileID && $0.session.id == payload.sessionID
        }
    }

    /// A chat let go over a pane. The middle of a pane means open it there; an edge means the
    /// arrangement the highlight drew — the pane halves and the arriving chat takes that side. A
    /// chat no listing knows changes nothing rather than emptying a pane.
    @discardableResult
    func pane(_ pane: ChatPane, received payload: PaneDragPayload, zone: PaneDropZone) -> Bool {
        guard let entry = entry(for: payload) else { return false }
        freshlyCreated = nil
        switch zone {
        case .fill:
            pane.open(entry)
            splitHost.focus(pane, grabKeyboard: false)
        case .split(let edge):
            guard let fresh = splitHost.split(pane, edge: edge) else { return false }
            fresh.open(entry)
            splitHost.focus(fresh, grabKeyboard: false)
        }
        focused = .transcript
        return true
    }

    /// - Parameters:
    ///   - profile: the server the dialog opens on, when the question has already been answered
    ///     somewhere else — a pane's chooser — so it is never asked twice.
    ///   - pane: where the minted chat opens; the focused pane when nothing says otherwise.
    private func presentNewChat(on profile: ConnectionProfile? = nil, into pane: ChatPane? = nil) {
        Task { [weak self, weak pane] in
            let profiles = await ServerDirectory.shared.profiles()
            let localAddresses = Self.localAddresses
            Gtk.onMain { [weak self, weak pane] in
                guard let self else { return }
                guard !profiles.isEmpty else {
                    self.presentServers()
                    return
                }
                let ordered =
                    profile.map { chosen in
                        [chosen] + profiles.filter { $0.id != chosen.id }
                    } ?? profiles
                var seen = Set<String>()
                let recents = self.entries.compactMap(\.session.directory).filter {
                    seen.insert($0).inserted
                }
                Dialogs.newChat(
                    parent: self.window, profiles: ordered, recentDirectories: recents,
                    localAddresses: localAddresses
                ) { [weak self, weak pane] profile, directory in
                    self?.createChat(on: profile, directory: directory, into: pane)
                }
            }
        }
    }

    /// Read once, off the main context: `tailscale status` is a subprocess, and the answer does
    /// not change within a run.
    private static let localAddresses: Set<String> = {
        var hosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        var name = [CChar](repeating: 0, count: 256)
        if gethostname(&name, 255) == 0 { hosts.insert(String(cString: name).lowercased()) }
        if let address = TailnetStatusLinux.read().address { hosts.insert(address) }
        return hosts
    }()

    /// The one round trip that mints the session id is all the new chat waits for; the full list
    /// refresh reconciles behind it.
    private func createChat(
        on profile: ConnectionProfile, directory: String?, into pane: ChatPane? = nil
    ) {
        Trace.mark("createChat begin")
        Task { [weak self, weak pane] in
            guard let backend = await ServerDirectory.shared.backend(for: profile) else { return }
            do {
                let session = try await backend.createSession(title: nil, directory: directory)
                Trace.mark("createChat session created")
                let entry = SessionEntry(
                    profileID: profile.id, profileName: profile.name,
                    host: profile.baseURL.host ?? profile.name,
                    backendType: profile.backend, session: session)
                Gtk.onMain { [weak self, weak pane] in
                    guard let self else { return }
                    if !self.entries.contains(where: { $0.session.id == entry.session.id }) {
                        self.entries.insert(entry, at: 0)
                    }
                    self.freshlyCreated = entry
                    self.lastSidebar = nil
                    self.renderSidebar()
                    (pane ?? self.activePane).open(entry, freshlyCreated: true)
                }
                await self?.refresh()
                Trace.mark("createChat refresh done")
            } catch {
                Gtk.onMain { [weak self, weak pane] in
                    guard let self else { return }
                    (pane ?? self.activePane).setNotice(
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

    func presentRename(entry: SessionEntry, backend: any CodingAgentBackend) {
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
                    guard let self, self.activePane.sessionID == sessionID else { return }
                    gtk_label_set_text(op(self.titleLabel), title)
                }
            }
        }
    }

    func fork(entry: SessionEntry, backend: any CodingAgentBackend) {
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

    func presentCompactPreflight(for pane: ChatPane, initialInstruction: String = "") {
        guard let conversation = pane.conversation else { return }
        Dialogs.compactPreflight(
            parent: window, initialInstruction: initialInstruction
        ) { instruction in
            Task { try? await conversation.compact(instructions: instruction) }
        }
    }

    func presentClear(entry: SessionEntry, backend: any CodingAgentBackend) {
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

    /// Optimistic on confirm: the row disappears and the next chat opens before the server has
    /// answered. Every pane showing the session empties with an explanation; the focused one
    /// moves on to the next chat.
    func presentDelete(entry: SessionEntry, backend: any CodingAgentBackend) {
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
                let active = self.activePane
                self.splitHost.eachPane { pane in
                    guard pane.sessionID == sessionID else { return }
                    if pane === active, let next = self.entries.first {
                        pane.open(next)
                    } else {
                        pane.reset(placeholder: Localized.text("That conversation was deleted."))
                    }
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
                        self.activePane.setNotice(Localized.text("Could not delete: %@", failure))
                        self.renderSidebar()
                    }
                }
                if failure != nil { await self?.refresh() }
            }
        }
    }

    func toggleSaved(_ entry: SessionEntry) {
        _ = SavedChatStore.toggle(entry)
        SettingsFile.capture()
        renderSidebar()
    }

    /// The right-click menu on a chat row, anchored to the sidebar's own box — a widget that
    /// outlives any re-render.
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
        if entry.session.id != activePane.sessionID {
            rows.append(
                (Localized.text("Open"), nil,
                 { [weak self] in Gtk.onMain { [weak self] in self?.open(entry) } }))
        }
        rows.append(
            (Localized.text("Open in a new split"),
             Localized.text("Beside the conversations already on screen"),
             { [weak self] in
                 Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.splitHost.splitActive(axis: .horizontal)
                     self.activePane.open(entry)
                 }
             }))
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
        let pinned = SessionPinStore.contains(
            profileID: entry.profileID, sessionID: entry.session.id)
        rows.append(
            (pinned ? Localized.text("Unpin") : Localized.text("Pin"),
             pinned
                 ? Localized.text("Back into the recency order")
                 : Localized.text("Always at the top of the chat list"),
             { [weak self] in
                 Gtk.onMain { [weak self] in
                     SessionPinStore.toggle(
                         profileID: entry.profileID, sessionID: entry.session.id)
                     self?.renderSidebar()
                 }
             }))
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

    /// Normal mode owns the letters; focusing anything that takes text hands them back, and the
    /// terminal keeps everything but Ctrl+Shift and zoom. The composer key first goes to
    /// whichever pane's composer actually has focus, and that pane becomes the focused one before
    /// the key acts — so typing into a pane and commanding it are never two different panes.
    private func installKeymap(on window: UnsafeMutablePointer<GtkWidget>) {
        let root = UInt(bitPattern: window)
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self, let base = UnsafeMutableRawPointer(bitPattern: root) else {
                return false
            }
            let window: UnsafeMutablePointer<GtkWidget> = ptr(base)
            for pane in self.splitHost.orderedPanes where pane.composerHasFocus() {
                self.splitHost.focus(pane, grabKeyboard: false)
                if let handled = pane.handleComposerKey(keyval: keyval, state: state) {
                    return handled
                }
                break
            }
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                return false
            }
            let context: KeyContext =
                self.terminal.ownsFocus(in: window)
                ? .terminal : Gtk.focusTakesText(window) ? .insert : .normal
            if context == .normal, self.focused == .transcript, self.pendingChords.isEmpty,
                self.activePane.handleChooserChord(chord)
            {
                return true
            }
            if context == .normal, self.focused == .transcript, self.pendingChords.isEmpty,
                self.activePane.handleVideoChord(chord)
            {
                return true
            }
            if self.focused == .transcript, self.pendingChords.isEmpty,
                self.activePane.handleWebChord(chord)
            {
                return true
            }
            let awaiting =
                context == .normal
                && !(self.activePane.lastState?.pendingPermissions.isEmpty ?? true)
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
            activePane.setNotice(
                Localized.text(
                    "Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    /// Re-reads the rebinding file and rebuilds everything derived from it, live: the resolver,
    /// every pane's cheatsheet, and the notice line if the file has something wrong in it.
    func reloadShortcuts() {
        shortcuts = ShortcutSet.load()
        pendingChords = []
        splitHost.eachPane { $0.rebuildHelpOverlay() }
        if shortcuts.issues.isEmpty {
            toast(Localized.text("Shortcuts reloaded"))
        } else {
            activePane.setNotice(
                Localized.text(
                    "Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    /// Ctrl+C over a selection means copy everywhere else on the desktop; only with nothing
    /// selected does the stop binding mean "stop the turn". Conversation verbs land on the
    /// focused pane; the split verbs work the tree itself.
    func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .focus(let pane): focus(pane)
        case .cycleForward: focus(nextPane(after: focused, by: 1))
        case .cycleBackward: focus(nextPane(after: focused, by: -1))
        case .selectNext: move(by: 1)
        case .selectPrevious: move(by: -1)
        case .selectFirst: cursor = 0; openCursor()
        case .selectLast: cursor = max(0, visible.count - 1); openCursor()
        case .openSelected: openCursor()
        case .scrollDown: activePane.scroll(by: 60)
        case .scrollUp: activePane.scroll(by: -60)
        case .halfPageDown: activePane.scroll(byPages: 0.5)
        case .halfPageUp: activePane.scroll(byPages: -0.5)
        case .scrollTop: activePane.scroll(toEnd: false)
        case .scrollBottom: activePane.scroll(toEnd: true)
        case .insert:
            focus(.transcript)
            activePane.focusComposer()
        case .leaveInsert:
            let pane = activePane
            if pane.findShown { pane.setFindShown(false) }
            pane.dismissCompletion()
            gtk_widget_grab_focus(sidebarList)
            pane.setHelp(false)
        case .search: gtk_widget_grab_focus(searchEntry)
        case .send: activePane.sendFromComposer()
        case .stop:
            if let window, let focused = tailscode_focused_widget(window),
                let selection = tailscode_label_selection(focused)
            {
                Gtk.copyToClipboard(String(cString: selection))
                g_free(selection)
                toast(Localized.text("Copied"))
            } else {
                activePane.stopTurn()
            }
        case .toggleHelp: activePane.setHelp(!activePane.helpShown)
        case .reload: Task { [weak self] in await self?.refresh() }
        case .allowOnce: activePane.respondToFirstPermission(.once)
        case .allowAlways: activePane.respondToFirstPermission(.always)
        case .deny: activePane.respondToFirstPermission(.reject)
        case .newChat: presentNewChat()
        case .toggleSaved:
            if let entry = activePane.entry { toggleSaved(entry) }
        case .findInConversation: activePane.setFindShown(true)
        case .zoomIn: UIScale.step(0.1)
        case .zoomOut: UIScale.step(-0.1)
        case .zoomReset: UIScale.reset()
        case .toggleSidebar: togglePane(.sidebar)
        case .toggleFiles: togglePane(.files)
        case .toggleTerminal: togglePane(.terminal)
        case .commandPalette: activePane.popupCommandPalette()
        case .archiveSelected:
            if let entry = activePane.entry { toggleArchived(entry) }
        case .toggleArchiveView: setArchiveShown(!showingArchive)
        case .toggleUnreadSelected: toggleUnreadSelected()
        case .renameSelected:
            if let entry = activePane.entry, let backend = activePane.backend,
                backend.capabilities.supportsRenaming
            {
                presentRename(entry: entry, backend: backend)
            }
        case .forkSelected:
            if let entry = activePane.entry, let backend = activePane.backend,
                backend.capabilities.supportsForking
            {
                fork(entry: entry, backend: backend)
            }
        case .deleteSelected:
            if let entry = activePane.entry, let backend = activePane.backend {
                presentDelete(entry: entry, backend: backend)
            }
        case .copySessionID:
            if let entry = activePane.entry {
                Gtk.copyToClipboard(entry.session.id)
                toast(Localized.text("Copied"))
            }
        case .copyProjectPath:
            if let directory = activePane.entry?.session.directory {
                Gtk.copyToClipboard(directory)
                toast(Localized.text("Copied"))
            }
        case .splitPane(let axis):
            focused = .transcript
            splitHost.splitActive(axis: axis)
        case .closeSplit:
            splitHost.closeActive()
        case .focusSplit(let direction):
            focused = .transcript
            _ = splitHost.focusNeighbor(direction)
        case .zoomSplit:
            splitHost.zoomActive()
        case .equalizeSplits:
            splitHost.equalize()
        case .exchangeSplit:
            splitHost.exchangeActive()
        }
        return true
    }

    private func toggleUnreadSelected() {
        guard let entry = activePane.entry else { return }
        let unread = SessionSeenStore.unreadEvaluator()(entry.session.id, entry.session.updatedAt)
        if unread {
            SessionSeenStore.markSeen(entry.session.id)
        } else {
            SessionSeenStore.markUnread(entry.session.id, updatedAt: entry.session.updatedAt)
        }
        renderSidebar()
    }

    private func nextPane(after pane: Pane, by delta: Int) -> Pane {
        let all = Pane.allCases
        let index = (all.firstIndex(of: pane) ?? 0) + delta
        return all[(index % all.count + all.count) % all.count]
    }

    private func focus(_ pane: Pane) {
        focused = pane
        if pane != .transcript { activePane.dismissCompletion() }
        switch pane {
        case .chats: gtk_widget_grab_focus(sidebarList)
        case .transcript: activePane.focusTranscript()
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

    /// Every pane closes: the chat list collapses into the split view, the file tree and the
    /// terminal give their space back to the conversation. The choice survives relaunch.
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

    /// Everything the settings window can change that is not a colour: the window's own pane
    /// sizes here, and each conversation pane restyling itself.
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
        terminal.setFontScale(Preferences.terminalScale)
        terminal.applyPalette(MatrixTheme.palette)
        splitHost.eachPane { $0.applyLayoutPreferences() }
        splitHost.applyRatios()
    }

    /// The desktop's dark preference flipped: reload the stylesheet for the other palette and let
    /// every pane re-derive its rows, whose prose markup carries the palette's colors baked in.
    private func retheme() {
        MatrixTheme.install()
        terminal.applyPalette(MatrixTheme.palette)
        splitHost.eachPane { $0.retheme() }
    }

    /// The dividers are read back rather than watched: a size saved a few seconds after the drag
    /// is indistinguishable from one saved during it. A position saved on a wide window would
    /// leave nothing for the other pane on a narrow one, so every divider is pulled back inside
    /// the window it is actually in before it is saved.
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

    /// The window's own shape, read back on the same slow tick as the dividers.
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
        Preferences.setLastSession(activePane.sessionID)
        if let splitWidget, gtk_widget_get_visible(sidebarPane ?? splitWidget) != 0 {
            Preferences.setDivider(.sidebar, position: gtk_paned_get_position(op(splitWidget)))
        }
        if let projectPaned, gtk_widget_get_visible(fileTree.widget) != 0 {
            Preferences.setDivider(.project, position: gtk_paned_get_position(op(projectPaned)))
        }
        if let terminalPaned, gtk_widget_get_visible(terminal.widget) != 0 {
            Preferences.setDivider(.terminal, position: gtk_paned_get_position(op(terminalPaned)))
        }
        splitHost.captureRatios()
        splitHost.persist()
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

    /// Quota is account state, not session state: polled on its own slow cadence and rendered in
    /// the sidebar footer.
    private func startUsagePolling() {
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                let settled = await self?.refreshUsage() ?? true
                try? await Task.sleep(for: .seconds(settled ? 120 : 15))
            }
        }
    }

    /// False while the profile list has not been seeded yet — the poll retries quickly then.
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

    /// Every quota every server can speak for. One machine answering for a provider is enough —
    /// a second profile on the same host must not double the card.
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
    /// reset countdown tucked under the row that actually resets.
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

                let percentText = QuotaSurface.amountLabel(
                    fraction: gauge.fraction,
                    percentText: "\(Int((fraction * 100).rounded()))%")
                let percent = Gtk.label(
                    percentText, css: "gauge-\(severity)",
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
}
