import AppKit
import TailscodeCore

extension ComposerView {
    /// Whether the chat this box writes to offers its nudges in its own menu.
    var offersNudges: Bool {
        ChatNudge.offers(running: running, hasTranscript: !(lastState?.messages.isEmpty ?? true))
    }

    /// The nudge's words through this chat's ordinary send, on the model and level the box would
    /// send with, leaving whatever is in the box where it is.
    func sendNudge(_ nudge: ChatNudge) {
        onSubmitPrompt?(nudge.prompt, chosenModel, activeEffort, [])
    }
}
