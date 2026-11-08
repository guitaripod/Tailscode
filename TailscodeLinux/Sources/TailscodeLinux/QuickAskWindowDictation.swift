import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension QuickAskWindow: DictationPaneHost {
    var dictationEditor: PromptEditor { editor }

    var dictationWindow: UnsafeMutablePointer<GtkWidget>? { window }

    var dictationSendTarget: UnsafeMutablePointer<GtkWidget>? { send }

    var dictationKey: String { "quickask" }

    var dictationCallLive: Bool { false }

    var dictationShortcuts: ShortcutSet { shortcuts }

    /// A quick ask has no transcript yet, so the words it knows are what is on offer from the
    /// clipboard, the aimed machine's commands and the model it would ask.
    func dictationVocabulary() -> DictationVocabulary {
        DictationVocabulary.read(
            messages: [], commands: commands.map(\.name),
            models: [QuickAskDefaults.model(forProfileID: targetServer.id)?.modelID].compactMap { $0 },
            notes: [copied?.headline, copied?.preview].compactMap { $0 })
    }

    func dictationSend() { submit() }

    func dictationAnnounce(_ words: String) {
        guard tailscode_can_announce() != 0, !words.isEmpty else { return }
        tailscode_accessible_announce(window, words, 0)
    }

    /// The microphone's keys come before every other: while a take is open Esc throws it away
    /// rather than putting the window away, ⏎ settles it and asks, and Alt+⏎ keeps what is shown
    /// and asks the party. The dictation chord is the registry's, so a rebound chord is the one
    /// that listens here too.
    func handleDictationKey(keyval: UInt32, state: UInt32) -> Bool {
        let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
        if dictation.isOpen, isReturn, state & KeyChord.altMask != 0 {
            dictation.stopKeepingShown()
            Gtk.onMain { [weak self] in self?.submitToParty() }
            return true
        }
        if dictation.handleKey(keyval: keyval, state: state) { return true }
        guard let chord = KeyChord.canonical(keyval: keyval, state: state),
            case .run(.dictate) = shortcuts.resolve(chord, context: .insert, pending: [], awaitingApproval: false)
        else { return false }
        dictation.chordDown(keyval: keyval)
        return true
    }

    /// The quick ask over the scripted fleet, listening with the scripted engine, for the drive
    /// verb that photographs it. The window kept for the next summon is built again so it takes
    /// the scripted engine.
    static func stageDictation(parent: UnsafeMutablePointer<GtkWidget>?) {
        open?.close()
        if let standby { gtk_window_destroy(ptr(standby.window)) }
        standby = nil
        dictationDemo = (true, 0.22)
        QuickAskPartyDemo.present(parent: parent)
        Gtk.after(900) {
            Gtk.onMain {
                open?.dictation.harnessPress()
                open?.dictation.harnessRelease()
            }
        }
    }
}
