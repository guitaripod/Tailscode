import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// One action, written or rewritten: its name and glyph, the words with their tokens, when it is
/// offered, where it asks and whether it sends at once. Opened over the quick ask that asked for
/// it, so the aim it can keep is the one showing there.
final class QuickAskActionEditor: @unchecked Sendable {
    nonisolated(unsafe) static var current: QuickAskActionEditor?

    static let offers: [QuickAskAction.Offer] = [.always, .text, .link, .picture, .files]

    let original: QuickAskAction
    let isNew: Bool
    let aims: [QuickAskActionAim?]
    var offer: QuickAskAction.Offer
    var aimIndex: Int
    var sends: Bool

    let window: UnsafeMutablePointer<GtkWidget>
    let titleRow: UnsafeMutablePointer<GtkWidget>
    let glyphRow: UnsafeMutablePointer<GtkWidget>
    let hostsRow: UnsafeMutablePointer<GtkWidget>
    let prompt: UnsafeMutablePointer<GtkWidget>
    let problem: UnsafeMutablePointer<GtkWidget>

    static func open(
        _ action: QuickAskAction, isNew: Bool, current aim: QuickAskActionAim,
        on owner: QuickAskWindow
    ) {
        Self.current?.close()
        Self.current = QuickAskActionEditor(action, isNew: isNew, current: aim, on: owner)
    }

    private init(
        _ action: QuickAskAction, isNew: Bool, current aim: QuickAskActionAim,
        on owner: QuickAskWindow
    ) {
        original = action
        self.isNew = isNew
        var aims: [QuickAskActionAim?] = [nil]
        if let own = action.aim { aims.append(own) }
        if action.aim != aim { aims.append(aim) }
        self.aims = aims
        offer = action.offer
        aimIndex = action.aim == nil ? 0 : 1
        sends = action.sends

        window = gtk_window_new()!
        gtk_window_set_title(
            ptr(window), isNew ? Localized.text("New action") : Localized.text("Edit action"))
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 560, -1)
        if let parent = owner.stage.dialogParent {
            gtk_window_set_transient_for(ptr(window), ptr(parent))
        }

        let header = adw_header_bar_new()!
        let cancel = Gtk.button(Localized.text("Cancel"), css: ["flat"]) {
            Gtk.onMain { QuickAskActionEditor.current?.close() }
        }
        let save = Gtk.button(Localized.text("Save"), css: ["suggested-action"]) {
            Gtk.onMain { QuickAskActionEditor.current?.save() }
        }
        adw_header_bar_pack_start(op(UnsafeMutableRawPointer(header)), cancel)
        adw_header_bar_pack_end(op(UnsafeMutableRawPointer(header)), save)
        gtk_window_set_titlebar(ptr(window), header)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 14)
        Gtk.margins(column, top: 16, bottom: 16, leading: 16, trailing: 16)
        gtk_window_set_child(ptr(window), column)

        let naming = adw_preferences_group_new()!
        titleRow = Self.entryRow(Localized.text("Title"), text: action.title)
        glyphRow = Self.entryRow(Localized.text("Glyph"), text: action.glyph)
        gtk_widget_set_tooltip_text(glyphRow, Localized.text("One or two characters for the tile"))
        adw_preferences_group_add(ptr(naming), ptr(titleRow))
        adw_preferences_group_add(ptr(naming), ptr(glyphRow))
        gtk_box_append(ptr(column), naming)

        let words = Gtk.label(Localized.text("Words"), css: "ask-section", selectable: false)
        gtk_label_set_xalign(op(words), 0)
        gtk_box_append(ptr(column), words)
        prompt = gtk_text_view_new()!
        gtk_text_view_set_wrap_mode(ptr(prompt), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_top_margin(ptr(prompt), 8)
        gtk_text_view_set_bottom_margin(ptr(prompt), 8)
        gtk_text_view_set_left_margin(ptr(prompt), 10)
        gtk_text_view_set_right_margin(ptr(prompt), 10)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(prompt)), action.prompt, -1)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_min_content_height(op(scroller), 96)
        gtk_scrolled_window_set_max_content_height(op(scroller), 260)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), prompt)
        Gtk.addClass(scroller, "card")
        gtk_box_append(ptr(column), scroller)
        let tokens = Gtk.label(Self.tokenHelp, css: "ask-hint", wrap: true, selectable: true)
        gtk_label_set_xalign(op(tokens), 0)
        gtk_box_append(ptr(column), tokens)

        let placing = adw_preferences_group_new()!
        hostsRow = Self.entryRow(Localized.text("Sites"), text: action.hosts.joined(separator: ", "))
        gtk_widget_set_tooltip_text(
            hostsRow, Localized.text("Comma-separated, like x.com, youtube.com; empty for any link"))
        let offerRow = SettingsRows.comboRow(
            title: Localized.text("Offered"), subtitle: nil,
            options: Self.offers.map(Self.offerWords),
            selected: Self.offers.firstIndex(of: action.offer) ?? 0
        ) { index in
            Gtk.onMain {
                guard let editor = QuickAskActionEditor.current,
                    QuickAskActionEditor.offers.indices.contains(index)
                else { return }
                editor.offer = QuickAskActionEditor.offers[index]
                gtk_widget_set_visible(editor.hostsRow, editor.offer == .link ? 1 : 0)
            }
        }
        let aimRow = SettingsRows.comboRow(
            title: Localized.text("Asks on"), subtitle: nil,
            options: aims.enumerated().map { index, aim in
                Self.aimOption(aim, own: index == 1 && action.aim != nil, owner: owner)
            },
            selected: aimIndex
        ) { index in
            Gtk.onMain { QuickAskActionEditor.current?.aimIndex = index }
        }
        let sendsRow = SettingsRows.switchRow(
            title: Localized.text("Send at once"),
            subtitle: Localized.text("Without waiting for enter, once its tokens are gathered"),
            value: action.sends
        ) { value in
            Gtk.onMain { QuickAskActionEditor.current?.sends = value }
        }
        adw_preferences_group_add(ptr(placing), ptr(offerRow))
        adw_preferences_group_add(ptr(placing), ptr(hostsRow))
        adw_preferences_group_add(ptr(placing), ptr(aimRow))
        adw_preferences_group_add(ptr(placing), ptr(sendsRow))
        gtk_widget_set_visible(hostsRow, action.offer == .link ? 1 : 0)
        gtk_box_append(ptr(column), placing)

        problem = Gtk.label("", css: "ask-hint", wrap: true, selectable: false)
        gtk_label_set_xalign(op(problem), 0)
        gtk_box_append(ptr(column), problem)

        Gtk.onKey(window) { keyval, state in
            if keyval == Keymap.escape {
                Gtk.onMain { QuickAskActionEditor.current?.close() }
                return true
            }
            let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
            if isReturn, state & KeyChord.controlMask != 0 {
                Gtk.onMain { QuickAskActionEditor.current?.save() }
                return true
            }
            return false
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") {
            QuickAskActionEditor.current = nil
        }
        gtk_window_present(ptr(window))
        owner.stage.stepAside(until: window)
        gtk_widget_grab_focus(original.title.isEmpty ? titleRow : prompt)
    }

    static var tokenHelp: String {
        Localized.text(
            "{clipboard} or {link} the copied thing · {session} a chat to hand on · {screen} a drag over the screen · {file} a file · {latest:~/Downloads} the newest file there · {date} today · {cursor} where the caret lands"
        )
    }

    static func offerWords(_ offer: QuickAskAction.Offer) -> String {
        switch offer {
        case .always: return Localized.text("Always, as a tile")
        case .text: return Localized.text("When words are copied")
        case .link: return Localized.text("When a link is copied")
        case .picture: return Localized.text("When a picture is copied")
        case .files: return Localized.text("When files are copied")
        }
    }

    static func aimOption(_ aim: QuickAskActionAim?, own: Bool, owner: QuickAskWindow) -> String {
        guard let aim else { return Localized.text("The aim in force") }
        let words = owner.aimWords(aim)
        return own
            ? Localized.text("Its own: %@", words)
            : Localized.text("The aim showing now: %@", words)
    }

    static func entryRow(_ title: String, text: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_entry_row_new()!
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_preferences_row_set_title(ptr(row), title)
        gtk_editable_set_text(op(row), text)
        return row
    }

    private func text(of row: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let raw = gtk_editable_get_text(op(row)) else { return "" }
        return String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var promptText: String {
        let buffer = gtk_text_view_get_buffer(ptr(prompt))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    func save() {
        let words = promptText
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            gtk_label_set_text(op(problem), Localized.text("An action needs words to write."))
            return
        }
        let firstLine = words.split(separator: "\n").first.map(String.init) ?? words
        let title = text(of: titleRow)
        let glyph = text(of: glyphRow)
        let hosts = text(of: hostsRow).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        var action = original
        action.title = title.isEmpty ? String(firstLine.prefix(40)) : title
        action.glyph = glyph.isEmpty ? "✦" : String(glyph.prefix(2))
        action.prompt = words
        action.offer = offer
        action.hosts = offer == .link ? hosts : []
        action.aim = aims.indices.contains(aimIndex) ? aims[aimIndex] : nil
        action.sends = sends
        QuickAskActions.save(action)
        AppLog.write(.ui, "ASK action saved id=\(action.id) new=\(isNew)")
        close()
        QuickAskWindow.open?.editor.focus()
    }

    func close() {
        gtk_window_destroy(ptr(window))
        Self.current = nil
    }
}
