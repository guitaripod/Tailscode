import AppKit
import TailscodeCore

extension QuickAskPanel: MacDictationHost {
    var dictationEditor: PromptEditor { editor }

    var dictationSendControl: NSView { sendButton }

    var dictationKey: String { "quickask" }

    var dictationChord: String? { ComposerView.dictationChordWords }

    /// A quick ask has no transcript yet, so the words it knows are what is on offer from the
    /// pasteboard, the aimed machine's commands and the model it would ask.
    func dictationVocabulary() -> DictationVocabulary {
        DictationVocabulary.read(
            messages: [], commands: commands.map(\.name),
            models: [QuickAskDefaults.model(forProfileID: targetServer.id)?.modelID].compactMap { $0 },
            notes: [copied?.headline, copied?.preview].compactMap { $0 })
    }

    func dictationSend() { submit() }
}
