import CAdw
import Foundation
import TailscodeCore

/// The app is modal the way vim is: normal mode owns the letters, insert mode gives them back.
/// Focusing anything that takes text enters insert implicitly and Escape leaves it; the terminal
/// keeps almost everything, because a shell's own chords are not the app's to take. What each key
/// does in each mode lives in `ShortcutRegistry`; nothing here fights the pointer, so every
/// binding has a thing you can also click.
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
    case allowOnce
    case allowAlways
    case deny
    case newChat
    case toggleSaved
    case commandPalette
    case findInConversation
    case zoomIn
    case zoomOut
    case zoomReset
    case toggleSidebar
    case toggleFiles
    case toggleTerminal
    case archiveSelected
    case toggleArchiveView
    case toggleUnreadSelected
    case renameSelected
    case forkSelected
    case deleteSelected
    case copySessionID
    case copyProjectPath
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
    static let up: UInt32 = 0xFF52
    static let down: UInt32 = 0xFF54

    static let control: UInt32 = 1 << 2
    static let shift: UInt32 = 1 << 0

    static func scalar(_ keyval: UInt32) -> Character? {
        guard let scalar = Unicode.Scalar(keyval), keyval < 0x110000 else { return nil }
        return Character(scalar)
    }
}
