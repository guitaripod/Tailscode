import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The Keyboard page: every shortcut as keycaps, a search over them, and a dialog that rebinds one
/// by pressing the keys. The page holds no rules of its own — what may be bound, who it would take
/// the key from and how the file is written are all `ShortcutEditor`'s — so it can only ever show
/// and ask.
enum SettingsKeyboardPage {
    static func fill(_ page: UnsafeMutablePointer<GtkWidget>, _ context: SettingsContext) {
        let attention = SettingsRows.group(Localized.text("Needs attention"), on: page)

        let searchGroup = SettingsRows.group(nil, on: page)
        let search = gtk_search_entry_new()!
        gtk_search_entry_set_placeholder_text(op(search), Localized.text("Search shortcuts"))
        adw_preferences_group_add(ptr(searchGroup), search)

        let sectionsGroup = SettingsRows.group(nil, on: page)
        let host = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 32)
        adw_preferences_group_add(ptr(sectionsGroup), host)

        if let window = context.window.widget { SummonRows.install(on: page, window: window) }

        let fileGroup = SettingsRows.group(Localized.text("Shortcuts file"), on: page)
        let state = KeyboardPageState(context: context, attention: attention, host: host)
        state.installFileRows(in: fileGroup)

        let searchBits = UInt(bitPattern: search)
        Gtk.connect(UnsafeMutableRawPointer(search), "search-changed") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: searchBits) else { return }
            state.search(Dialogs.entryText(ptr(raw)))
        }
        state.render()
    }
}

/// What the page is showing, and the widgets it rebuilds when that changes. The search entry and
/// the file group are built once and never rebuilt, so typing in the entry keeps its focus while
/// the categories under it are replaced.
final class KeyboardPageState: @unchecked Sendable {
    private let context: SettingsContext
    private let attention: Gtk.WeakWidget
    private let host: Gtk.WeakWidget
    private var attentionRows: [Gtk.WeakWidget] = []
    private var resetRow: Gtk.WeakWidget?
    private var query = ""

    init(
        context: SettingsContext, attention: UnsafeMutablePointer<GtkWidget>,
        host: UnsafeMutablePointer<GtkWidget>
    ) {
        self.context = context
        self.attention = Gtk.WeakWidget(attention)
        self.host = Gtk.WeakWidget(host)
    }

    func search(_ text: String) {
        query = text
        render()
    }

    func render() {
        let bindings = ShortcutBindings.load()
        renderAttention()
        renderSections(bindings)
        renderCount(bindings)
    }

    /// Any change, from a row or from the dialog: the page redraws from the file and the main
    /// window reloads its shortcut table. Deferred, because the control that asked may be a row
    /// this very redraw is about to remove.
    func changed() {
        Gtk.onMain { [self] in
            render()
            context.onShortcutsChanged()
        }
    }

    private func renderAttention() {
        guard let group = attention.widget else { return }
        for row in attentionRows {
            if let widget = row.widget { adw_preferences_group_remove(ptr(group), ptr(widget)) }
        }
        attentionRows = []
        let issues = ShortcutSet.load().issues
        for issue in issues {
            let row = KeybindingRows.issueRow(issue)
            adw_preferences_group_add(ptr(group), ptr(row))
            attentionRows.append(Gtk.WeakWidget(row))
        }
        gtk_widget_set_visible(group, issues.isEmpty ? 0 : 1)
    }

    private func renderSections(_ bindings: ShortcutBindings) {
        guard let host = host.widget else { return }
        Gtk.removeChildren(of: host)
        let sections = ShortcutEditor.sections(bindings: bindings, query: query)
        guard !sections.isEmpty else {
            let empty = Gtk.label(
                Localized.text("No shortcut matches that."), css: "dim-label", wrap: true,
                selectable: false)
            gtk_box_append(ptr(host), empty)
            return
        }
        for section in sections {
            let group = adw_preferences_group_new()!
            adw_preferences_group_set_title(ptr(group), section.category.title)
            for entry in section.entries { adw_preferences_group_add(ptr(group), row(for: entry)) }
            gtk_box_append(ptr(host), group)
        }
    }

    private func row(for entry: ShortcutEntry) -> UnsafeMutablePointer<GtkWidget> {
        let id = entry.id
        return KeybindingRows.row(
            for: entry,
            onOpen: { [self] in
                KeyCaptureDialog.present(context: context, id: id) { [self] in changed() }
            },
            onRestore: { [self] in restore(id) })
    }

    private func restore(_ id: String) {
        let plan = ShortcutEditor.restoring(id, in: ShortcutBindings.load())
        if let failure = KeyboardEdit.apply(plan) {
            toast(failure)
        } else if let taken = KeyboardEdit.takenFrom(plan.displaced) {
            toast(taken)
        }
        changed()
    }

    private func renderCount(_ bindings: ShortcutBindings) {
        guard let row = resetRow?.widget else { return }
        adw_action_row_set_subtitle(
            ptr(row),
            ShortcutFile.isUnreadable
                ? Localized.text(
                    "keybindings.json is not valid JSON — fix it in the text editor, or reset it")
                : Self.countWords(bindings.customizedCount))
    }

    private static func countWords(_ count: Int) -> String {
        switch count {
        case 0: return Localized.text("Every shortcut is as shipped")
        case 1: return Localized.text("1 shortcut changed")
        default: return Localized.text("%d shortcuts changed", Int32(count))
        }
    }

    private func toast(_ words: String) {
        guard let window = context.window.widget, let toast = adw_toast_new(words) else { return }
        adw_preferences_window_add_toast(ptr(window), toast)
    }

    func installFileRows(in group: UnsafeMutablePointer<GtkWidget>) {
        let context = context
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Shortcut cheatsheet"), label: Localized.text("Show")
            ) { context.onShowCheatsheet() }, to: group)
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Edit as text"), subtitle: ShortcutSet.configURL.path,
                label: Localized.text("Edit")
            ) { Self.openInEditor() }, to: group)
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Apply changes from the file"), label: Localized.text("Reload")
            ) { [self] in changed() }, to: group)
        let reset = SettingsRows.buttonRow(
            Localized.text("Reset every shortcut"), label: Localized.text("Reset…")
        ) { [self] in confirmReset() }
        adw_preferences_row_set_use_markup(ptr(reset), 0)
        resetRow = Gtk.WeakWidget(reset)
        SettingsRows.add(reset, to: group)
    }

    private static func openInEditor() {
        ShortcutSet.ensureConfigFile()
        let editor = Process()
        editor.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        editor.arguments = [ShortcutSet.configURL.path]
        try? editor.run()
    }

    private func confirmReset() {
        let broken = ShortcutFile.isUnreadable
        Dialogs.confirm(
            title: broken
                ? Localized.text("Replace keybindings.json?")
                : Localized.text("Reset every shortcut?"),
            body: broken
                ? Localized.text(
                    "The file is not valid JSON. Its text is kept beside it as keybindings.json.broken, and a fresh file takes its place."
                )
                : Localized.text(
                    "Every shortcut goes back to the keys it shipped with. Notes you wrote in keybindings.json stay."
                ),
            confirmLabel: broken ? Localized.text("Replace") : Localized.text("Reset"),
            parent: context.window.widget
        ) { [self] in
            do {
                try ShortcutFile.resetAll()
            } catch {
                toast(KeyboardEdit.words(for: error))
            }
            changed()
        }
    }
}

/// Writing a plan, and saying so when it cannot be written. A file that is not JSON is never
/// overwritten — somebody typed it — so the refusal has to reach the person's eyes.
enum KeyboardEdit {
    /// Applies `plan`; nil when it went through, the words for the person when it did not.
    static func apply(_ plan: ShortcutEditor.Plan) -> String? {
        do {
            try ShortcutEditor.apply(plan)
            return nil
        } catch {
            return words(for: error)
        }
    }

    static func words(for error: Error) -> String {
        if let failure = error as? ShortcutFile.Failure, failure == .unreadable {
            return Localized.text(
                "keybindings.json is not valid JSON — fix it in the text editor, or reset it")
        }
        return Localized.text("Could not save keybindings.json: %@", error.localizedDescription)
    }

    /// Who lost a key to an edit, or nil when nobody did.
    static func takenFrom(_ displaced: [ShortcutEditor.Conflict]) -> String? {
        var titles: [String] = []
        for conflict in displaced where !titles.contains(conflict.title) {
            titles.append(conflict.title)
        }
        guard !titles.isEmpty else { return nil }
        let quoted = titles.map { "“\($0)”" }.joined(separator: ", ")
        return Localized.text("Taken from %@", quoted)
    }
}
