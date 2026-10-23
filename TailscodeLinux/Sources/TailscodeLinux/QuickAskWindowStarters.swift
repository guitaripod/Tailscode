import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension QuickAskWindow {
    /// What the keys do, said once under the box. Which key sends is the person's own setting, so
    /// the line reads it rather than asserting Enter — and it always names the one that writes a
    /// line break, because a box that grows is worth nothing to somebody who does not know how to
    /// put a paragraph in it. The picks wear only their digit, so the modifier is said here once.
    static func keysHint(machines: Int) -> String {
        let sending =
            Preferences.sendOnReturn
            ? Localized.text("Enter sends · shift+enter for a new line")
            : Localized.text("Ctrl+enter sends · enter for a new line")
        let picking = Localized.text(" · alt+number picks")
        guard machines > 1 else {
            return sending + picking + Localized.text(" · esc closes")
        }
        return sending + Localized.text(" · tab moves the machine") + picking
            + Localized.text(" · esc closes")
    }

    /// The bar's second line teaches the thing a person cannot discover from inside this window:
    /// that it can be opened without the app in front of them. The machine it will ask is already
    /// the chip beside it, so saying that here too would spend the line on something visible.
    static func subtitle() -> String {
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

    func setHint(_ text: String) {
        gtk_label_set_text(op(hint), text)
    }

    /// What a number chord picks, in the order the picks are drawn: the copied thing's errands
    /// first, because a summon with something new on the clipboard is most likely about it, and the
    /// starters after them.
    enum Pick {
        case errand(QuickAskClipboardErrand)
        case starter(Int)
    }

    /// The empty window's argument for itself: what was just copied and what can be done with it,
    /// what this thing can be asked to do, offered against what the aim can take, and the last few
    /// questions asked here. It gets out of the way the moment there is a question and comes back
    /// if the entry is emptied again.
    func renderStarters() {
        Gtk.removeChildren(of: starters)
        offered = QuickAskStarters.offered(for: abilities)
        copied = copiedOffer.flatMap(reading)
        let errands = copied?.errands ?? []
        picks = errands.map(Pick.errand) + offered.indices.map(Pick.starter)
        if let copied { gtk_box_append(ptr(starters), renderCopied(copied)) }
        gtk_box_append(ptr(starters), section(QuickAskWords.offer))
        let grid = gtk_grid_new()!
        gtk_grid_set_column_homogeneous(ptr(grid), 1)
        gtk_grid_set_row_homogeneous(ptr(grid), 1)
        gtk_grid_set_row_spacing(ptr(grid), 6)
        gtk_grid_set_column_spacing(ptr(grid), 6)
        for (index, starter) in offered.enumerated() {
            let tile = self.tile(starter, keycap: Self.keycap(at: errands.count + index)) {
                [weak self] in
                Gtk.onMain { [weak self] in self?.pickStarter(at: index) }
            }
            gtk_grid_attach(ptr(grid), tile, Int32(index % 2), Int32(index / 2), 1, 1)
        }
        gtk_box_append(ptr(starters), grid)
        let asked = QuickAskRecents.asks(among: recents, profileID: targetServer.id)
        guard !asked.isEmpty else {
            refreshStarterVisibility()
            return
        }
        gtk_box_append(ptr(starters), section(QuickAskWords.asked))
        for entry in asked {
            let title = AgentSession.isPlaceholderTitle(entry.session.title)
                ? QuickAskWords.untitled : entry.session.title
            gtk_box_append(
                ptr(starters),
                recentRow(
                    title: title,
                    age: Localized.text(
                        "asked %@ ago", SessionRowModel.age(of: entry.session.updatedAt))
                ) { [weak self] in
                    Gtk.onMain { [weak self] in self?.resume(entry) }
                })
        }
        refreshStarterVisibility()
    }

    /// The number a pick answers to, worn on the pick itself. Only the digit: the footer of every
    /// desktop surface already says which modifier, and nine copies of "alt+" are nine copies of
    /// the same fact.
    static func keycap(at index: Int) -> String? {
        index < 9 ? "\(index + 1)" : nil
    }

    /// What was copied, as one card above the starters: what it is, a glimpse of it, and a chip per
    /// errand. The close button is how a person says the clipboard is not what this question is
    /// about, and it is remembered, so the same thing is not offered again on the next summon.
    func renderCopied(_ copied: QuickAskCopied) -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "ask-copied")
        let head = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let headline = whole(Gtk.label(copied.headline, css: "ask-copied-head", selectable: false))
        gtk_widget_set_hexpand(headline, 1)
        gtk_label_set_xalign(op(headline), 0)
        gtk_box_append(ptr(head), headline)
        let aside = Gtk.button("✕", css: ["flat", "ask-copied-close"]) {
            Gtk.onMain { QuickAskWindow.open?.setCopiedAside() }
        }
        gtk_widget_set_tooltip_text(aside, QuickAskWords.setAside)
        gtk_box_append(ptr(head), aside)
        gtk_box_append(ptr(card), head)
        if let preview = copied.preview {
            let glimpse = Gtk.label(preview, css: "ask-copied-preview", wrap: true, selectable: false)
            gtk_label_set_lines(op(glimpse), 2)
            gtk_label_set_ellipsize(op(glimpse), PANGO_ELLIPSIZE_END)
            gtk_label_set_xalign(op(glimpse), 0)
            gtk_box_append(ptr(card), glimpse)
        }
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        for (index, errand) in copied.errands.enumerated() {
            gtk_box_append(
                ptr(row),
                errandChip(errand, keycap: Self.keycap(at: index)) {
                    Gtk.onMain { QuickAskWindow.open?.pickErrand(errand) }
                })
        }
        gtk_box_append(ptr(card), row)
        return card
    }

    func errandChip(
        _ errand: QuickAskClipboardErrand, keycap: String?,
        onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "ask-errand")
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_append(ptr(line), whole(Gtk.label(errand.glyph, css: "ask-errand-glyph", selectable: false)))
        gtk_box_append(ptr(line), whole(Gtk.label(errand.title, css: "ask-errand-title", selectable: false)))
        if let keycap {
            gtk_box_append(ptr(line), whole(Gtk.label(keycap, css: "ask-keycap", selectable: false)))
        }
        gtk_button_set_child(ptr(button), line)
        gtk_widget_set_tooltip_text(button, errand.prompt)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        return button
    }

    func section(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "ask-section", selectable: false)
        gtk_label_set_xalign(op(label), 0)
        return label
    }

    /// One starter as a tile of a two-column grid: the glyph set in a tinted square so the column
    /// of them reads as a set of things to do, the title over its quieter detail, and the number
    /// that picks it in the corner. Two columns hold the whole catalog in half the height a list
    /// of rows took, which is the difference between a window that arrives over the work and one
    /// that covers it.
    func tile(
        _ starter: QuickAskStarter, keycap: String?, onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "ask-tile")
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let mark = whole(Gtk.label(starter.glyph, css: "ask-tile-glyph", selectable: false))
        gtk_label_set_xalign(op(mark), 0.5)
        gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(line), mark)
        let words = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(words, 1)
        gtk_widget_set_valign(words, GTK_ALIGN_CENTER)
        let title = Gtk.label(starter.title, css: "ask-tile-title", selectable: false)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(words), title)
        let note = Gtk.label(starter.detail, css: "ask-tile-detail", selectable: false)
        gtk_label_set_ellipsize(op(note), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(note), 0)
        gtk_box_append(ptr(words), note)
        gtk_box_append(ptr(line), words)
        if let keycap {
            let cap = whole(Gtk.label(keycap, css: "ask-keycap", selectable: false))
            gtk_widget_set_valign(cap, GTK_ALIGN_START)
            gtk_box_append(ptr(line), cap)
        }
        gtk_button_set_child(ptr(button), line)
        gtk_widget_set_tooltip_text(button, starter.detail)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        return button
    }

    /// A question already asked, on one line: what it was, and how long ago at the far end.
    func recentRow(
        title: String, age: String, onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "ask-row")
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
        let mark = whole(Gtk.label("↻", css: "ask-glyph", selectable: false))
        gtk_label_set_xalign(op(mark), 0.5)
        gtk_label_set_width_chars(op(mark), 2)
        gtk_box_append(ptr(line), mark)
        let name = Gtk.label(title, css: "ask-row-title", selectable: false)
        gtk_label_set_ellipsize(op(name), PANGO_ELLIPSIZE_END)
        gtk_label_set_xalign(op(name), 0)
        gtk_widget_set_hexpand(name, 1)
        gtk_box_append(ptr(line), name)
        gtk_box_append(ptr(line), whole(Gtk.label(age, css: "ask-row-detail", selectable: false)))
        gtk_button_set_child(ptr(button), line)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onClick)
        return button
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
            holding: held.holding, fingerprint: held.fingerprint, abilities: abilities)
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
                self.fitToContents()
            }
        }
    }

    /// An errand is the first half of a sentence, the same as a starter: the instruction lands in
    /// the entry and the clipboard follows it through the paste the entry already does, so a page
    /// of log still becomes the file it already is, and the person sends it.
    func pickErrand(_ errand: QuickAskClipboardErrand) {
        guard !asking, editor.text.isEmpty, attachments.isEmpty, let copied,
            let offer = copiedOffer
        else { return }
        QuickAskClipboardMemory.settle(copied.fingerprint)
        let plan = PasteIntake.plan(for: offer, abilities: abilities, alreadyNamed: pastedImageCount)
        pastedImageCount = plan.named
        write(errand.opening + (plan.text ?? ""))
        if !plan.attachments.isEmpty {
            attachments.append(contentsOf: plan.attachments)
            renderAttachments()
        }
        if let notice = plan.notices.first { setHint(notice) }
        renderStarters()
        editor.focus()
        AppLog.write(.ui, "ASK copied=\(errand.id)")
    }

    func setCopiedAside() {
        guard let copied else { return }
        QuickAskClipboardMemory.settle(copied.fingerprint)
        renderStarters()
        fitToContents()
        editor.focus()
        AppLog.write(.ui, "ASK copied set aside")
    }

    func pick(at index: Int) {
        guard picks.indices.contains(index) else { return }
        switch picks[index] {
        case .errand(let errand): pickErrand(errand)
        case .starter(let starter): pickStarter(at: starter)
        }
    }

    /// The rows are the empty state and nothing more, and a window that kept their height after
    /// they left would be a pane of dead space under the question: the toplevel is asked for its
    /// natural height again every time they come or go.
    func refreshStarterVisibility() {
        let empty = editor.text.isEmpty && attachments.isEmpty
        let visible: Int32 = empty && !asking ? 1 : 0
        guard gtk_widget_get_visible(starters) != visible else { return }
        gtk_widget_set_visible(starters, visible)
        fitToContents()
    }

    /// The window is exactly as tall as what is in it, which means it has to be asked again every
    /// time that changes: a box that grew inside a window that did not would write the question
    /// off the bottom edge of its own surface. Asking for the natural height (-1) a second time is
    /// no change at all to GTK, so a window that had grown kept its height after the card or the
    /// box under it shrank; asking for a single pixel lets the content's own minimum decide, in
    /// both directions, every time.
    func fitToContents() {
        gtk_window_set_default_size(ptr(window), 720, 1)
    }

    /// A starter is the first half of a sentence, never a question the app asked on somebody's
    /// behalf: the words land in the entry with the caret at their end, and a row that needs a
    /// file opens the chooser for it in the same gesture.
    func pickStarter(at index: Int) {
        guard !asking, offered.indices.contains(index) else { return }
        let starter = offered[index]
        QuickAskStarterRecents.record(starter.id)
        if editor.text.isEmpty { write(starter.prompt) }
        editor.focus()
        refreshStarterVisibility()
        switch starter.opens {
        case .files, .photos: pickAttachments()
        case .camera, .none: break
        }
        AppLog.write(.ui, "ASK starter=\(starter.id)")
    }

    func resume(_ entry: SessionEntry) {
        guard !asking else { return }
        let onResume = onResume
        let session = entry
        close()
        onResume(session)
    }
}
