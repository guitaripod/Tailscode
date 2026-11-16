import Foundation

/// When a notice already standing on a screen stops being news, every client takes it down.
///
/// A banner is an interruption about a chat. Once that chat has been read anywhere after the
/// banner appeared — opened on the phone, read at the desk, looked at on the iPad — the banner
/// interrupts about nothing, so it goes, question or not: the person has seen what it asked. The
/// Missed list keeps its own rule (a question stays listed until it is answered); this is only
/// about what is standing in Notification Center or on a desktop. The read mark is the one every
/// device already shares through the servers (`SessionSeenStore`), so each client applies the rule
/// on every listing it reads, and claude-bridge, which knows the moment a chat is read, also tells
/// a sleeping phone at once with a silent push carrying the chats under `pushKey`.
public enum NoticeWithdrawal {
    /// The key of a bridge's silent push that names the chats whose notices should come down.
    public static let pushKey = "withdraw"

    /// How much later than a notice a look must be to take it down, so two clocks a moment apart
    /// never take down news that arrived just after the person looked.
    public static let margin: TimeInterval = 2

    /// A notice standing somewhere: what it is called there, the chat it is about, and when it
    /// appeared.
    public struct Shown: Sendable, Equatable {
        public var identifier: String
        public var sessionID: String
        public var shownAt: Date

        public init(identifier: String, sessionID: String, shownAt: Date) {
            self.identifier = identifier
            self.sessionID = sessionID
            self.shownAt = shownAt
        }
    }

    /// The notices whose chat has been read since they appeared, by the same question the unread
    /// dot asks.
    public static func stale(_ shown: [Shown], isUnread: (String, Date) -> Bool) -> [String] {
        shown
            .filter { !$0.sessionID.isEmpty && !isUnread($0.sessionID, $0.shownAt.addingTimeInterval(margin)) }
            .map(\.identifier)
    }

    /// The chats a bridge's silent push says were read, empty when it says nothing about them.
    public static func sessions(inPush userInfo: [AnyHashable: Any]) -> Set<String> {
        guard let named = userInfo[pushKey] as? [Any] else { return [] }
        return Set(named.compactMap { $0 as? String }.filter { !$0.isEmpty })
    }
}
