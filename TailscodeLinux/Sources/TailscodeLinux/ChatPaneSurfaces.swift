import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// An empty pane asks which server rather than captioning itself. The chooser owns the
    /// transcript area until something fills it, and every re-render keeps the person's place.
    func showChooser(_ model: PaneChooser) {
        leaveSlots()
        chooser = model
        renderChooser()
    }

    var chooserShown: Bool { chooser != nil }

    var chooserServerID: String? { chooser?.serverID }

    /// A pane holding an unanswered question or a slot is not an empty pane looking for a chat:
    /// the listing may refresh under it, but nothing may fill it except the person who opened it.
    var isAnswering: Bool {
        chooser != nil || video != nil || page != nil || preview != nil
    }

    /// One line describing the chooser, for the headless driver: the question, then the rows with
    /// the cursor marked.
    var chooserSummary: String? {
        guard let chooser else { return nil }
        let rows = chooser.rows.enumerated().map { index, row in
            let badge = row.badge.map { " (\($0.text))" } ?? ""
            return "\(index == chooser.cursor ? "*" : "")\(row.title)\(badge) — \(row.detail)"
        }
        return "\(chooser.heading) [\(rows.joined(separator: " | "))]"
    }

    /// A fresh listing under an open chooser: the same question, answered with what is true now.
    func restateChooser(
        servers: [PaneChooserServer], entries: [SessionEntry], watching: WatchSummary? = nil
    ) {
        guard let current = chooser else { return }
        var next = current.restated(servers: servers, entries: entries)
        if let watching { next.watchSummary = watching }
        chooser = next
        renderChooser()
    }

    /// The terminal moved: the row that offers its folder says the folder it is in now.
    func followTerminal(_ folder: String?) {
        guard var model = chooser, folder != model.terminalFolder else { return }
        model.setTerminalFolder(folder)
        chooser = model
        renderChooser()
    }

    /// The chooser answers the keyboard before the shortcut table does — but only for the keys it
    /// binds, so `ctrl+w` verbs, `?` and everything else still reach the window.
    func handleChooserChord(_ chord: KeyChord) -> Bool {
        guard var model = chooser, let command = PaneChooser.command(for: chord) else {
            return false
        }
        let (handled, action) = model.handle(command)
        guard handled else { return false }
        chooser = model
        if let action {
            host?.pane(self, chose: action)
        } else {
            renderChooser()
        }
        return true
    }

    func renderChooser() {
        guard let model = chooser else { return }
        Gtk.removeChildren(of: transcriptBox)
        forgetRowWidgets()
        placeholderShown = true
        currentPlaceholder = nil
        pendingReveal = false
        gtk_widget_set_opacity(transcriptBox, 1)
        gtk_box_append(
            ptr(transcriptBox),
            ChooserView.make(model) { [weak self] index in
                Gtk.onMain { [weak self] in self?.activateChooserRow(index) }
            })
    }

    func activateChooserRow(_ index: Int) {
        guard var model = chooser else { return }
        host?.paneClicked(self)
        model.focus(index)
        let action = model.rows.indices.contains(index) ? model.rows[index].action : nil
        guard let action else { return }
        let outcome = model.activate(action)
        chooser = model
        if let outcome {
            host?.pane(self, chose: outcome)
        } else {
            renderChooser()
        }
    }

    static let startersKey = "starters"

    /// A chat with nothing in it asks what it should do, and offers four ways to begin. A starter
    /// fills the composer and sends nothing: the words are the person's to change.
    func showStarters() {
        chooser = nil
        if placeholderShown, currentPlaceholder == Self.startersKey { return }
        currentPlaceholder = Self.startersKey
        Gtk.removeChildren(of: transcriptBox)
        forgetRowWidgets()
        placeholderShown = true
        pendingReveal = false
        gtk_widget_set_opacity(transcriptBox, 1)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(column, "empty-chat")
        gtk_box_append(
            ptr(column), Gtk.label(ChatSuggestion.headline, css: "empty-headline", selectable: false))
        for suggestion in ChatSuggestion.all {
            let words = suggestion.prompt
            let parts = ChatChips.control(
                glyph: suggestion.glyph, word: suggestion.title, tone: .live, label: suggestion.title
            ) { [weak self] in
                Gtk.onMain { [weak self] in self?.addWordsToComposer(words, announcing: false) }
            }
            gtk_widget_set_halign(parts.button, GTK_ALIGN_START)
            gtk_box_append(ptr(column), parts.button)
        }
        gtk_box_append(ptr(transcriptBox), column)
    }

    static let welcomeKey = "welcome"

    /// The pane with no conversation and no server to hold one draws Core's welcome rather than a
    /// blank page: the title, the sentence, the one step standing in the way and the buttons that
    /// open the checklist. A pane that holds a chat or is asking which server keeps what it has.
    func showWelcome(_ welcome: EmptyWelcome, onAction: @escaping @Sendable (EmptyWelcome.Intent) -> Void) {
        guard sessionID == nil, chooser == nil, video == nil, page == nil, preview == nil else { return }
        if currentPlaceholder == Self.welcomeKey, shownWelcome == welcome { return }
        shownWelcome = welcome
        currentPlaceholder = Self.welcomeKey
        Gtk.removeChildren(of: transcriptBox)
        forgetRowWidgets()
        placeholderShown = true
        pendingReveal = false
        gtk_widget_set_opacity(transcriptBox, 1)
        gtk_box_append(ptr(transcriptBox), Self.welcomeView(welcome, onAction: onAction))
    }

    static func welcomeView(
        _ welcome: EmptyWelcome, onAction: @escaping @Sendable (EmptyWelcome.Intent) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        Gtk.addClass(column, "empty-chat")
        gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(column), Gtk.label(welcome.title, css: "empty-headline", selectable: false))
        gtk_box_append(ptr(column), welcomeText(welcome.detail, css: "dim"))
        gtk_box_append(ptr(column), welcomeStep(welcome.step, onAction: onAction))
        gtk_box_append(ptr(column), welcomeButtons(welcome, onAction: onAction))
        return column
    }

    func clearWelcome() {
        guard currentPlaceholder == Self.welcomeKey else { return }
        currentPlaceholder = nil
        shownWelcome = nil
        Gtk.removeChildren(of: transcriptBox)
    }

    var welcomeShown: Bool { currentPlaceholder == Self.welcomeKey }

    static func welcomeText(_ text: String, css: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: css, wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(label), 60)
        return label
    }

    static func welcomeStep(
        _ step: EmptyWelcome.Step, onAction: @escaping @Sendable (EmptyWelcome.Intent) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.groupBox(
            GTK_ORIENTATION_VERTICAL, spacing: 6, spoken: "\(step.title). \(step.detail)")
        Gtk.addClass(card, "card")
        Gtk.margins(card, 12)
        gtk_box_append(ptr(card), Gtk.label(step.title, css: "row-title", selectable: false))
        gtk_box_append(ptr(card), welcomeText(step.detail, css: "row-detail"))
        if let fix = step.fix {
            let button = welcomeButton(fix, css: ["flat"], onAction: onAction)
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            gtk_box_append(ptr(card), button)
        }
        return card
    }

    static func welcomeButtons(
        _ welcome: EmptyWelcome, onAction: @escaping @Sendable (EmptyWelcome.Intent) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(row), welcomeButton(welcome.primary, css: ["suggested-action"], onAction: onAction))
        for action in welcome.secondary {
            gtk_box_append(ptr(row), welcomeButton(action, css: ["flat"], onAction: onAction))
        }
        return row
    }

    static func welcomeButton(
        _ action: EmptyWelcome.Action, css: [String],
        onAction: @escaping @Sendable (EmptyWelcome.Intent) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let intent = action.intent
        let button = Gtk.button(action.title, css: css) { Gtk.onMain { onAction(intent) } }
        gtk_widget_set_tooltip_text(button, action.help)
        return button
    }

    func showPlaceholder(_ text: String) {
        chooser = nil
        if placeholderShown, currentPlaceholder == text { return }
        currentPlaceholder = text
        openTimer.note("placeholder \(text)")
        Gtk.removeChildren(of: transcriptBox)
        forgetRowWidgets()
        placeholderShown = true
        pendingReveal = false
        gtk_widget_set_opacity(transcriptBox, 1)
        let label = Gtk.label(text, css: "dim", selectable: false)
        Gtk.margins(label, top: 24, bottom: 24)
        gtk_box_append(ptr(transcriptBox), label)
    }

    /// A sentence for a screen reader, spoken once and only for the pane the reader is working
    /// in: a turn ending, an approval and a question are news nobody sees if they are not looking
    /// at the screen. A toolkit older than the call has nothing to say it with, and says nothing.
    func announce(_ words: String) {
        guard tailscode_can_announce() != 0, host?.activePane === self, !words.isEmpty else {
            return
        }
        tailscode_accessible_announce(root, words, 0)
    }

    func setFindShown(_ shown: Bool) {
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

    var findShown: Bool { gtk_widget_get_visible(findBar) != 0 }

    func findQuery() -> String {
        guard let raw = gtk_editable_get_text(op(findEntry)) else { return "" }
        return String(cString: raw)
    }

    func runFind(retarget: Bool) {
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

    func stepFind(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        findCursor = ((findCursor + delta) % count + count) % count
        updateFindCount()
        applyFindHighlight(scroll: true)
    }

    func updateFindCount() {
        gtk_label_set_text(
            op(findCountLabel),
            findMatches.isEmpty
                ? Localized.text("No matches") : "\(findCursor + 1)/\(findMatches.count)")
    }

    /// Marks the current match, and on an explicit jump scrolls it to the upper third so the eye
    /// lands on the hit rather than hunting for it.
    func applyFindHighlight(scroll: Bool) {
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

    func clearFindHighlight() {
        guard highlightedRow != 0,
            let raw = UnsafeMutableRawPointer(bitPattern: highlightedRow)
        else { return }
        gtk_widget_remove_css_class(ptr(raw) as UnsafeMutablePointer<GtkWidget>, "find-hit")
        highlightedRow = 0
    }

    /// The cheatsheet is generated from the registry, so it always tells the truth — overrides
    /// included. Two columns, because forty rows in one column is a scroll, not a glance.
    func rebuildHelpOverlay() {
        guard let shortcuts = host?.shortcuts else { return }
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

    func setHelp(_ shown: Bool) {
        helpShown = shown
        gtk_widget_set_visible(helpOverlay, shown ? 1 : 0)
    }

    func popupCommandPalette() {
        if let commandButton { gtk_menu_button_popup(op(commandButton)) }
    }

    func focusComposer() {
        gtk_widget_grab_focus(entryView)
    }

    /// Puts a quote of what the agent said into the box at the caret and leaves the caret under
    /// it, in insert mode: nothing is sent, and the reply goes out through the ordinary send.
    func replyWithQuote(_ quote: String) {
        editor.insertReplyQuote(quote)
        updateVimBadge()
    }

    /// The row under a turn's brain, which is its answer, put at the top of the window.
    func revealAnswer(afterBrain turnID: String) {
        guard let scroller = transcriptScroller, let canvas = canvasBox,
            gtk_scrolled_window_get_vadjustment(op(scroller)) != nil
        else { return }
        var found: Int?
        for (index, row) in renderedRows.enumerated() {
            if case .brain(let brain) = row.kind, brain.turn.id == turnID {
                found = index
                break
            }
        }
        guard let found else { return }
        let target = min(found + 1, rowWidgets.count - 1)
        guard target >= 0, let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[target]) else { return }
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        guard tailscode_widget_bounds_in(ptr(raw), canvas, &x, &y, &width, &height) != 0 else { return }
        followsBottom = false
        adjust { _ in y - 8 }
    }

    /// A scrolled window conjures its own viewport, and a conjured one scrolls to whatever takes
    /// focus. Every row in a transcript is a button: a rebuild that destroys the row holding focus
    /// — which is every arrival of a running turn — and the close of a sibling pane both re-home
    /// focus inside this list, and the viewport answered by animating the transcript to the top
    /// under a reader who was mid-conversation. The sidebar paid this debt already
    /// (`makeSidebarViewport`); nothing had paid it here. What genuinely wants the transcript to
    /// move — find, a disclosure opening — scrolls by hand and is unaffected.
    func makeTranscriptViewport(
        _ child: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkWidget> {
        let viewport = gtk_viewport_new(nil, nil)!
        gtk_viewport_set_scroll_to_focus(op(viewport), 0)
        gtk_viewport_set_child(op(viewport), child)
        return viewport
    }

    /// The transcript box is a plain `GtkBox` and cannot hold focus, so grabbing it moved nothing
    /// and `ctrl+w` left the keyboard wherever it happened to be — often on a disclosure inside
    /// the transcript it had just left. The composer is what a person types into when a pane takes
    /// the keyboard, so that is what takes it.
    /// A pane that is asking which server, and which folder, owns the keyboard: its keys are the
    /// answers (↑↓, j/k, 1–9, Enter), so the composer must not hold the focus, or every one of them
    /// would be typed into a message nobody started.
    func focusTranscript() {
        guard chooser != nil, let scroller = transcriptScroller else {
            focusComposer()
            return
        }
        gtk_widget_grab_focus(scroller)
    }

    /// Everything the settings window can change that is not a colour, applied to this pane.
    /// Compact and dense change what a row *is*, so the transcript is rebuilt rather than
    /// restyled.
    func applyLayoutPreferences() {
        syncBrainSettings()
        editor.applyPreferences()
        if let canvasBox {
            gtk_box_set_spacing(ptr(canvasBox), Int32(TranscriptGaps.metrics.proseToFurnitureGap))
        }
        windowLimit = max(windowLimit, Preferences.transcriptWindow)
        updateVimBadge()
        queueLaneFit()
        tearDownAllRows()
        placeholderShown = true
        rebuildTranscriptRows()
    }

    func retheme() {
        preview?.retheme()
        syncBrainSettings()
        rebuildTranscriptRows()
        for view in brains.liveViews { view.rethemed() }
    }

    /// Hands the row builder what the brains need to be built with: the style, the head the person
    /// opened, the turns that list their rows and the palette the stage is painted in.
    func syncBrainSettings() {
        rowBuilder.setBrains(brains.settings())
    }

    /// A choice about a brain changed: build the rows again with it. A pane showing a scripted
    /// conversation has no stream to rebuild from, so its rows are built where it stands.
    func brainSettingsChanged() {
        syncBrainSettings()
        guard let state = lastState else { return }
        if lease != nil {
            feed.rebuild(state)
        } else if !isParked {
            apply(state: state, rows: rowBuilder.rows(state: state))
        }
    }

    /// What the conversation says about the head being written, as Core's brain model reads it.
    func brainContext(activity: ActivityKind?, fill: ContextFill?) -> NeuralBrainContext {
        NeuralBrainContext(
            activity: activity, fill: fill, providerID: activeSelection?.providerID,
            effortOptions: effortOptions(), effort: resolvedEffort())
    }

    /// A Task node, opened: the card of that call is expanded in the transcript and brought into
    /// view, which is what pressing its own row does.
    func openSubagentCard(_ key: String) {
        context.expanded.set(key, open: true)
        followsBottom = false
        if let index = renderedRows.firstIndex(where: { $0.key == key }),
            index < rowWidgets.count
        {
            rebuildRow(at: index)
            if let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]) {
                revealDisclosure(UInt(bitPattern: raw))
            }
        }
    }

    /// Rows for the current state, folded off the GLib main context — a ten-thousand-message
    /// conversation must never be re-parsed where the frame clock lives.
    func rebuildTranscriptRows() {
        guard let state = lastState else { return }
        if lease == nil, !isParked, entry == nil || isScripted {
            apply(state: state, rows: rowBuilder.rows(state: state))
        } else {
            feed.rebuild(state)
        }
    }

    /// A pane showing a conversation the harness wrote, which has no stream behind it.
    var isScripted: Bool { brains.sessionKey == "demo" || brains.sessionKey == "live" }

    /// A fire-and-forget fetch for the open conversation, ended with it.
    @discardableResult
    func track(_ task: Task<Void, Never>) -> Task<Void, Never> {
        chatLife.add { task.cancel() }
        return task
    }
}
