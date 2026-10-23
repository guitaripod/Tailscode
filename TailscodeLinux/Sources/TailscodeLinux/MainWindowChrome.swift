import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// The way in to video, carrying the weight the app gives its other primary actions: it sits
    /// in the sidebar's header beside the button that starts a chat, rather than inside the gear
    /// menu, which is where a preference lives and not where an action does. It promises something
    /// different before a renderer exists than after, and it wears the render's own mark while the
    /// other machine is working — so somebody who closed the surface can still see it is out.
    func makeVideoButton() -> UnsafeMutablePointer<GtkWidget> {
        let button = Gtk.button(ForgeEntryPoint.glyph, css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.presentForge() }
        }
        videoButton = button
        let ring = ForgeButtonRing(button: button)
        videoRing = ring
        ForgeRunner.shared.watch(self) { [weak self] in
            Gtk.onMain { [weak self] in self?.refreshVideoButton() }
        }
        refreshVideoButton()
        return ring.widget
    }

    func refreshVideoButton() {
        guard let videoButton else { return }
        let light = ForgeRunner.shared.light
        gtk_widget_set_tooltip_text(
            videoButton,
            ForgeEntryPoint.tooltip(configured: ForgeRunner.shared.endpoint != nil, light: light))
        tailscode_set_accessible_label(videoButton, ForgeEntryPoint.accessibilityLabel(light: light))
        videoRing?.apply(light)
    }

    func makeSidebarPane() -> UnsafeMutablePointer<GtkWidget> {
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        adw_header_bar_set_show_end_title_buttons(op(header), 0)
        adw_header_bar_set_title_widget(op(header), makeSidebarTitle())
        adw_header_bar_pack_start(
            op(header),
            Gtk.button("+", css: ["flat"]) { [weak self] in self?.presentNewChat() })
        adw_header_bar_pack_start(op(header), makeVideoButton())
        adw_header_bar_pack_end(
            op(header),
            Gtk.menuButton("⚙", css: ["flat"]) { [weak self] in
                let settings: @Sendable () -> Void = { [weak self] in
                    Gtk.onMain { [weak self] in self?.presentSettings() }
                }
                let servers: @Sendable () -> Void = { [weak self] in
                    Gtk.onMain { [weak self] in self?.presentServers() }
                }
                let software: @Sendable () -> Void = { [weak self] in
                    Gtk.onMain { [weak self] in self?.presentUpdates() }
                }
                let about: @Sendable () -> Void = { [weak self] in
                    Gtk.onMain { [weak self] in AboutWindow.present(parent: self?.window) }
                }
                let forge: @Sendable () -> Void = { [weak self] in
                    Gtk.onMain { [weak self] in _ = self?.presentForge() }
                }
                let delegate: @Sendable () -> Void = { [weak self] in
                    Gtk.onMain { [weak self] in self?.presentDelegate() }
                }
                let archive: @Sendable () -> Void = { [weak self] in
                    Gtk.onMain { [weak self] in self?.setArchiveShown(true) }
                }
                var rows: [(String, String, @Sendable () -> Void)] = []
                if let filed = self?.archivedCount(), filed > 0 {
                    rows.append(
                        (ChatArchiveRule.door(count: filed), ChatArchiveRule.doorSubtitle, archive))
                }
                return rows + [
                    (ForgeEntryPoint.menuTitle,
                     ForgeEntryPoint.tooltip(configured: ForgeRunner.shared.endpoint != nil), forge),
                    (DelegateEntryPoint.menuTitle, DelegateEntryPoint.subtitle, delegate),
                    (Localized.text("Settings…"),
                     Localized.text("Type sizes, the prompt box, vim mode, layout"), settings),
                    (Localized.text("Servers…"),
                     Localized.text("Add, probe, update or remove a server"), servers),
                    (Localized.text("Software…"),
                     Localized.text("What this app and every server is running"), software),
                    (Localized.text("About Tailscode"),
                     Localized.text("Version, what it was built with, diagnostics to paste"), about),
                ]
            })
        adw_toolbar_view_add_top_bar(op(toolbar), header)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_search_entry_set_placeholder_text(
            op(searchEntry), Localized.text("Filter chats  /   ⏎ to search inside"))
        Gtk.margins(searchEntry, top: 4, bottom: 4, leading: 6, trailing: 6)
        Gtk.connect(UnsafeMutableRawPointer(searchEntry), "search-changed") { [weak self] in
            self?.applyFilterFromEntry()
        }
        Gtk.connect(UnsafeMutableRawPointer(searchEntry), "activate") { [weak self] in
            Gtk.onMain { [weak self] in self?.runTranscriptSearch() }
        }
        gtk_box_append(ptr(column), searchEntry)
        gtk_box_append(ptr(column), sidebarBanner)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        Gtk.margins(sidebarList, top: 2, bottom: 8, leading: 6, trailing: 6)
        gtk_scrolled_window_set_child(op(scroller), makeSidebarViewport())
        gtk_widget_set_vexpand(scroller, 1)
        let listOverlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(listOverlay), scroller)
        gtk_widget_set_vexpand(listOverlay, 1)
        gtk_box_append(ptr(column), listOverlay)
        sidebarScroller = scroller
        installRowVerbs(on: listOverlay)
        Gtk.onPressHold(
            scroller,
            down: { [weak self] in self?.holdSidebar() },
            up: { [weak self] in
                Gtk.onMain { [weak self] in
                    Gtk.onMain { [weak self] in self?.releaseSidebar() }
                }
            })
        if let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) {
            Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "upper") { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.reapplySidebarScroll()
                    self?.applySidebarReveal()
                }
            }
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "value-changed") { [weak self] in
                self?.rowVerbsScrolled()
            }
        }

        gtk_widget_set_visible(updateBox, 0)
        Gtk.addClass(updateBox, "update-footer")
        Gtk.margins(updateBox, top: 6, bottom: 6, leading: 0, trailing: 10)
        gtk_widget_set_cursor_from_name(updateBox, "pointer")
        gtk_widget_set_tooltip_text(updateBox, Localized.text("What every machine is running"))
        gtk_widget_set_valign(updateGlyph, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(updateHeadline, 1)
        gtk_box_append(ptr(updateBox), updateGlyph)
        gtk_box_append(ptr(updateBox), updateHeadline)
        Gtk.onRelease(updateBox) { [weak self] in self?.presentUpdates() }
        let footRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(footRow, "clock-footer")
        Gtk.margins(clockChip.widget, top: 6, bottom: 6, leading: 10, trailing: 0)
        gtk_widget_set_hexpand(updateBox, 1)
        gtk_box_append(ptr(footRow), clockChip.widget)
        gtk_box_append(ptr(footRow), updateBox)
        gtk_box_append(ptr(column), footRow)
        ClockWatch.shared.start()

        gtk_widget_set_visible(usageBox, 0)
        Gtk.addClass(usageBox, "usage-footer")
        Gtk.margins(usageBox, top: 6, bottom: 8, leading: 10, trailing: 10)
        gtk_widget_set_cursor_from_name(usageBox, "pointer")
        gtk_widget_set_tooltip_text(usageBox, Localized.text("The full quota picture"))
        Gtk.onRelease(usageBox) { [weak self] in self?.presentUsage() }
        NotificationCenter.default.addObserver(
            forName: ChatDensitySetting.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            SettingsFile.capture()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                MatrixTheme.install()
                self.applyLayoutPreferences()
            }
        }
        NotificationCenter.default.addObserver(
            forName: ActivityStyleSetting.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            SettingsFile.capture()
            Gtk.onMain { [weak self] in self?.applyLayoutPreferences() }
        }
        NotificationCenter.default.addObserver(
            forName: QuotaBoardStore.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            SettingsFile.capture()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.renderUsage(self.lastQuotas)
            }
        }
        NotificationCenter.default.addObserver(
            forName: ModelCatalogStore.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.renderSidebar() }
        }
        gtk_widget_set_tooltip_text(orb.widget, Localized.text("Nothing is running"))
        Gtk.onRelease(orb.widget) { [weak self] in
            guard let self, let entry = self.orbTarget else { return }
            self.open(entry)
        }
        gtk_box_append(ptr(column), usageBox)
        gtk_box_append(ptr(column), orb.widget)

        adw_toolbar_view_set_content(op(toolbar), column)
        sidebarColumn = column
        Gtk.addClass(toolbar, "sidebar-pane")
        sidebarPane = toolbar
        return toolbar
    }

    /// A name is a word or it is nothing. The app's own name spelled TAILSCO… is a header that
    /// looks broken rather than a header that ran out of room, so the label never ellipsizes and
    /// gives way whole: below the width it needs the title simply is not drawn, and the two
    /// buttons either side of it — new chat, settings — keep the bar they were always the point of.
    func makeSidebarTitle() -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label("TAILSCODE", css: "section-header", selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        sidebarTitle = label
        return label
    }

    /// What the two buttons either side of the name need before the name may have the rest: new
    /// chat on one side, settings and its chevron on the other, and the margins between them.
    static let sidebarTitleClearance: Int32 = 130

    /// The divider's position rather than the pane's allocation: this runs from `notify::position`,
    /// where the drag has already moved the divider and GTK has not yet laid the pane out, so the
    /// allocation is still the width the title was last judged against — and a header that decides
    /// on a stale width is a `+` button that disappears for one drag and comes back on the next.
    func fitSidebarTitle() {
        guard let sidebarTitle else { return }
        let width =
            splitWidget.map { gtk_paned_get_position(op($0)) }
            ?? sidebarPane.map { gtk_widget_get_width($0) } ?? 0
        guard width > 0 else { return }
        var minimum: Int32 = 0
        var natural: Int32 = 0
        var minimumBaseline: Int32 = 0
        var naturalBaseline: Int32 = 0
        gtk_widget_measure(
            sidebarTitle, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, &minimumBaseline,
            &naturalBaseline)
        sidebarTitleWidth = max(sidebarTitleWidth, natural)
        guard sidebarTitleWidth > 0 else { return }
        gtk_widget_set_visible(
            sidebarTitle, width >= sidebarTitleWidth + Self.sidebarTitleClearance ? 1 : 0)
    }

    /// The chat list moves when this window says so, and for no other reason. A scrolled window
    /// wraps whatever it is given in a viewport that scrolls itself to keep the focused widget
    /// visible, and every row here is a button: a rebuild that destroys the row holding focus, a
    /// press that lands on a row, `ctrl+w h` — each of them re-homes focus inside the list, and the
    /// viewport answers by scrolling somewhere nobody asked to go, under a reader who was mid-list.
    /// So the viewport is built here rather than conjured, with that behaviour off, and the one
    /// case that genuinely wants the list to move — the keyboard cursor walking past the fold —
    /// is `applySidebarReveal`, which scrolls the least it can rather than centring on the row.
    func makeSidebarViewport() -> UnsafeMutablePointer<GtkWidget> {
        let viewport = gtk_viewport_new(nil, nil)!
        gtk_viewport_set_scroll_to_focus(op(viewport), 0)
        gtk_viewport_set_child(op(viewport), sidebarList)
        return viewport
    }

    /// The tiling tree on the left of the content area, the project it works in on the right.
    /// Both panes may be squeezed below their natural width: without that, a pane whose content
    /// is naturally wide makes the split wider than the window, and GTK resolves that by drawing
    /// the conversation off the left edge.
    func makeContentPane() -> UnsafeMutablePointer<GtkWidget> {
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
            Gtk.button("⌨", css: ["flat"]) { [weak self] in self?.togglePane(.terminal) })
        let chip = Gtk.menuButton("", css: ["flat", "live-chip"]) { [weak self] in
            self?.liveChipSections() ?? []
        }
        gtk_widget_set_visible(chip, 0)
        adw_header_bar_pack_end(op(header), chip)
        liveChipHold = Gtk.WeakWidget(chip)
        adw_toolbar_view_add_top_bar(op(toolbar), header)
        contentHeader = header

        adw_toolbar_view_set_content(op(toolbar), splitHost.container)
        return toolbar
    }

    func makeActionsButton() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.menuButton("⋯", css: ["flat"]) { [weak self] in
            guard let self else { return [] }
            let chat = self.activePane.actionRows().map {
                Gtk.MenuRow(title: $0.0, detail: $0.1, action: $0.2)
            }
            return [Gtk.MenuSection(heading: nil, rows: chat)] + self.paneMenuSections()
        }
    }

    /// Whether a pane verb that is a switch is on for the focused pane, for the mark in the menu.
    func paneMenuMarks(_ id: String) -> Bool {
        guard let tile = splitHost as? TileHost else { return false }
        switch id {
        case "split.pin": return tile.activeIsPinned
        case "split.park": return tile.activeIsParked
        default: return false
        }
    }

    /// What the chat list last heard about a conversation, for a pane that holds it without
    /// streaming it: its title and the face its row wears.
    func listFace(for session: SplitPaneSession) -> (title: String, activity: ActivityKind?)? {
        guard
            let entry = entries.first(where: {
                $0.profileID == session.profileID && $0.session.id == session.sessionID
            })
        else { return nil }
        let model = SessionRowModel(
            entry: entry, unreachable: unreachable.contains(entry.profileID), unread: false,
            saved: false)
        return (model.title, model.state.activity)
    }

    /// The live chip: how many chats are whole out of how many are open, drawn only once there are
    /// two to count.
    func updateLiveChip() {
        guard isStanding, let chip = liveChip, let tile = splitHost as? TileHost else { return }
        let counts = tile.liveCounts
        let shown = counts.chats > 1
        if gtk_widget_get_visible(chip) != (shown ? 1 : 0) {
            gtk_widget_set_visible(chip, shown ? 1 : 0)
        }
        guard shown else { return }
        let title = LiveChipReading.title(
            live: counts.live, chats: counts.chats, decision: tile.lastDecision)
        guard title != liveChipText else { return }
        liveChipText = title
        gtk_menu_button_set_label(op(chip), title)
        tailscode_set_accessible_label(chip, title)
    }

    func liveChipSections() -> [Gtk.MenuSection] {
        guard let tile = splitHost as? TileHost else { return [] }
        let decision = tile.lastDecision
        var rows = [
            Gtk.MenuRow(title: LiveChipReading.explanation(decision: decision), detail: nil),
            Gtk.MenuRow(
                title: Localized.text("Keep all live"), detail: nil,
                on: Seatbelts.shared.liveBudget == .all,
                action: {
                    Gtk.onMain {
                        Seatbelts.shared.setLiveBudget(
                            Seatbelts.shared.liveBudget == .all ? .auto : .all)
                    }
                }),
        ]
        if decision?.level.overridesPreference == true {
            rows.append(Gtk.MenuRow(title: LiveChipReading.ignoredNote, detail: nil))
        }
        return [Gtk.MenuSection(heading: nil, rows: rows)]
    }

    /// The pane verbs in the menu, for a person who never learns the chords: Core's groups in
    /// Core's order, each row wearing the keys it is on right now, rebinding included. Only a
    /// window with something to arrange offers them.
    func paneMenuSections() -> [Gtk.MenuSection] {
        guard splitHost.paneCount > 1 else { return [] }
        let named = SplitMenu.arrangements.map { arrangement in
            Gtk.MenuRow(
                title: "\(arrangement.glyph) \(arrangement.title)", detail: nil,
                on: SplitEven.shape(of: splitHost.layout) == arrangement,
                action: { [weak self] in
                    Gtk.onMain { [weak self] in self?.splitHost.arrange(arrangement) }
                })
        }
        var sections = [Gtk.MenuSection(heading: Localized.text("Panes"), rows: named)]
        var groups = SplitMenu.groups.map { ($0.title, $0.shortcutIDs) }
        groups.append((Localized.text("Focus"), ["split.cycle", "split.cycleBack"]))
        if splitHost.supportsDensity {
            groups.append((Localized.text("Live"), ["split.pin", "split.park"]))
        }
        for (title, ids) in groups {
            let rows = ids.compactMap { id -> Gtk.MenuRow? in
                guard let definition = SplitMenu.definition(id) else { return nil }
                let keys = shortcuts.effective[id]?.joined(separator: " / ")
                return Gtk.MenuRow(
                    title: definition.title, detail: keys,
                    on: paneMenuMarks(id),
                    action: { [weak self] in
                        Gtk.onMain { [weak self] in _ = self?.perform(definition.action) }
                    })
            }
            sections.append(Gtk.MenuSection(heading: title, rows: rows))
        }
        return sections
    }

    /// A two-second floating confirmation — the answer to "did my click do anything".
    func toast(_ text: String) {
        guard let toastOverlay else { return }
        let toast = adw_toast_new(text)
        adw_toast_set_timeout(toast, 2)
        adw_toast_overlay_add_toast(op(toastOverlay), toast)
    }

    /// A confirmation that replaces the one before it rather than queueing behind it: a wheel
    /// turned five notches says where it landed now, not five sentences in a row over ten seconds.
    func flash(_ text: String) {
        guard let toastOverlay, let toast = adw_toast_new(text) else { return }
        if let lastFlash {
            adw_toast_dismiss(lastFlash)
            g_object_unref(UnsafeMutableRawPointer(lastFlash))
        }
        adw_toast_set_timeout(toast, 2)
        g_object_ref(UnsafeMutableRawPointer(toast))
        lastFlash = toast
        adw_toast_overlay_add_toast(op(toastOverlay), toast)
        FileHandle.standardOutput.write(Data("FLASH \(text)\n".utf8))
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

    /// A pane changed which conversation it holds. The layout on disk carries the sessions, so a
    /// relaunch restores what the panes were actually showing, and the chat list's merged row
    /// re-reads its members from the same snapshot.
    func paneRebound() {
        splitHost.persist()
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
        Seatbelts.shared.touch(activePane.id)
        refreshChromeForActivePane()
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
        Seatbelts.shared.touch(pane.id)
        if parkedBindings[pane.id] != nil { resume(pane.id) }
    }

    /// The same rule for the regions beside the tree: pressing in the chat list, the file tree or
    /// the terminal is what makes them the keyboard's region, so Tab cycles from where the hand
    /// actually is. Only the region moves — the press keeps whatever it was going to do, and
    /// nothing is given the keyboard that the press did not already give it.
    func regionClicked(_ pane: Pane) {
        guard focused != pane else { return }
        focused = pane
        if pane != .transcript { activePane.dismissCompletion() }
    }

    /// One capture-phase watcher on the window itself decides what a press activated. It has to be
    /// the toplevel: a menu button pops its popover on the press, and a gesture on any widget in
    /// between never sees that sequence at all. Nothing is claimed, so the press still does
    /// whatever it was going to do — this only decides what it was aimed at.
    func installPressRouting(on window: UnsafeMutablePointer<GtkWidget>) {
        let root = UInt(bitPattern: window)
        Gtk.onPressCapture(window) { [weak self] x, y in
            guard let self, let base = UnsafeMutableRawPointer(bitPattern: root) else { return }
            self.pressLanded(x: x, y: y, in: ptr(base))
        }
    }

    func pressLanded(x: Double, y: Double, in window: UnsafeMutablePointer<GtkWidget>) {
        guard !(SheetStack.shared?.isUp ?? false) else { return }
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

    var regionTargets: [(UnsafeMutablePointer<GtkWidget>?, Pane)] {
        [(sidebarColumn, .chats), (terminal.widget, .terminal)]
    }

    /// A preview pane's app or light changed: the title bar follows it when it is the focused pane.
    func previewTitleChanged(_ pane: ChatPane) {
        guard pane === activePane, let title = pane.previewHeaderTitle else { return }
        gtk_label_set_text(op(titleLabel), title)
    }

    func refreshChromeForActivePane() {
        let pane = activePane
        if let title = pane.previewHeaderTitle {
            gtk_label_set_text(op(titleLabel), title)
        } else if let entry = pane.entry {
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

    func workspaceSync(_ pane: ChatPane) {
        terminal.setDirectory(pane.entry?.session.directory)
    }
}
