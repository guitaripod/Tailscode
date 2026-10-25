import Foundation

extension KeyChord {
    /// The grammar's spelling of this chord, which `KeySpec.parse` reads back as the same chord:
    /// modifiers in one fixed order, a lone Shift on a letter written as the capital the defaults
    /// table uses (`J`), and a key that has a name written by it.
    public var spec: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if alt { parts.append("alt") }
        let letter = Keymap.scalar(keyval)?.isLetter ?? false
        let capital = shift && letter && !control && !alt
        if shift && !capital { parts.append("shift") }
        let token = KeySpec.token(for: keyval)
        parts.append(capital ? token.uppercased() : token)
        return parts.joined(separator: "+")
    }

    /// The pieces of a keycap row for this chord: one cap per modifier, then the key.
    public func caps(on platform: SummonPlatform) -> [String] {
        var caps: [String] = []
        switch platform {
        case .linux:
            if control { caps.append("Ctrl") }
            if alt { caps.append("Alt") }
            if shift { caps.append("Shift") }
        case .apple:
            if control { caps.append("⌃") }
            if alt { caps.append("⌥") }
            if shift { caps.append("⇧") }
        }
        caps.append(Self.label(for: keyval, on: platform))
        return caps
    }

    /// A key as it is printed on a cap.
    static func label(for keyval: UInt32, on platform: SummonPlatform) -> String {
        let apple = platform == .apple
        switch keyval {
        case Keymap.enter: return apple ? "↩" : "Enter"
        case Keymap.escape: return apple ? "⎋" : "Esc"
        case Keymap.tab: return apple ? "⇥" : "Tab"
        case 0x20: return "Space"
        case Keymap.up: return "↑"
        case Keymap.down: return "↓"
        case 0xFF51: return "←"
        case 0xFF53: return "→"
        case Keymap.backspace: return apple ? "⌫" : "Backspace"
        case Keymap.delete: return apple ? "⌦" : "Delete"
        case Keymap.home: return apple ? "↖" : "Home"
        case Keymap.end: return apple ? "↘" : "End"
        case Keymap.pageUp: return apple ? "⇞" : "Page Up"
        case Keymap.pageDown: return apple ? "⇟" : "Page Down"
        case Keymap.insert: return "Insert"
        default:
            if let number = Keymap.functionNumber(keyval) { return "F\(number)" }
            if keyval < 0xFF00, let character = Keymap.scalar(keyval) {
                return String(character).uppercased()
            }
            return "0x\(String(keyval, radix: 16))"
        }
    }

    /// Whether a text field answers this key itself, so a binding that took it in the prompt box
    /// would break typing: select-all, the clipboard, undo, and word-wise movement and deletion.
    var belongsToTextEditing: Bool {
        guard control, !alt else { return false }
        switch keyval {
        case 0x61, 0x63, 0x78, 0x79: return !shift
        case 0x76, 0x7A: return true
        case Keymap.backspace, Keymap.delete, Keymap.home, Keymap.end, 0xFF51, 0xFF53: return true
        default: return false
        }
    }

    /// Whether a key a text field would type as a character is bare: with no Ctrl and no Alt, so
    /// that it means a letter rather than a command.
    var typesText: Bool {
        guard !control, !alt else { return false }
        if Keymap.functionNumber(keyval) != nil || keyval == Keymap.escape { return false }
        return true
    }
}

extension KeySpec {
    /// A whole binding as the grammar writes it: an optional `context:` prefix in the order the
    /// contexts are declared, then one or two chords.
    public static func spec(_ chords: [KeyChord], contexts: Set<KeyContext>? = nil) -> String {
        let body = chords.map(\.spec).joined(separator: " ")
        guard let contexts, !contexts.isEmpty else { return body }
        let named = KeyContext.allCases.filter(contexts.contains).map(\.rawValue)
        return "\(named.joined(separator: ",")):\(body)"
    }
}
