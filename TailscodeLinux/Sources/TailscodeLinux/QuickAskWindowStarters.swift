import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension QuickAskWindow {
    /// The far end of the foot teaches the one thing nothing inside the card can: that it opens
    /// without the app in front.
    static func chordNote() -> String {
        let state = Summon.shared.state
        guard state.isLive, let chord = state.chord else { return "" }
        return Localized.text("%@ from anywhere", chord.display(on: .linux))
    }

    /// The send arrow is lit by the same rule that lets Enter through, so the one control and the
    /// one key can never disagree about whether there is a question yet.
    func refreshSend() {
        let ready = QuickAskComposition.canSend(
            text: editor.text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments.count)
        gtk_widget_set_sensitive(send, ready && !asking ? 1 : 0)
        if ready { Gtk.addClass(send, "ask-send-ready") } else {
            gtk_widget_remove_css_class(send, "ask-send-ready")
        }
    }

    /// How hard the machine is asked to think, which is half of what a question costs and the
    /// other half of the aim: the levels are the picked model's own where the catalog names them
    /// and the agent's otherwise, and a pick is the quick ask's own memory on that server rather
    /// than the machine's — the same bargain the model chip strikes.
    func effortOptions() -> [String] {
        let server = targetServer
        return ModelEffort.options(
            models: ModelCatalogStore.cached(server.id),
            selection: QuickAskDefaults.model(forProfileID: server.id),
            agentOptions: agentEfforts[server.id] ?? [])
    }

    /// A model whose levels are its own can make the level already picked unrunnable. The aim
    /// then hands the choice back to the machine rather than keeping a word the question could
    /// not be asked with — a chip may never name a level the send would not carry.
    func dropUnofferedEffort(on profileID: String, options: [String]) {
        guard let chosen = QuickAskDefaults.effort(forProfileID: profileID), !chosen.isEmpty,
            !options.contains(chosen)
        else { return }
        QuickAskDefaults.recordEffort(nil, forProfileID: profileID)
    }

    /// A level set from the open dial leaves the focus where it is — the dial stays up for the
    /// next nudge — while a level set any other way hands the caret back to the question.
    func setEffort(_ level: String?, on profileID: String, refocus: Bool = true) {
        QuickAskDefaults.recordEffort(level, forProfileID: profileID)
        refreshTarget()
        if refocus { editor.focus() }
        AppLog.write(.ui, "ASK effort=\(level ?? "server")")
    }

    /// Vim is the composer's, so it is the quick ask's: the same engine, the same badge, the same
    /// rule that a mode is worn rather than remembered. Escape leaves insert before it closes the
    /// window, because a hand that pressed it meant the mode it was in.
    func vimKey(keyval: UInt32, state: UInt32) -> Bool? {
        guard Preferences.vimComposer, !asking, editor.hasFocus(in: window) else { return nil }
        let control = state & KeyChord.controlMask != 0
        let key = VimKey(
            character: Keymap.scalar(keyval),
            isEscape: keyval == Keymap.escape,
            isEnter: keyval == Keymap.enter || keyval == Keymap.keypadEnter,
            isBackspace: keyval == Keymap.backspace,
            control: control)
        if editor.vim.mode == .insert {
            guard key.isEscape || (control && Keymap.scalar(keyval) == "[") else { return nil }
            applyVim(VimKey(isEscape: true))
            return true
        }
        if key.isEscape { return nil }
        guard !control, state & KeyChord.altMask == 0 else { return nil }
        applyVim(key)
        return true
    }

    func applyVim(_ key: VimKey) {
        let outcome = editor.vim.handle(key, text: editor.text, cursor: editor.cursor)
        switch outcome {
        case .handled: editor.write(editor.vim.document, selection: editor.vim.selection)
        case .passThrough: break
        case .send: submit()
        }
        updateVimBadge()
    }

    func updateVimBadge() {
        editor.refreshMode()
        guard Preferences.vimComposer else {
            gtk_widget_set_visible(vimBadge, 0)
            return
        }
        gtk_widget_set_visible(vimBadge, 1)
        gtk_label_set_text(op(vimBadge), editor.vim.mode.label)
        gtk_widget_remove_css_class(vimBadge, "vim-badge-visual")
        gtk_widget_remove_css_class(vimBadge, "vim-badge-insert")
        switch editor.vim.mode {
        case .insert: Gtk.addClass(vimBadge, "vim-badge-insert")
        case .visual, .visualLine: Gtk.addClass(vimBadge, "vim-badge-visual")
        case .normal: break
        }
    }

    /// The powers are visibly on before the question is sent: the aim's own effort, or the word
    /// typed into the draft, lights the same rainbow the chat's box wears.
    func refreshAura() {
        editor.setAura(
            effort: QuickAskDefaults.effort(forProfileID: targetServer.id), inFlight: false)
    }

    /// The line under the box is for what just happened — a refusal, a notice, a level that moved —
    /// and it is gone when there is nothing to say, so the card never carries an empty row.
    func setHint(_ text: String) {
        gtk_label_set_text(op(hint), text)
        gtk_widget_set_visible(hint, text.isEmpty ? 0 : 1)
    }

    /// A notice is about the moment it was said in; the next keystroke is a new moment.
    func clearHint() {
        guard !asking, gtk_widget_get_visible(hint) != 0 else { return }
        setHint("")
    }

    /// Words or things in the box, and no template waiting for a chat: the list is then the verbs
    /// for what was typed rather than everything that can be done.
    var isTyping: Bool {
        gathering?.awaiting != .session && !(editor.text.isEmpty && attachments.isEmpty)
    }

    /// Whether an arrow is the list's rather than the box's. With the box empty every arrow walks
    /// the list; with words in it ↓ steps into the list only from the box's last line, so a
    /// question of several lines is still walked line by line, and ↑ is the list's only while a
    /// line of it is held — from the first line it hands the keyboard back to the box.
    func walksList(down: Bool) -> Bool {
        guard isTyping else { return true }
        if menuCursor.index != nil { return true }
        guard down else { return false }
        let text = editor.text
        let caret = text.index(text.startIndex, offsetBy: min(editor.cursor, text.count))
        return !text[caret...].contains("\n")
    }

    /// The card below the question: what was just copied with what can be done with it, then
    /// Core's sections — the person's actions, what is waiting for later, what was asked here — or,
    /// while `{session}` waits, the chats to hand on. A redraw keeps the keyboard on the line it
    /// was on.
    func renderStarters() {
        let selected = menuCursor.index.flatMap {
            menuItems.indices.contains($0) ? menuItems[$0].id : nil
        }
        Gtk.removeChildren(of: starters)
        menuRows = []
        typingShown = isTyping
        let sections: [QuickAskMenuSection]
        if gathering?.awaiting == .session {
            sections = QuickAskMenu.sessions(QuickAskSessionReference.candidates(among: recents))
        } else if isTyping {
            offered = QuickAskStarters.offered(for: abilities, surface: surface)
            sections = QuickAskMenu.verbs(offered, aimWords: { [weak self] aim in self?.aimBadge(aim) })
        } else {
            offered = QuickAskStarters.offered(for: abilities, surface: surface)
            copied = copiedOffer.flatMap(reading)
            sections = QuickAskMenu.sections(
                copied: copied, starters: offered, later: QuickAskLaterStore.all(),
                recents: QuickAskRecents.asks(among: recents, profileID: targetServer.id),
                aimWords: { [weak self] aim in self?.aimBadge(aim) })
        }
        menuItems = QuickAskMenu.items(sections)
        picks = menuItems.filter { $0.digit != nil }
        for section in sections {
            gtk_box_append(ptr(starters), section.isCopied ? copiedHeader(section) : self.section(section.title))
            for item in section.items {
                let row = menuRow(item)
                menuRows.append(row)
                gtk_box_append(ptr(starters), row)
            }
            if section.id == "later" {
                let reach = Gtk.label(
                    QuickAskLaterWords.reach, css: "qa-note", wrap: true, selectable: false)
                gtk_label_set_xalign(op(reach), 0)
                gtk_box_append(ptr(starters), reach)
            }
        }
        let unread = QuickAskActions.unreadable
        if unread > 0 {
            let note = Gtk.label(
                unread == 1
                    ? Localized.text("1 entry in quick-actions.json could not be read")
                    : Localized.text("%@ entries in quick-actions.json could not be read", "\(unread)"),
                css: "qa-note", wrap: true, selectable: false)
            gtk_label_set_xalign(op(note), 0)
            gtk_box_append(ptr(starters), note)
        }
        menuCursor.follow(id: selected, in: menuItems)
        paintSelection()
        renderFooter()
        refreshStarterVisibility()
    }

    /// Where an action asks when it asks somewhere of its own, said as short as it can be: the
    /// model's word where it names one, the machine's name otherwise.
    func aimBadge(_ aim: QuickAskActionAim) -> String? {
        let profileID = aim.profileID(among: servers)
        if let selection = aim.selection {
            return ModelBadge.word(
                for: selection, in: ModelCatalogStore.cached(profileID ?? targetServer.id))
        }
        return servers.first { $0.id == profileID }?.name ?? aim.server
    }

    /// One line: the glyph in its tinted square, the title, its quieter words, where it asks or
    /// when, and the digit that picks it. A press runs it, a right press offers what can be done
    /// with an action.
    func menuRow(_ item: QuickAskMenuItem) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "qa-row")
        if case .newAction = item.kind { Gtk.addClass(button, "qa-row-quiet") }
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        gtk_box_append(ptr(line), glyphTile(item.glyph))
        let title = Gtk.label(item.title, css: "qa-row-title", selectable: false)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(line), title)
        let detail = Gtk.label(item.detail, css: "qa-row-detail", selectable: false)
        gtk_label_set_ellipsize(op(detail), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(detail), 0)
        gtk_widget_set_hexpand(detail, 1)
        gtk_box_append(ptr(line), detail)
        if let badge = item.badge, !badge.isEmpty {
            let pill = whole(Gtk.label(badge, css: "qa-row-badge", selectable: false))
            gtk_label_set_ellipsize(op(pill), PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_max_width_chars(op(pill), 22)
            gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
            gtk_widget_set_tooltip_text(pill, badge)
            gtk_box_append(ptr(line), pill)
        }
        if let digit = item.digit {
            let cap = whole(Gtk.label("\(digit)", css: "ask-keycap", selectable: false))
            gtk_widget_set_valign(cap, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), cap)
        }
        gtk_button_set_child(ptr(button), line)
        if !item.detail.isEmpty { gtk_widget_set_tooltip_text(button, item.detail) }
        let id = item.id
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
            Gtk.onMain { QuickAskWindow.open?.activate(id: id) }
        }
        let hold = Gtk.WeakWidget(button)
        Gtk.onRightClick(button) { x, y in
            Gtk.onMain {
                guard let open = QuickAskWindow.open, let held = hold.widget,
                    let item = open.menuItems.first(where: { $0.id == id })
                else { return }
                open.showMenu(for: item, on: held, x: x, y: y)
            }
        }
        return button
    }

    /// A glyph in a square of its own size, whatever font the character falls back to: a symbol
    /// from a taller face would otherwise make its line taller than its neighbours.
    func glyphTile(_ glyph: String) -> UnsafeMutablePointer<GtkWidget> {
        let tile = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(tile, "qa-row-glyph")
        gtk_widget_set_size_request(tile, 26, 26)
        gtk_widget_set_overflow(tile, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_valign(tile, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(tile, GTK_ALIGN_START)
        gtk_widget_set_hexpand(tile, 0)
        let mark = whole(Gtk.label(glyph, css: "qa-row-glyph-mark", selectable: false))
        gtk_widget_set_size_request(mark, 26, 26)
        gtk_label_set_xalign(op(mark), 0.5)
        gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(tile), mark)
        return tile
    }

    /// The selected line wears the accent and is scrolled into the visible part of the list.
    func paintSelection() {
        for (index, row) in menuRows.enumerated() {
            if index == menuCursor.index {
                Gtk.addClass(row, "qa-row-selected")
            } else {
                gtk_widget_remove_css_class(row, "qa-row-selected")
            }
        }
        guard let index = menuCursor.index, menuRows.indices.contains(index),
            let box = Gtk.bounds(of: menuRows[index], in: starters),
            let adjustment = gtk_scrolled_window_get_vadjustment(op(body))
        else { return }
        let top = gtk_adjustment_get_value(adjustment)
        let page = gtk_adjustment_get_page_size(adjustment)
        if box.y < top {
            gtk_adjustment_set_value(adjustment, max(0, box.y - 28))
        } else if box.y + box.height > top + page {
            gtk_adjustment_set_value(adjustment, box.y + box.height - page + 8)
        }
    }

    func moveSelection(by delta: Int) {
        guard !asking else { return }
        menuCursor.move(by: delta, count: menuItems.count)
        paintSelection()
    }

    func clearSelection() {
        menuCursor.clear()
        paintSelection()
    }

    func runSelected() {
        guard let index = menuCursor.index, menuItems.indices.contains(index) else { return }
        activate(id: menuItems[index].id)
    }

    /// A line pressed, picked by its digit or run with Enter: an action runs, a waiting question
    /// offers to be asked now or removed, a past question opens, a chat is handed on.
    func activate(id: String) {
        guard !asking, let index = menuItems.firstIndex(where: { $0.id == id }) else { return }
        let item = menuItems[index]
        switch item.kind {
        case .errand(let errand):
            menuCursor.clear()
            pickErrand(errand)
        case .starter(let starter):
            guard gathering == nil else { return }
            menuCursor.clear()
            if isTyping {
                applyVerb(starter)
                return
            }
            AppLog.write(.ui, "ASK starter=\(starter.id)")
            run(starter.action, copied: false)
        case .later:
            guard menuRows.indices.contains(index) else { return }
            let row = menuRows[index]
            showMenu(
                for: item, on: row, x: Double(gtk_widget_get_width(row)) / 2,
                y: Double(gtk_widget_get_height(row)))
        case .recent(let entry):
            resume(entry)
        case .session(let entry):
            menuCursor.clear()
            pickSession(entry)
        case .newAction:
            newAction()
        }
    }

    func showMenu(
        for item: QuickAskMenuItem, on widget: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double
    ) {
        switch item.kind {
        case .starter(let starter): showActionMenu(for: starter.action, on: widget, x: x, y: y)
        case .errand(let errand): showActionMenu(for: errand.action, on: widget, x: x, y: y)
        case .newAction: showActionMenu(for: nil, on: widget, x: x, y: y)
        case .later(let later):
            let id = later.id
            Gtk.contextMenu(
                on: widget, x: x, y: y,
                rows: [
                    (Localized.text("Ask now"), nil, { Gtk.onMain { QuickAskLaterStore.askNow(id: id) } }),
                    (Localized.text("Remove"), nil, { Gtk.onMain { QuickAskLaterStore.remove(id: id) } }),
                ])
        case .recent, .session: break
        }
    }

    /// The list is redrawn as the verbs, or back as everything, only when the box crosses between
    /// empty and not — never on every keystroke.
    func renderTyping() {
        guard isTyping != typingShown else { return }
        menuCursor.clear()
        renderStarters()
    }

    /// The words typed so far, handed to an action as what it is about.
    func applyVerb(_ starter: QuickAskStarter) {
        guard !asking, gathering == nil else { return }
        let typed = editor.text
        AppLog.write(.ui, "ASK verb=\(starter.id)")
        write("")
        run(starter.action, copied: false, typed: typed)
    }

    /// One line of keys for the box as it is, and on its far end the chord that opens the card
    /// from anywhere.
    func renderFooter() {
        Gtk.removeChildren(of: footKeys)
        let keys = QuickAskFooter.keys(
            platform: .linux, typing: isTyping,
            party: QuickAskParty.targets(partyInputs().cards).count > 1,
            screen: surface.screen && abilities.vision, verbs: picks.count)
            + [QuickAskFooter.Key(keys: "esc", word: Localized.text("close"))]
        for key in keys {
            let pair = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 5)
            gtk_box_append(ptr(pair), whole(Gtk.label(key.keys, css: "qa-foot-key", selectable: false)))
            gtk_box_append(ptr(pair), whole(Gtk.label(key.word, css: "qa-foot-word", selectable: false)))
            gtk_box_append(ptr(footKeys), pair)
        }
        gtk_label_set_text(op(chord), Self.chordNote())
    }


    /// What was copied heads its own section: what it is in the accent, a glimpse of it, and the
    /// way to say it is not what this question is about — remembered, so the same thing is not
    /// offered again on the next summon.
    func copiedHeader(_ section: QuickAskMenuSection) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(column, "qa-copied")
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let headline = Gtk.label(section.title, css: "qa-copied-head", selectable: false)
        gtk_label_set_ellipsize(op(headline), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(headline), 0)
        gtk_widget_set_hexpand(headline, 1)
        gtk_box_append(ptr(head), headline)
        let aside = Gtk.button("✕", css: ["flat", "ask-copied-close"]) {
            Gtk.onMain { QuickAskWindow.open?.setCopiedAside() }
        }
        gtk_widget_set_tooltip_text(aside, QuickAskWords.setAside)
        gtk_box_append(ptr(head), aside)
        gtk_box_append(ptr(column), head)
        if let note = section.note {
            let glimpse = Gtk.label(note, css: "qa-copied-preview", wrap: true, selectable: false)
            gtk_label_set_lines(op(glimpse), 2)
            gtk_label_set_ellipsize(op(glimpse), PANGO_ELLIPSIZE_END)
            gtk_label_set_xalign(op(glimpse), 0)
            gtk_box_append(ptr(column), glimpse)
        }
        return column
    }

    func section(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "qa-section", selectable: false)
        gtk_label_set_xalign(op(label), 0)
        return label
    }

    /// A label that is never shortened. Every label in this app ellipsizes by default, which is
    /// right for a title that has to share a row with something bigger and wrong for the three
    /// words that say which key does this — "alt+…" is not a shortcut anybody can press.
    func whole(_ label: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>
    {
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_hexpand(label, 0)
        return label
    }

    /// The card for what the clipboard holds, read against the aim in force: a picture copied for
    /// a model that cannot see one is no card at all.
    func reading(of offer: ClipboardOffer) -> QuickAskCopied? {
        guard let held = QuickAskClipboard.holding(of: offer) else { return nil }
        return QuickAskClipboard.reading(
            holding: held.holding, fingerprint: held.fingerprint, abilities: abilities,
            surface: surface)
    }

    /// Reads the clipboard whole and redraws the empty window only when what it offers changed,
    /// so the second read the activation triggers costs nothing on screen.
    func readCopied() {
        guard !asking else { return }
        Gtk.readClipboard { [weak self] offer in
            Gtk.onMain { [weak self] in
                guard let self, !self.asking else { return }
                let before = self.copied?.fingerprint
                self.copiedOffer = offer.isEmpty ? nil : offer
                let after = self.copiedOffer.flatMap(self.reading)?.fingerprint
                guard before != after else { return }
                self.renderStarters()
            }
        }
    }

    /// An errand is the first half of a sentence, the same as a starter: the instruction lands in
    /// the entry and the clipboard follows it through the paste the entry already does, so a page
    /// of log still becomes the file it already is, and the person sends it.
    func pickErrand(_ errand: QuickAskClipboardErrand) {
        guard !asking, gathering == nil, editor.text.isEmpty, attachments.isEmpty, copied != nil,
            copiedOffer != nil
        else { return }
        run(errand.action, copied: true)
        AppLog.write(.ui, "ASK copied=\(errand.id)")
    }

    func setCopiedAside() {
        guard let copied else { return }
        QuickAskClipboardMemory.settle(copied.fingerprint)
        renderStarters()
        editor.focus()
        AppLog.write(.ui, "ASK copied set aside")
    }

    func pick(at index: Int) {
        guard picks.indices.contains(index) else { return }
        activate(id: picks[index].id)
    }

    /// The list stays where it is whatever the box holds — the card never changes size under the
    /// person — and only goes quiet while a question is on its way.
    func refreshStarterVisibility() {
        gtk_widget_set_sensitive(body, asking ? 0 : 1)
    }

    /// A starter is the first half of a sentence, never a question the app asked on somebody's
    /// behalf: the words land in the entry with the caret where the action left room, after
    /// whatever its template fetches — a chooser, a drag over the screen, a chat to hand on.
    func pickStarter(at index: Int) {
        guard offered.indices.contains(index) else { return }
        activate(id: "action:" + offered[index].id)
    }

    func resume(_ entry: SessionEntry) {
        guard !asking else { return }
        let onResume = onResume
        let session = entry
        close()
        onResume(session)
    }
}
