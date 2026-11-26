import Foundation

/// Whether opening a chat should ask the server what it says.
///
/// A chat opens onto a conversation this device already holds whenever it was left while a turn
/// ran, followed by a Live Activity, or covered by another screen. What the held transcript says
/// is what the stream last told this device, and a stream can be quiet while the server's
/// transcript moves — opencode's event bus belongs to one process, so a prompt sent from another
/// process on that machine never reaches a socket here. Opening the chat is the same question
/// re-entering it asks, and this decides whether asking is worth a read: what moved a moment ago
/// (the warm conversation a press starts, a turn already streaming onto the page) is current, and
/// a screen that has just asked is not asked again.
public enum ChatOpenRead {
    /// How old what a device holds may be before opening a chat asks again.
    public static let freshness: TimeInterval = 3

    public static func needed(
        hasTranscript: Bool, changedAt: Date?, lastAsked: Date?, now: Date = Date()
    ) -> Bool {
        guard hasTranscript else { return false }
        if let lastAsked, now.timeIntervalSince(lastAsked) < freshness { return false }
        guard let changedAt else { return true }
        return now.timeIntervalSince(changedAt) >= freshness
    }
}
