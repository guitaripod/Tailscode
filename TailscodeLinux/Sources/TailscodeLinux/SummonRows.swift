import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The settings group for the key taken from the whole machine. It shows the chord, what the
/// desktop actually did with it, and the one line that reaches a Tailscode which is not running —
/// three facts rather than a switch, because a global shortcut is the one setting whose failure is
/// invisible from inside the app.
enum SummonRows {
    static func install(on page: UnsafeMutablePointer<GtkWidget>, window: UnsafeMutablePointer<GtkWidget>) {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(ptr(group), Localized.text("Ask from anywhere"))
        adw_preferences_group_set_description(
            ptr(group),
            Localized.text(
                "One chord, pressed in any app on this machine, opens the question box."))
        adw_preferences_page_add(ptr(page), ptr(group))

        let toggle = adw_switch_row_new()!
        adw_preferences_row_set_title(ptr(toggle), Localized.text("Summon with a chord"))
        adw_switch_row_set_active(OpaquePointer(toggle), SummonSettings.isEnabled ? 1 : 0)
        Gtk.onNotify(UnsafeMutableRawPointer(toggle), property: "active") { [toggleBits = UInt(bitPattern: toggle)] in
            guard let raw = UnsafeMutableRawPointer(bitPattern: toggleBits) else { return }
            SummonSettings.setEnabled(adw_switch_row_get_active(op(raw)) != 0)
            Summon.shared.refresh()
        }
        adw_preferences_group_add(ptr(group), ptr(toggle))

        let chordRow = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(chordRow), Localized.text("Chord"))
        let parentBits = UInt(bitPattern: window)
        let chordButton = Gtk.button(
            SummonSettings.chord.display(on: .linux), css: ["flat"],
            onClick: {
                guard let raw = UnsafeMutableRawPointer(bitPattern: parentBits) else { return }
                record(parent: ptr(raw))
            })
        gtk_widget_set_valign(chordButton, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(chordRow), chordButton)
        adw_preferences_group_add(ptr(group), ptr(chordRow))

        let commandRow = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(commandRow), Localized.text("Or bind it yourself"))
        let copy = Gtk.button(Localized.text("Copy"), css: ["flat"]) {
            Gtk.copyToClipboard(Summon.shared.recipe.binding)
        }
        gtk_widget_set_valign(copy, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(commandRow), copy)
        adw_preferences_group_add(ptr(group), ptr(commandRow))

        let held = SummonRowsHeld(
            chordRow: UInt(bitPattern: chordRow), chordButton: UInt(bitPattern: chordButton),
            commandRow: UInt(bitPattern: commandRow))
        held.render()
        let watch = SummonWatch()
        watch.token = NotificationCenter.default.addObserver(
            forName: Summon.didChange, object: nil, queue: nil
        ) { _ in
            Gtk.onMain { held.render() }
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { watch.stop() }
    }

    /// The chord is chosen by pressing it, not by reading a list of key names: what a person wants
    /// is the thing their hand already does. The dialog says what the press would cost before it
    /// takes it, and refuses the ones that would quietly break another program.
    private static func record(parent: UnsafeMutablePointer<GtkWidget>) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Press the chord"), parent: parent, width: 420)
        let heard = Gtk.label(
            Localized.text("Waiting for a chord…"), css: "summon-chord", wrap: true)
        gtk_widget_add_css_class(heard, "title-2")
        gtk_box_append(ptr(content), heard)
        let note = Gtk.label(
            Localized.text(
                "It has to be a chord no text field can want — two modifiers is the safe shape."),
            css: "row-detail", wrap: true)
        gtk_box_append(ptr(content), note)

        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(box, GTK_ALIGN_END)
        let state = RecorderState()
        let heardBits = UInt(bitPattern: heard)
        let noteBits = UInt(bitPattern: note)
        let windowBits = UInt(bitPattern: window)
        let apply = Gtk.button(Localized.text("Use it"), css: ["suggested-action"]) {
            guard let chord = state.chord else { return }
            SummonSettings.setChord(chord)
            Summon.shared.refresh()
            if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                gtk_window_destroy(ptr(raw))
            }
        }
        gtk_widget_set_sensitive(apply, 0)
        let applyBits = UInt(bitPattern: apply)
        gtk_box_append(
            ptr(box),
            Gtk.button(Localized.text("Cancel"), css: ["flat"]) {
                if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                    gtk_window_destroy(ptr(raw))
                }
            })
        gtk_box_append(ptr(box), apply)
        gtk_box_append(ptr(content), box)

        Gtk.onKey(window) { keyval, modifiers in
            guard let chord = SummonChord(keyval: keyval, state: modifiers) else { return true }
            state.chord = nil
            let judgement = SummonJudge.judge(chord, on: .linux)
            if case .fine = judgement { state.chord = chord }
            if case .caution = judgement { state.chord = chord }
            if let raw = UnsafeMutableRawPointer(bitPattern: heardBits) {
                gtk_label_set_text(op(raw), chord.display(on: .linux))
            }
            if let raw = UnsafeMutableRawPointer(bitPattern: noteBits) {
                gtk_label_set_text(
                    op(raw),
                    judgement.note
                        ?? Localized.text("Nothing on this machine is likely to want this one."))
            }
            if let raw = UnsafeMutableRawPointer(bitPattern: applyBits) {
                gtk_widget_set_sensitive(ptr(raw), state.chord == nil ? 0 : 1)
            }
            return true
        }
        gtk_window_present(ptr(window))
    }

    private final class RecorderState: @unchecked Sendable {
        var chord: SummonChord?
    }

    /// The observer the group keeps while its window exists. The token is not `Sendable`, and a
    /// settings window that closed without dropping it would leave the portal talking to rows GTK
    /// has already destroyed.
    private final class SummonWatch: @unchecked Sendable {
        var token: NSObjectProtocol?

        func stop() {
            guard let token else { return }
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }
}

/// The rows the summon group owns, so the state the portal reports later lands on the rows that
/// are already on screen rather than on a group that has to be rebuilt.
final class SummonRowsHeld: @unchecked Sendable {
    private let chordRow: UInt
    private let chordButton: UInt
    private let commandRow: UInt

    init(chordRow: UInt, chordButton: UInt, commandRow: UInt) {
        self.chordRow = chordRow
        self.chordButton = chordButton
        self.commandRow = commandRow
    }

    func render() {
        let state = Summon.shared.state
        if let raw = UnsafeMutableRawPointer(bitPattern: chordRow) {
            adw_action_row_set_subtitle(
                ptr(raw),
                [state.line(on: .linux), state.detail(on: .linux)]
                    .compactMap { $0 }.joined(separator: " · "))
        }
        if let raw = UnsafeMutableRawPointer(bitPattern: chordButton) {
            gtk_button_set_label(ptr(raw), SummonSettings.chord.display(on: .linux))
        }
        if let raw = UnsafeMutableRawPointer(bitPattern: commandRow) {
            let recipe = Summon.shared.recipe
            adw_action_row_set_subtitle(ptr(raw), "\(recipe.binding) — \(recipe.instruction)")
        }
    }
}

extension SummonChord {
    /// A press as GDK reports it, read as the chord a person meant: the letter rather than the
    /// shifted glyph, the lock and pointer bits dropped, and a bare modifier ignored so holding
    /// Ctrl on the way to a chord does not register as one.
    init?(keyval: UInt32, state: UInt32) {
        guard !(0xFFE1...0xFFEE).contains(keyval) else { return nil }
        let control = state & KeyChord.controlMask != 0
        let shift = state & KeyChord.shiftMask != 0
        let alt = state & KeyChord.altMask != 0
        let meta = state & (1 << 26) != 0 || state & (1 << 6) != 0
        guard let name = SummonChord.keyName(for: keyval) else { return nil }
        self.init(control: control, alt: alt, shift: shift, meta: meta, key: name)
    }

    private static func keyName(for keyval: UInt32) -> String? {
        switch keyval {
        case 0xFF08...0xFF1B:
            switch keyval {
            case 0xFF09: return "tab"
            case 0xFF0D: return "return"
            case 0xFF1B: return "escape"
            default: return nil
            }
        case 0xFF51: return "left"
        case 0xFF52: return "up"
        case 0xFF53: return "right"
        case 0xFF54: return "down"
        case 0xFFBE...0xFFC9: return "f\(keyval - 0xFFBD)"
        case 0x20: return "space"
        default: break
        }
        guard keyval < 0x80, let scalar = Unicode.Scalar(keyval) else { return nil }
        let character = Character(scalar)
        if character.isLetter || character.isNumber {
            return String(character).lowercased()
        }
        switch character {
        case ".": return "period"
        case ",": return "comma"
        case "/": return "slash"
        case "`": return "grave"
        case "-": return "minus"
        case "=": return "equal"
        default: return nil
        }
    }
}
