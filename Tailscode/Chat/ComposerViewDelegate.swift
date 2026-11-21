import UIKit

@MainActor
protocol ComposerViewDelegate: AnyObject {
    func composerDidSend(_ text: String)
    func composerTextDidChange(_ text: String)
    func composerDidLongPressSend(from view: UIView)
    func composerDidPasteLargeText(_ text: String)
    /// A picture on the pasteboard, pasted into the box. A screenshot is the commonest thing a
    /// phone has in hand, and making someone save it to Photos and pick it back up through the
    /// attach menu is a detour the clipboard already answered.
    func composerDidPasteImage(_ data: Data, mime: String)
    /// Built when the attach menu opens, so it always reflects what the model
    /// selected right now can actually accept.
    func composerAttachOptions() -> [UIMenuElement]
    func composerDidTapStop()
    func composerDidBeginEditing()
    /// The caret moved without the words changing, which is enough to walk into or out of a
    /// file's name.
    func composerSelectionDidChange()
    /// The last thing this person sent here, offered back from the empty box's own menu.
    func composerLastPrompt() -> String?
    func composerDidAskForLastPrompt()
}
