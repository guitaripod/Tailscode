import Foundation

/// A key on a keyboard, named by where it is and not by what it types: the numbering is the
/// engine's own, which follows the W3C key codes. A client maps its toolkit's key to one of these
/// and hands over what the key typed beside it; which bytes that becomes is the terminal's to say,
/// because it depends on what the program on the other side has asked for.
public struct TerminalKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let unidentified = TerminalKey(rawValue: 0)
    public static let backquote = TerminalKey(rawValue: 1)
    public static let backslash = TerminalKey(rawValue: 2)
    public static let bracketLeft = TerminalKey(rawValue: 3)
    public static let bracketRight = TerminalKey(rawValue: 4)
    public static let comma = TerminalKey(rawValue: 5)
    public static let equal = TerminalKey(rawValue: 16)
    public static let minus = TerminalKey(rawValue: 46)
    public static let period = TerminalKey(rawValue: 47)
    public static let quote = TerminalKey(rawValue: 48)
    public static let semicolon = TerminalKey(rawValue: 49)
    public static let slash = TerminalKey(rawValue: 50)
    public static let backspace = TerminalKey(rawValue: 53)
    public static let enter = TerminalKey(rawValue: 58)
    public static let space = TerminalKey(rawValue: 63)
    public static let tab = TerminalKey(rawValue: 64)
    public static let delete = TerminalKey(rawValue: 68)
    public static let end = TerminalKey(rawValue: 69)
    public static let home = TerminalKey(rawValue: 71)
    public static let insert = TerminalKey(rawValue: 72)
    public static let pageDown = TerminalKey(rawValue: 73)
    public static let pageUp = TerminalKey(rawValue: 74)
    public static let arrowDown = TerminalKey(rawValue: 75)
    public static let arrowLeft = TerminalKey(rawValue: 76)
    public static let arrowRight = TerminalKey(rawValue: 77)
    public static let arrowUp = TerminalKey(rawValue: 78)
    public static let numpadEnter = TerminalKey(rawValue: 97)
    public static let escape = TerminalKey(rawValue: 120)

    /// 0 through 9 on the digit row.
    public static func digit(_ value: Int) -> TerminalKey {
        TerminalKey(rawValue: UInt32(6 + min(max(value, 0), 9)))
    }

    /// The letter keys, by their letter in the Latin alphabet: a is 0.
    public static func letter(_ index: Int) -> TerminalKey {
        TerminalKey(rawValue: UInt32(20 + min(max(index, 0), 25)))
    }

    /// F1 through F25.
    public static func function(_ number: Int) -> TerminalKey {
        TerminalKey(rawValue: UInt32(120 + min(max(number, 1), 25)))
    }

    /// 0 through 9 on the number pad.
    public static func numpad(_ value: Int) -> TerminalKey {
        TerminalKey(rawValue: UInt32(80 + min(max(value, 0), 9)))
    }

    /// The key that types `character` on a US keyboard, for a toolkit that reports a key by the
    /// unmodified character it produces: letters, digits and the punctuation that has a key of
    /// its own.
    public static func typing(_ character: Character) -> TerminalKey {
        guard let scalar = character.lowercased().unicodeScalars.first, scalar.isASCII else {
            return .unidentified
        }
        switch scalar.value {
        case 0x61...0x7a: return letter(Int(scalar.value - 0x61))
        case 0x30...0x39: return digit(Int(scalar.value - 0x30))
        case 0x20: return .space
        case 0x60: return .backquote
        case 0x5c: return .backslash
        case 0x5b: return .bracketLeft
        case 0x5d: return .bracketRight
        case 0x2c: return .comma
        case 0x3d: return .equal
        case 0x2d: return .minus
        case 0x2e: return .period
        case 0x27: return .quote
        case 0x3b: return .semicolon
        case 0x2f: return .slash
        default: return .unidentified
        }
    }
}

public struct TerminalModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let shift = TerminalModifiers(rawValue: 1 << 0)
    public static let control = TerminalModifiers(rawValue: 1 << 1)
    public static let alt = TerminalModifiers(rawValue: 1 << 2)
    /// Command on a Mac, the logo key elsewhere.
    public static let command = TerminalModifiers(rawValue: 1 << 3)
}

/// One press of a key.
public struct TerminalKeyPress: Sendable, Equatable {
    public var key: TerminalKey
    public var modifiers: TerminalModifiers
    /// What the key typed with its modifiers, when it typed anything a person would call text.
    /// Empty for arrows, function keys and anything held with Control.
    public var text: String
    /// The character on the key cap, without Shift: `a` for the A key however it was pressed.
    public var unshifted: Character?
    public var isRepeat: Bool

    public init(
        key: TerminalKey, modifiers: TerminalModifiers = [], text: String = "",
        unshifted: Character? = nil, isRepeat: Bool = false
    ) {
        self.key = key
        self.modifiers = modifiers
        self.text = text
        self.unshifted = unshifted
        self.isRepeat = isRepeat
    }
}
