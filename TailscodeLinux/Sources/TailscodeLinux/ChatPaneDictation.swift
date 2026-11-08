import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension ChatPane: DictationPaneHost {
    var dictationEditor: PromptEditor { editor }

    var dictationWindow: UnsafeMutablePointer<GtkWidget>? { host?.window }

    var dictationSendTarget: UnsafeMutablePointer<GtkWidget>? {
        gtk_widget_get_visible(sendButton) != 0 ? sendButton : stopButton
    }

    var dictationKey: String { "pane-\(id)" }

    var dictationCallLive: Bool { call.isOwner }

    var dictationShortcuts: ShortcutSet { host?.shortcuts ?? ShortcutSet.load() }

    /// The words this chat knows, read from the tail of what it holds when the microphone opens.
    func dictationVocabulary() -> DictationVocabulary {
        let project = entry?.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent }
        return DictationVocabulary.read(
            messages: lastState?.messages ?? [], project: project, branch: git?.title,
            commands: commands.map(\.name), models: [chosenModel?.modelID].compactMap { $0 })
    }

    func dictationSend() { sendFromComposer() }

    func dictationAnnounce(_ words: String) { announce(words) }
}
