import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Rebinding one action by pressing its new keys. The dialog records what is pressed and shows it
/// as keycaps; whether it may be bound, who has it already and how the file changes are all
/// `ShortcutEditor`'s answers, asked again after every press, so the verdict on screen is the one
/// the edit would act on.
enum KeyCaptureDialog {
    static func present(
        context: SettingsContext, id: String, onChanged: @escaping @Sendable () -> Void
    ) {
        guard let definition = ShortcutRegistry.definition(id) else { return }
        let (window, content, actions) = Dialogs.windowWithActions(
            title: definition.title, parent: context.window.widget, width: 500)
        gtk_window_set_default_size(ptr(window), 500, 540)
        let session = CaptureSession(id: id, onChanged: onChanged)
        session.window = Gtk.WeakWidget(window)
        let windowBits = UInt(bitPattern: window)
        let closeWindow: @Sendable () -> Void = {
            if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                gtk_window_destroy(ptr(raw))
            }
        }

        let title = Gtk.label(definition.title, css: "title-3", wrap: true, selectable: false)
        gtk_box_append(ptr(content), title)
        gtk_box_append(
            ptr(content),
            Gtk.label(definition.category.title, css: "dim-label", wrap: false, selectable: false))

        gtk_box_append(ptr(content), sectionLabel(Localized.text("Keys now")))
        let now = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        session.nowBox = Gtk.WeakWidget(now)
        gtk_box_append(ptr(content), now)

        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        gtk_widget_add_css_class(card, "key-capture")
        gtk_widget_set_focusable(card, 1)
        gtk_widget_set_hexpand(card, 1)
        gtk_widget_set_vexpand(card, 0)
        gtk_widget_set_valign(card, GTK_ALIGN_START)
        gtk_widget_set_margin_top(card, 6)
        session.card = Gtk.WeakWidget(card)
        gtk_box_append(ptr(content), card)
        let cardBits = UInt(bitPattern: card)
        Gtk.onPrimaryRelease(card) {
            if let raw = UnsafeMutableRawPointer(bitPattern: cardBits) {
                gtk_widget_grab_focus(ptr(raw))
            }
        }

        let hint = Gtk.label(
            Localized.text(
                "Press a second key to make it a two-key shortcut. Backspace clears; Esc closes."),
            css: "row-detail", wrap: true, selectable: false)
        gtk_box_append(ptr(content), hint)

        let verdict = Gtk.label("", css: "row-detail", wrap: true, selectable: false)
        session.verdict = Gtk.WeakWidget(verdict)
        gtk_box_append(ptr(content), verdict)

        gtk_box_append(ptr(content), typedExpander(session))

        let restore = Gtk.button(Localized.text("Restore default"), css: ["flat"]) {
            session.restoreDefault()
        }
        session.restore = Gtk.WeakWidget(restore)
        gtk_box_append(ptr(actions), restore)
        gtk_box_append(ptr(actions), Gtk.button(Localized.text("Done"), css: ["flat"], onClick: closeWindow))
        let primary = Gtk.button(Localized.text("Add key"), css: ["suggested-action"]) {
            session.commit()
        }
        session.primary = Gtk.WeakWidget(primary)
        gtk_box_append(ptr(actions), primary)

        Gtk.onKey(window) { keyval, state in
            session.press(keyval: keyval, state: state, close: closeWindow)
        }
        session.refresh()
        gtk_window_present(ptr(window))
        Gtk.onMain { gtk_widget_grab_focus(ptr(UnsafeMutableRawPointer(bitPattern: cardBits)!)) }
    }

    private static func sectionLabel(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "dim-label", wrap: false, selectable: false)
        gtk_widget_add_css_class(label, "caption-heading")
        return label
    }

    /// The grammar spelled out, for the keys a press cannot record: Esc, Backspace and Tab are
    /// the dialog's own, and a context prefix limits a key to where it is wanted.
    private static func typedExpander(_ session: CaptureSession) -> UnsafeMutablePointer<GtkWidget> {
        let expander = gtk_expander_new(Localized.text("Type it instead"))!
        let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_set_margin_top(box, 6)
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(entry), "normal:ctrl+b · g g · esc · f5")
        gtk_box_append(ptr(box), entry)
        gtk_expander_set_child(op(expander), box)
        session.entry = Gtk.WeakWidget(entry)

        let entryBits = UInt(bitPattern: entry)
        Gtk.connect(UnsafeMutableRawPointer(entry), "changed") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
            session.typed(Dialogs.entryText(ptr(raw)))
        }
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate") { session.commit() }

        let expanderBits = UInt(bitPattern: expander)
        Gtk.onNotify(UnsafeMutableRawPointer(expander), property: "expanded") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: expanderBits) else { return }
            let open = gtk_expander_get_expanded(op(raw)) != 0
            if let target = open ? session.entry?.widget : session.card?.widget {
                gtk_widget_grab_focus(target)
            }
        }
        return expander
    }
}

/// One open capture dialog: what has been pressed and the widgets it redraws. Main-thread only,
/// like every widget it touches; a class because GTK's callbacks outlive any one function.
final class CaptureSession: @unchecked Sendable {
    /// What the edit would do with the keys recorded so far.
    enum Verdict {
        case idle
        case unreadable
        case refused(String)
        case already
        case ready(spec: String, note: String?, conflicts: [ShortcutEditor.Conflict])
    }

    let id: String
    let onChanged: @Sendable () -> Void
    var window: Gtk.WeakWidget?
    var nowBox: Gtk.WeakWidget?
    var card: Gtk.WeakWidget?
    var verdict: Gtk.WeakWidget?
    var restore: Gtk.WeakWidget?
    var primary: Gtk.WeakWidget?
    var entry: Gtk.WeakWidget?
    private var chords: [KeyChord] = []
    private var contexts: Set<KeyContext>?
    private var typedUnreadable = false
    private var afterNote: String?
    private var failure: String?
    private var settingEntry = false

    init(id: String, onChanged: @escaping @Sendable () -> Void) {
        self.id = id
        self.onChanged = onChanged
    }

    func press(keyval: UInt32, state: UInt32, close: @Sendable () -> Void) -> Bool {
        let chord = KeyChord.canonical(keyval: keyval, state: state)
        let bare = chord.map { !$0.control && !$0.shift && !$0.alt } ?? false
        if bare, keyval == Keymap.escape {
            close()
            return true
        }
        if let widget = window?.widget, Gtk.focusTakesText(widget) { return false }
        if bare, keyval == Keymap.backspace {
            forget()
            refresh()
            return true
        }
        guard let chord else { return true }
        record(chord)
        return true
    }

    private func record(_ chord: KeyChord) {
        chords = chords.count == 1 ? chords + [chord] : [chord]
        contexts = nil
        typedUnreadable = false
        afterNote = nil
        failure = nil
        clearEntry()
        refresh()
    }

    private func forget() {
        chords = []
        contexts = nil
        typedUnreadable = false
        afterNote = nil
        failure = nil
        clearEntry()
    }

    private func clearEntry() {
        guard let widget = entry?.widget else { return }
        settingEntry = true
        gtk_editable_set_text(op(widget), "")
        settingEntry = false
    }

    func typed(_ text: String) {
        guard !settingEntry else { return }
        afterNote = nil
        failure = nil
        let spec = text.trimmingCharacters(in: .whitespaces)
        if spec.isEmpty {
            chords = []
            contexts = nil
            typedUnreadable = false
        } else if let parsed = KeySpec.parse(spec) {
            chords = parsed.chords
            contexts = parsed.contexts
            typedUnreadable = false
        } else {
            chords = []
            contexts = nil
            typedUnreadable = true
        }
        refresh()
    }

    func verdictNow() -> Verdict {
        if typedUnreadable { return .unreadable }
        guard !chords.isEmpty else { return .idle }
        switch ShortcutEditor.fit(chords, contexts: contexts, for: id) {
        case .refused(let reason):
            return .refused(reason)
        case .bound(let spec, let note):
            let bindings = ShortcutBindings.load()
            guard !bindings.keys(for: id).contains(spec) else { return .already }
            return .ready(
                spec: spec, note: note,
                conflicts: ShortcutEditor.conflicts(adding: spec, to: id, in: bindings))
        }
    }

    func commit() {
        guard case .ready(let spec, _, _) = verdictNow() else { return }
        let plan = ShortcutEditor.adding(spec, to: id, in: ShortcutBindings.load())
        if let problem = KeyboardEdit.apply(plan) {
            failure = problem
            refresh()
            return
        }
        forget()
        afterNote = Self.sentence([Localized.text("Added"), KeyboardEdit.takenFrom(plan.displaced)])
        refresh()
        focusCard()
        onChanged()
    }

    func restoreDefault() {
        let plan = ShortcutEditor.restoring(id, in: ShortcutBindings.load())
        if let problem = KeyboardEdit.apply(plan) {
            failure = problem
            refresh()
            return
        }
        forget()
        afterNote = Self.sentence([
            Localized.text("Back to the default keys"), KeyboardEdit.takenFrom(plan.displaced),
        ])
        refresh()
        focusCard()
        onChanged()
    }

    func remove(_ spec: String) {
        let plan = ShortcutEditor.removing(spec, from: id, in: ShortcutBindings.load())
        if let problem = KeyboardEdit.apply(plan) {
            failure = problem
        } else {
            afterNote = Localized.text("Removed")
        }
        refresh()
        focusCard()
        onChanged()
    }

    private func focusCard() {
        if let widget = card?.widget { gtk_widget_grab_focus(widget) }
    }

    private static func sentence(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: ". ")
    }

    func refresh() {
        let bindings = ShortcutBindings.load()
        renderNow(bindings)
        renderCard()
        renderVerdict()
        if let widget = restore?.widget {
            gtk_widget_set_visible(widget, bindings.isCustomized(id) ? 1 : 0)
        }
    }

    private func currentEntry(_ bindings: ShortcutBindings) -> ShortcutEntry? {
        ShortcutEditor.sections(bindings: bindings).flatMap(\.entries).first { $0.id == id }
    }

    private func renderNow(_ bindings: ShortcutBindings) {
        guard let box = nowBox?.widget else { return }
        Gtk.removeChildren(of: box)
        let keys = currentEntry(bindings)?.keys ?? []
        guard !keys.isEmpty else {
            let none = Keycaps.strip([])
            gtk_widget_set_halign(none, GTK_ALIGN_START)
            gtk_box_append(ptr(box), none)
            return
        }
        for key in keys {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_box_append(ptr(row), Keycaps.key(key))
            if let scope = key.scope {
                gtk_box_append(
                    ptr(row), Gtk.label(scope, css: "dim-label", wrap: false, selectable: false))
            }
            let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            gtk_widget_set_hexpand(spacer, 1)
            gtk_box_append(ptr(row), spacer)
            let spec = key.spec
            let removeButton = Gtk.button("✕", css: ["flat", "circular"]) { [self] in
                Gtk.onMain { self.remove(spec) }
            }
            gtk_widget_set_tooltip_text(removeButton, Localized.text("Remove this key"))
            gtk_box_append(ptr(row), removeButton)
            gtk_box_append(ptr(box), row)
        }
    }

    private func renderCard() {
        guard let card = card?.widget else { return }
        Gtk.removeChildren(of: card)
        let content: UnsafeMutablePointer<GtkWidget>
        if chords.isEmpty {
            content = Gtk.label(
                Localized.text("Press the keys you want…"), css: "key-capture-prompt", wrap: true,
                selectable: false)
            gtk_label_set_xalign(op(content), 0.5)
            gtk_label_set_justify(op(content), GTK_JUSTIFY_CENTER)
            gtk_widget_remove_css_class(card, "key-capture-live")
        } else {
            content = Keycaps.sequence(chords)
            gtk_widget_add_css_class(card, "key-capture-live")
        }
        gtk_widget_set_halign(content, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(content, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(content, 1)
        gtk_box_append(ptr(card), content)
    }

    private func renderVerdict() {
        guard let label = verdict?.widget else { return }
        let state = verdictNow()
        let (words, bad) = Self.reading(
            of: state, failure: failure, afterNote: afterNote)
        gtk_label_set_text(op(label), words)
        gtk_widget_set_visible(label, words.isEmpty ? 0 : 1)
        if bad {
            gtk_widget_add_css_class(label, "key-capture-bad")
        } else {
            gtk_widget_remove_css_class(label, "key-capture-bad")
        }
        guard let button = primary?.widget else { return }
        if case .ready(_, _, let conflicts) = state {
            gtk_widget_set_sensitive(button, 1)
            gtk_button_set_label(
                ptr(button),
                conflicts.isEmpty ? Localized.text("Add key") : Localized.text("Take it"))
        } else {
            gtk_widget_set_sensitive(button, 0)
            gtk_button_set_label(ptr(button), Localized.text("Add key"))
        }
    }

    /// The line under the card: what pressing this would do, in words, and whether it is a
    /// refusal. A failure to write outranks everything, because it is the one thing the person
    /// cannot see coming.
    static func reading(
        of verdict: Verdict, failure: String?, afterNote: String?
    ) -> (words: String, bad: Bool) {
        if let failure { return (failure, true) }
        switch verdict {
        case .idle:
            return (afterNote ?? "", false)
        case .unreadable:
            return (Localized.text("Not a shortcut I can read"), true)
        case .refused(let reason):
            return (reason, true)
        case .already:
            return (Localized.text("This action already has that key"), false)
        case .ready(_, let note, let conflicts):
            var lines = conflicts.isEmpty ? [Localized.text("Free")] : conflicts.map(conflictWords)
            if let note { lines.append(note) }
            return (lines.joined(separator: "\n"), false)
        }
    }

    private static func conflictWords(_ conflict: ShortcutEditor.Conflict) -> String {
        switch conflict.kind {
        case .sameKey:
            return Localized.text(
                "“%@” also uses this key. Adding it here takes it from there.", conflict.title)
        case .startsSequence:
            return Localized.text(
                "“%@” has a two-key shortcut (%@) that starts with this key, so it would stop working. Adding it here takes that shortcut from there.",
                conflict.title, conflict.display)
        case .beginsWithKey:
            return Localized.text(
                "“%@” uses %@ on its own, so this two-key shortcut could never be reached. Adding it here takes that key from there.",
                conflict.title, conflict.display)
        }
    }
}
