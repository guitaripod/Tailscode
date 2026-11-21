import TailscodeCore
import UIKit

extension ComposerView {
    /// A selection has verbs of its own beside the system's, and an empty box offers the last
    /// thing that was sent from it.
    func textView(
        _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        var verbs: [UIMenuElement] = []
        if range.length > 0 {
            verbs = [
                UIAction(title: DraftVerbs.codeTitle) { [weak self] _ in
                    self?.rewrite(range, by: DraftVerbs.code)
                },
                UIAction(title: DraftVerbs.quoteTitle) { [weak self] _ in
                    self?.rewrite(range, by: DraftVerbs.quote)
                },
            ]
        } else if (textView.text ?? "").isEmpty, delegate?.composerLastPrompt()?.isEmpty == false {
            verbs = [
                UIAction(title: DraftVerbs.lastPromptTitle) { [weak self] _ in
                    self?.delegate?.composerDidAskForLastPrompt()
                }
            ]
        }
        guard !verbs.isEmpty else { return nil }
        return UIMenu(children: Array(suggestedActions.prefix(1)) + verbs + suggestedActions.dropFirst())
    }

    private func rewrite(_ range: NSRange, by verb: (String) -> DraftVerbs.Edit) {
        let whole = (textView.text ?? "") as NSString
        guard range.location + range.length <= whole.length else { return }
        let edit = verb(whole.substring(with: range))
        replace(range.location..<(range.location + range.length), with: edit.text)
        textView.selectedRange = NSRange(
            location: range.location + edit.selectedStart, length: edit.selectedLength)
        Theme.Haptics.selection()
    }

    #if DEBUG
        /// Runs a selection verb over a stretch of the draft, for a run with no finger to open
        /// the menu.
        func stageVerb(_ name: String, over range: NSRange) {
            rewrite(range, by: name == "quote" ? DraftVerbs.quote : DraftVerbs.code)
        }

        /// One key the way the keyboard sends it, `<` deleting and `|` starting a line: the box is
        /// asked first, as the keyboard asks it, and a key it refuses is not typed.
        func stageKeystroke(_ key: Character) {
            let caret = textView.selectedRange
            let deleting = key == "<"
            let range =
                deleting && caret.length == 0
                ? NSRange(location: max(0, caret.location - 1), length: caret.location > 0 ? 1 : 0) : caret
            let written = deleting ? "" : (key == "|" ? "\n" : String(key))
            guard textView(textView, shouldChangeTextIn: range, replacementText: written) else { return }
            if deleting { textView.deleteBackward() } else { textView.insertText(written) }
        }

        /// One frame of a finger holding the handle this far above where it came down.
        func stageDrag(travel: CGFloat) {
            if heldCap == nil { beginHold() }
            hold(travel: travel)
        }

        func stageDragEnd() {
            heldCap = nil
            setLifted(true)
        }
    #endif
}
