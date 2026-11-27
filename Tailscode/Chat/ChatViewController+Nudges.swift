import TailscodeCore
import UIKit

extension ChatViewController {
    /// Resume and Status? for this chat, at the head of its own menu: offered only while the chat
    /// is quiet and has been spoken to.
    func nudgeMenuElement() -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self,
                ChatNudge.offers(
                    running: self.viewModel.isBusy,
                    hasTranscript: !self.viewModel.state.messages.isEmpty)
            else { return completion([]) }
            completion([
                UIMenu(
                    options: .displayInline,
                    children: ChatNudge.all.map { nudge in
                        UIAction(
                            title: nudge.title, subtitle: nudge.hint,
                            image: UIImage(systemName: nudge.symbol)
                        ) { [weak self] _ in self?.sendNudge(nudge) }
                    })
            ])
        }
    }

    /// The nudge's words through this chat's ordinary send, leaving the box, its draft and
    /// anything clipped to it exactly as they are.
    func sendNudge(_ nudge: ChatNudge) {
        guard !viewModel.isBusy else { return }
        Theme.Haptics.send()
        userScrolledUp = false
        animateNextRender = true
        viewModel.send(nudge.prompt, model: nil, effort: nil, attachments: [])
    }
}
