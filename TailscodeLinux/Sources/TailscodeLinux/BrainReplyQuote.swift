import CAdw
import CGtkShim
import Foundation

extension PromptEditor {
    /// Puts a quote of what the agent said into the box at the caret, on a line of its own, and
    /// leaves the caret under it in insert mode with the keyboard on the box. Nothing is sent: the
    /// reply is what the person writes next and sends the ordinary way.
    func insertReplyQuote(_ quote: String) {
        let current = text
        let place = max(0, min(cursor, current.count))
        let before = current.prefix(place)
        let separator = before.isEmpty || before.hasSuffix("\n") ? "" : "\n"
        insertAtCaret(separator + quote)
        vim.reset(to: text, cursor: cursor, mode: .insert)
        refreshMode()
        focus()
    }
}
