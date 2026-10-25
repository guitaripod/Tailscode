import AppKit
import Carbon.HIToolbox
import TailscodeCore

/// The NSEvent half of the shared shortcut system: one canonical key-code space (GDK's, because
/// the registry was born there), so `~/.config/tailscode/keybindings.json` means the same thing
/// on this Mac as on the Linux desktop.
/// A view pressed from the keyboard with Space or Return once Full Keyboard Access makes it a stop
/// in the Tab loop — a row that opens, a picture that opens its viewer. The window's key monitor
/// sees those keys before the view does, and would spend them on the chat list's own Space and
/// Return.
@MainActor
protocol KeyboardPressable: NSView {}

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

    /// F1 to F12 in order. They arrive with private-use characters (U+F704 and up) that mean
    /// nothing in the registry's space, so the key code is what names them.
    private static let functionKeyCodes: [UInt16] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
    ]

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
        case 115: return Keymap.home
        case 119: return Keymap.end
        case 116: return Keymap.pageUp
        case 121: return Keymap.pageDown
        case 117: return Keymap.delete
        default: break
        }
        if let number = functionKeyCodes.firstIndex(of: event.keyCode) {
            return Keymap.functionKey(number + 1)
        }
        /// `charactersIgnoringModifiers` keeps shift's work (`J`, `?`) while dropping control's
        /// (^C arrives as the letter, not as 0x03), which is exactly the shape the canonicaliser
        /// expects from GDK.
        guard let characters = event.charactersIgnoringModifiers,
            let scalar = characters.unicodeScalars.first, scalar.value >= 0x20
        else { return nil }
        guard scalar.value > 0x7E else { return UInt32(scalar.value) }
        return latinKeyval(for: event) ?? UInt32(scalar.value)
    }

    /// What the key under the finger would type on a Latin keyboard.
    ///
    /// The registry is written in one key space, and a Cyrillic, Greek or Hebrew layout answers
    /// `charactersIgnoringModifiers` with its own alphabet — so `ctrl+w`, `j`, `g g`, `?` and every
    /// other chord would resolve to a keyval nothing is bound to, and the whole non-⌘ layer would
    /// go dead with nothing said about it. macOS solves exactly this for menu equivalents by
    /// consulting the ASCII-capable layout; this asks that layout the same question, and keeps
    /// shift in the question so `shift+/` is still `?` rather than `/`.
    private static func latinKeyval(for event: NSEvent) -> UInt32? {
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        var deadKeys: UInt32 = 0
        var produced = 0
        var translated = [UniChar](repeating: 0, count: 4)
        let shift: UInt32 = event.modifierFlags.contains(.shift) ? UInt32(shiftKey >> 8) : 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, event.keyCode, UInt16(kUCKeyActionDown), shift,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys,
                translated.count, &produced, &translated)
        }
        guard status == noErr, produced > 0, translated[0] >= 0x20, translated[0] <= 0x7E
        else { return nil }
        return UInt32(translated[0])
    }
}
