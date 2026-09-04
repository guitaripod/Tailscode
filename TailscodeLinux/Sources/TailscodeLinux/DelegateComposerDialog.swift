import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A packet, written rather than dictated — the same standard `ForgeSetupWindow` holds pointing at
/// a renderer: a modal transient over the board, held to as long as it is open and let go of on
/// `destroy`. Three fields matter (the goal, the paths, the verifier) and everything else is a
/// default the daemon's own class table already knows; `DelegateDraft` decides every word and every
/// rule, this only composes the widgets.
final class DelegateComposerDialog: @unchecked Sendable {
    nonisolated(unsafe) private static var open: DelegateComposerDialog?

    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, board: DelegateBoard,
        onSend: @escaping @Sendable (DelegateDraft) -> Void
    ) {
        if let open {
            gtk_window_present(ptr(open.window))
            return
        }
        open = DelegateComposerDialog(parent: parent, board: board, onSend: onSend)
    }

    private let window = gtk_window_new()!
    private let onSend: @Sendable (DelegateDraft) -> Void
    private var draft: DelegateDraft
    private let classes: [String]

    private let classDropdown: UnsafeMutablePointer<GtkWidget>
    private let goalView = gtk_text_view_new()!
    private let repoEntry = gtk_entry_new()!
    private let pathsView = gtk_text_view_new()!
    private let verifyEntry = gtk_entry_new()!
    private let suggestionRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let readEntry = gtk_entry_new()!
    private let notesView = gtk_text_view_new()!
    private let ladderStartRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let ladderCeilingRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let modeRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let effortRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
    private let statusHeader = Gtk.label(DelegateComposerWords.cautionsTitle, css: "row-title", selectable: false)
    private let problemsLabel = Gtk.label("", wrap: true, selectable: false)
    private let cautionsLabel = Gtk.label("", wrap: true, selectable: false)
    private let sendButton = gtk_button_new_with_label(DelegateComposerWords.sendTitle)!

    private init(
        parent: UnsafeMutablePointer<GtkWidget>?, board: DelegateBoard,
        onSend: @escaping @Sendable (DelegateDraft) -> Void
    ) {
        self.onSend = onSend
        draft = DelegateDraft(capabilities: board.capabilities, repo: "")
        classes = board.classes.isEmpty ? [draft.taskClass] : board.classes
        classDropdown = Self.dropdown(classes)
        DelegateToneCSS.apply(problemsLabel, .danger)
        DelegateToneCSS.apply(cautionsLabel, .attention)

        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 560, 720)
        gtk_widget_set_size_request(window, 460, 480)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(
            op(UnsafeMutableRawPointer(header)),
            adw_window_title_new(DelegateComposerWords.title, board.serverName))
        let cancel = Gtk.button(Localized.text("Cancel"), css: ["flat"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.close() }
        }
        adw_header_bar_pack_start(op(UnsafeMutableRawPointer(header)), cancel)
        gtk_window_set_titlebar(ptr(window), header)

        if let index = classes.firstIndex(of: draft.taskClass) {
            gtk_drop_down_set_selected(op(UnsafeMutableRawPointer(classDropdown)), UInt32(index))
        }
        gtk_editable_set_text(op(repoEntry), draft.repo)
        gtk_entry_set_placeholder_text(ptr(repoEntry), DelegateComposerWords.repoPlaceholder)
        gtk_entry_set_placeholder_text(ptr(verifyEntry), DelegateComposerWords.verifyPlaceholder)
        gtk_entry_set_placeholder_text(ptr(readEntry), "README.md, docs/")

        buildTierToggles(
            into: ladderStartRow, tiers: board.tiers, selected: draft.tier,
            assign: { [weak self] tier in self?.draft.tier = tier })
        buildTierToggles(
            into: ladderCeilingRow, tiers: board.tiers, selected: draft.ceiling,
            assign: { [weak self] tier in self?.draft.ceiling = tier })
        buildModeToggles()
        buildEffortToggles()

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(scroller), form())
        gtk_widget_set_vexpand(scroller, 1)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(column), scroller)
        gtk_box_append(ptr(column), footer())
        gtk_window_set_child(ptr(window), column)

        wireSignals()
        refreshVerifySuggestions()
        renderStatus()

        Gtk.onKey(window) { [weak self] keyval, _ in
            guard let self, keyval == Keymap.escape else { return false }
            self.close()
            return true
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            guard let self else { return }
            if DelegateComposerDialog.open === self { DelegateComposerDialog.open = nil }
        }

        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(goalView)
    }

    private func close() {
        gtk_window_destroy(ptr(window))
    }

    private func form() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 14)
        Gtk.margins(column, top: 12, bottom: 12, leading: 16, trailing: 16)

        gtk_box_append(ptr(column), fieldBlock(DelegateComposerWords.classLabel, classDropdown))
        gtk_box_append(
            ptr(column),
            fieldBlock(
                DelegateComposerWords.goalLabel,
                textArea(goalView, placeholder: DelegateComposerWords.goalPlaceholder, minHeight: 90)))
        gtk_widget_set_hexpand(repoEntry, 1)
        gtk_box_append(ptr(column), fieldBlock(DelegateComposerWords.repoLabel, repoEntry))
        gtk_box_append(
            ptr(column),
            fieldBlock(
                DelegateComposerWords.pathsLabel,
                textArea(pathsView, placeholder: DelegateComposerWords.pathsPlaceholder, minHeight: 70),
                help: DelegateComposerWords.pathsHelp))

        gtk_widget_set_hexpand(verifyEntry, 1)
        let verifyColumn = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_box_append(ptr(verifyColumn), verifyEntry)
        gtk_box_append(ptr(verifyColumn), suggestionRow)
        gtk_box_append(
            ptr(column),
            fieldBlock(DelegateComposerWords.verifyLabel, verifyColumn, help: DelegateComposerWords.verifyHelp))

        gtk_widget_set_hexpand(readEntry, 1)
        gtk_box_append(ptr(column), fieldBlock(DelegateComposerWords.readLabel, readEntry))
        gtk_box_append(
            ptr(column),
            fieldBlock(
                DelegateComposerWords.notesLabel,
                textArea(notesView, placeholder: "", minHeight: 60)))

        Gtk.addClass(ladderStartRow, "linked")
        Gtk.addClass(ladderCeilingRow, "linked")
        let ladder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_box_append(ptr(ladder), Gtk.label(Localized.text("Start"), css: "watch-meta", selectable: false))
        gtk_box_append(ptr(ladder), ladderStartRow)
        gtk_box_append(ptr(ladder), Gtk.label(Localized.text("Ceiling"), css: "watch-meta", selectable: false))
        gtk_box_append(ptr(ladder), ladderCeilingRow)
        gtk_box_append(
            ptr(column), fieldBlock(DelegateComposerWords.ladderLabel, ladder, help: DelegateComposerWords.ladderHelp))

        Gtk.addClass(modeRow, "linked")
        gtk_box_append(ptr(column), fieldBlock(DelegateComposerWords.modeLabel, modeRow))
        Gtk.addClass(effortRow, "linked")
        gtk_box_append(ptr(column), fieldBlock(DelegateComposerWords.effortLabel, effortRow))
        return column
    }

    private func fieldBlock(
        _ title: String, _ widget: UnsafeMutablePointer<GtkWidget>, help: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        gtk_box_append(ptr(column), Gtk.label(title, css: "row-title", selectable: false))
        gtk_box_append(ptr(column), widget)
        if let help {
            gtk_box_append(ptr(column), Gtk.label(help, css: "row-detail", wrap: true, selectable: false))
        }
        return column
    }

    private func textArea(
        _ view: UnsafeMutablePointer<GtkWidget>, placeholder: String, minHeight: Int32
    ) -> UnsafeMutablePointer<GtkWidget> {
        let frame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(frame, "forge-prompt")
        gtk_text_view_set_wrap_mode(ptr(view), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_accepts_tab(ptr(view), 0)
        gtk_text_view_set_top_margin(ptr(view), 8)
        gtk_text_view_set_bottom_margin(ptr(view), 8)
        gtk_text_view_set_left_margin(ptr(view), 10)
        gtk_text_view_set_right_margin(ptr(view), 10)
        gtk_widget_set_size_request(view, -1, minHeight)
        if !placeholder.isEmpty { gtk_widget_set_tooltip_text(view, placeholder) }
        gtk_box_append(ptr(frame), view)
        return frame
    }

    private func footer() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(column, "forge-prompt")
        Gtk.margins(column, top: 8, bottom: 12, leading: 16, trailing: 16)
        gtk_box_append(ptr(column), statusHeader)
        gtk_box_append(ptr(column), problemsLabel)
        gtk_box_append(ptr(column), cautionsLabel)
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(row, GTK_ALIGN_END)
        Gtk.margins(row, top: 6)
        Gtk.addClass(sendButton, "suggested-action")
        Gtk.addClass(sendButton, "pill")
        gtk_box_append(ptr(row), sendButton)
        gtk_box_append(ptr(column), row)
        return column
    }

    private func wireSignals() {
        Gtk.onNotify(UnsafeMutableRawPointer(classDropdown), property: "selected") { [weak self] in
            Gtk.onMain { [weak self] in self?.updateFromForm() }
        }
        Gtk.connect(UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(goalView))!), "changed") {
            [weak self] in
            Gtk.onMain { [weak self] in self?.updateFromForm() }
        }
        Gtk.connect(UnsafeMutableRawPointer(repoEntry), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.updateFromForm() }
        }
        Gtk.connect(UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(pathsView))!), "changed") {
            [weak self] in
            Gtk.onMain { [weak self] in self?.updateFromForm() }
        }
        Gtk.connect(UnsafeMutableRawPointer(verifyEntry), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.updateFromForm() }
        }
        Gtk.connect(UnsafeMutableRawPointer(readEntry), "changed") { [weak self] in
            Gtk.onMain { [weak self] in self?.updateFromForm() }
        }
        Gtk.connect(UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(notesView))!), "changed") {
            [weak self] in
            Gtk.onMain { [weak self] in self?.updateFromForm() }
        }
        Gtk.connect(UnsafeMutableRawPointer(sendButton), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.pressSend() }
        }
    }

    private func updateFromForm() {
        draft.taskClass = selectedClass()
        draft.goal = Self.text(of: goalView)
        draft.repo = Dialogs.entryText(repoEntry)
        draft.paths = Self.text(of: pathsView)
        draft.verify = Dialogs.entryText(verifyEntry)
        draft.read = Dialogs.entryText(readEntry)
        draft.notes = Self.text(of: notesView)
        refreshVerifySuggestions()
        renderStatus()
    }

    private func selectedClass() -> String {
        let index = Int(gtk_drop_down_get_selected(op(UnsafeMutableRawPointer(classDropdown))))
        guard index >= 0, index < classes.count else { return draft.taskClass }
        return classes[index]
    }

    private func refreshVerifySuggestions() {
        Gtk.removeChildren(of: suggestionRow)
        let suggestions = DelegateDraft.verifySuggestions(paths: draft.pathList, repo: draft.repo)
        for suggestion in suggestions {
            gtk_box_append(
                ptr(suggestionRow),
                Gtk.button(suggestion, css: ["flat", "pill"]) { [weak self] in
                    Gtk.onMain { [weak self] in self?.pick(verify: suggestion) }
                })
        }
        gtk_widget_set_visible(suggestionRow, suggestions.isEmpty ? 0 : 1)
    }

    private func pick(verify: String) {
        gtk_editable_set_text(op(verifyEntry), verify)
        draft.verify = verify
        renderStatus()
    }

    private func renderStatus() {
        let problems = draft.problems
        let cautions = draft.cautions
        gtk_widget_set_visible(statusHeader, (problems.isEmpty && cautions.isEmpty) ? 0 : 1)
        gtk_label_set_text(op(problemsLabel), problems.joined(separator: "\n"))
        gtk_widget_set_visible(problemsLabel, problems.isEmpty ? 0 : 1)
        gtk_label_set_text(op(cautionsLabel), cautions.joined(separator: "\n"))
        gtk_widget_set_visible(cautionsLabel, cautions.isEmpty ? 0 : 1)
        gtk_widget_set_sensitive(sendButton, draft.canSend ? 1 : 0)
    }

    private func pressSend() {
        guard draft.canSend else { return }
        onSend(draft)
        close()
    }

    private func buildTierToggles(
        into row: UnsafeMutablePointer<GtkWidget>, tiers: [DelegateTier], selected: String?,
        assign: @escaping @Sendable (String?) -> Void
    ) {
        let options: [(id: String?, title: String)] =
            [(nil, Localized.text("Class decides"))]
            + tiers.map { ($0.tier, $0.label.isEmpty ? $0.tier : $0.label) }
        var lead: UnsafeMutablePointer<GtkWidget>?
        for option in options {
            let button = gtk_toggle_button_new_with_label(option.title)!
            if let lead {
                gtk_toggle_button_set_group(
                    ptr(button), ptr(lead))
            } else {
                lead = button
            }
            if option.id == selected {
                gtk_toggle_button_set_active(ptr(button), 1)
            }
            let id = option.id
            let bits = UInt(bitPattern: button)
            Gtk.connect(UnsafeMutableRawPointer(button), "toggled") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                    let toggle: UnsafeMutablePointer<GtkToggleButton> = ptr(raw)
                    guard gtk_toggle_button_get_active(toggle) != 0 else { return }
                    assign(id)
                    self?.renderStatus()
                }
            }
            gtk_box_append(ptr(row), button)
        }
    }

    private func buildModeToggles() {
        var lead: UnsafeMutablePointer<GtkWidget>?
        for mode in DelegateMode.allCases {
            let button = gtk_toggle_button_new_with_label(DelegateWords.mode(mode))!
            if let lead {
                gtk_toggle_button_set_group(
                    ptr(button), ptr(lead))
            } else {
                lead = button
            }
            if mode == draft.mode { gtk_toggle_button_set_active(ptr(button), 1) }
            let bits = UInt(bitPattern: button)
            Gtk.connect(UnsafeMutableRawPointer(button), "toggled") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                    let toggle: UnsafeMutablePointer<GtkToggleButton> = ptr(raw)
                    guard gtk_toggle_button_get_active(toggle) != 0 else { return }
                    self?.draft.mode = mode
                    self?.renderStatus()
                }
            }
            gtk_box_append(ptr(modeRow), button)
        }
    }

    private func buildEffortToggles() {
        let options: [(id: DelegateEffort?, title: String)] =
            [(nil, DelegateComposerWords.effortDefault)]
            + DelegateEffort.allCases.map { ($0, DelegateWords.effort($0)) }
        var lead: UnsafeMutablePointer<GtkWidget>?
        for option in options {
            let button = gtk_toggle_button_new_with_label(option.title)!
            if let lead {
                gtk_toggle_button_set_group(
                    ptr(button), ptr(lead))
            } else {
                lead = button
            }
            if option.id == draft.effort {
                gtk_toggle_button_set_active(ptr(button), 1)
            }
            let id = option.id
            let bits = UInt(bitPattern: button)
            Gtk.connect(UnsafeMutableRawPointer(button), "toggled") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                    let toggle: UnsafeMutablePointer<GtkToggleButton> = ptr(raw)
                    guard gtk_toggle_button_get_active(toggle) != 0 else { return }
                    self?.draft.effort = id
                    self?.renderStatus()
                }
            }
            gtk_box_append(ptr(effortRow), button)
        }
    }

    private static func text(of view: UnsafeMutablePointer<GtkWidget>) -> String {
        let buffer = gtk_text_view_get_buffer(ptr(view))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    private static func dropdown(_ items: [String]) -> UnsafeMutablePointer<GtkWidget> {
        var pointers: [UnsafePointer<CChar>?] = items.map { UnsafePointer(strdup($0)) }
        pointers.append(nil)
        let widget = pointers.withUnsafeBufferPointer { buffer in
            gtk_drop_down_new_from_strings(buffer.baseAddress)!
        }
        for pointer in pointers where pointer != nil {
            free(UnsafeMutableRawPointer(mutating: pointer))
        }
        return widget
    }
}
