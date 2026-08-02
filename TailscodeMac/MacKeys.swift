import AppKit
import TailscodeCore

/// The NSEvent half of the shared shortcut system: one canonical key-code space (GDK's, because
/// the registry was born there), so `~/.config/tailscode/keybindings.json` means the same thing
/// on this Mac as on the Linux desktop.
enum MacKeys {
    /// Command is deliberately absent: ⌘ chords belong to the menu bar, where macOS makes them
    /// discoverable and rebindable on its own. The registry speaks ctrl, shift and option.
    static func chord(for event: NSEvent) -> KeyChord? {
        guard !event.modifierFlags.contains(.command) else { return nil }
        guard let keyval = keyval(for: event) else { return nil }
        var state: UInt32 = 0
        if event.modifierFlags.contains(.control) { state |= KeyChord.controlMask }
        if event.modifierFlags.contains(.shift) { state |= KeyChord.shiftMask }
        if event.modifierFlags.contains(.option) { state |= KeyChord.altMask }
        return KeyChord.canonical(keyval: keyval, state: state)
    }

    private static func keyval(for event: NSEvent) -> UInt32? {
        switch event.keyCode {
        case 53: return Keymap.escape
        case 36: return Keymap.enter
        case 76: return Keymap.keypadEnter
        case 48: return Keymap.tab
        case 51: return Keymap.backspace
        case 126: return Keymap.up
        case 125: return Keymap.down
        case 123: return 0xFF51
        case 124: return 0xFF53
        default: break
        }
        /// `charactersIgnoringModifiers` keeps shift's work (`J`, `?`) while dropping control's
        /// (^C arrives as the letter, not as 0x03), which is exactly the shape the canonicaliser
        /// expects from GDK.
        guard let characters = event.charactersIgnoringModifiers,
            let scalar = characters.unicodeScalars.first, scalar.value >= 0x20
        else { return nil }
        return UInt32(scalar.value)
    }
}
