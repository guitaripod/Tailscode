import TailscodeCore
import UIKit

extension ComposerView: DictationComposerHost {
    var dictationTextView: UITextView { textView }
    var dictationBox: UIView { bar }
    var dictationSendControl: UIView { sendButton }

    var dictationPresenter: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    func dictationDidWrite() {
        textViewDidChange(textView)
        paintInk(force: true)
    }

    func dictationSend() { sendTapped() }

    func dictationSetListening(_ listening: Bool) {
        placeholder.text = listening ? DictationReading.listeningPlaceholder : restingPlaceholder
        UIView.animate(withDuration: 0.2) { self.auraHost.alpha = listening ? 0 : 1 }
        refreshDoors()
        if !listening { paintInk(force: true) }
    }

    func dictationShowStatus(_ status: DictationHintView, shown: Bool) {
        guard shown || status.superview === self else { return }
        if status.superview !== self {
            addSubview(status)
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
                status.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
                status.trailingAnchor.constraint(
                    lessThanOrEqualTo: dictation.button.leadingAnchor, constant: -Theme.Spacing.s),
            ])
        }
        guard shown != statusShown else { return }
        statusShown = shown
        accessory?.isUserInteractionEnabled = !shown
        attachButton.isUserInteractionEnabled = !shown
        DictationSeat.move {
            self.applyLayout()
            status.alpha = shown ? 1 : 0
            self.accessory?.alpha = shown ? 0 : 1
            self.attachButton.alpha = shown ? 0 : 1
            self.superview?.layoutIfNeeded()
        }
    }
}
