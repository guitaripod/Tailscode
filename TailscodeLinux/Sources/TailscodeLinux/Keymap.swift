import CAdw
import Foundation
import TailscodeCore

/// What a key means, given where you are.
///
/// The app is modal the way vim is: normal mode owns the letters, insert mode gives them back.
/// Focusing anything that takes text — the composer, the terminal, a search field — enters insert
/// implicitly, and Escape leaves it; nothing here fights the pointer, so every binding has a thing
/// you can also click.
enum Pane: CaseIterable {
    case chats
    case transcript
    case files
    case terminal
}

enum KeyAction: Equatable {
    case focus(Pane)
    case cycleForward
    case cycleBackward
    case selectNext
    case selectPrevious
    case selectFirst
    case selectLast
    case openSelected
    case scrollDown
    case scrollUp
    case halfPageDown
    case halfPageUp
    case scrollTop
    case scrollBottom
    case insert
    case leaveInsert
    case search
    case send
    case stop
    case toggleHelp
    case reload
}

enum Keymap {
    /// GDK keyvals, spelled out rather than imported: the constants are macros in C and would need
    /// their own shim, and the whole table is more readable as one list anyway.
    static let escape: UInt32 = 0xFF1B
    static let enter: UInt32 = 0xFF0D
    static let keypadEnter: UInt32 = 0xFF8D
    static let slash: UInt32 = 0x002F
    static let question: UInt32 = 0x003F
    static let colon: UInt32 = 0x003A
    static let tab: UInt32 = 0xFF09
    static let shiftTab: UInt32 = 0xFE20

    static let control: UInt32 = 1 << 2
    static let shift: UInt32 = 1 << 0

    /// The binding for a key in normal mode, or nil if the key should be left alone.
    static func normal(keyval: UInt32, state: UInt32, pending: String) -> KeyAction? {
        let isControl = state & control != 0
        if isControl {
            switch scalar(keyval) {
            case "d": return .halfPageDown
            case "u": return .halfPageUp
            case "n": return .selectNext
            case "p": return .selectPrevious
            case "c": return .stop
            case "h": return .focus(.chats)
            case "j": return .focus(.terminal)
            case "k": return .focus(.transcript)
            case "l": return .focus(.files)
            case "r": return .reload
            default: return nil
            }
        }
        switch keyval {
        case escape: return .leaveInsert
        case enter, keypadEnter: return .openSelected
        case tab: return .cycleForward
        case shiftTab: return .cycleBackward
        case slash: return .search
        case question: return .toggleHelp
        default: break
        }
        switch scalar(keyval) {
        case "j": return .scrollDown
        case "k": return .scrollUp
        case "J": return .selectNext
        case "K": return .selectPrevious
        case "g": return pending == "g" ? .scrollTop : nil
        case "G": return .scrollBottom
        case "i", "a", "o": return .insert
        case "q": return .stop
        default: return nil
        }
    }

    /// In insert mode only the leaving keys and the deliberate chords are ours; everything else
    /// belongs to whatever is being typed into.
    static func insert(keyval: UInt32, state: UInt32) -> KeyAction? {
        if keyval == escape { return .leaveInsert }
        if state & control != 0, keyval == enter || keyval == keypadEnter { return .send }
        return nil
    }

    static func scalar(_ keyval: UInt32) -> Character? {
        guard let scalar = Unicode.Scalar(keyval), keyval < 0x110000 else { return nil }
        return Character(scalar)
    }

    static var help: [(keys: String, what: String)] {
        [
            ("j / k", Localized.text("Scroll the transcript")),
            ("gg / G", Localized.text("Top / bottom")),
            ("^d / ^u", Localized.text("Half page down / up")),
            ("J / K", Localized.text("Next / previous chat")),
            ("^n / ^p", Localized.text("Next / previous chat")),
            ("⏎", Localized.text("Open the selected chat")),
            ("i", Localized.text("Write a message")),
            ("^⏎", Localized.text("Send")),
            ("esc", Localized.text("Back to normal mode")),
            ("^h ^k ^l ^j", Localized.text("Focus chats / transcript / files / terminal")),
            ("tab", Localized.text("Cycle panes")),
            ("/", Localized.text("Filter chats")),
            ("^r", Localized.text("Refresh now")),
            ("q / ^c", Localized.text("Stop the running turn")),
            ("?", Localized.text("This list")),
        ]
    }
}
