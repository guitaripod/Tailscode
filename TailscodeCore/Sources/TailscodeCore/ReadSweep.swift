import CodingAgentKit
import Foundation

/// What one press of "Mark all as read" reads, and whether there is anything for it to read.
///
/// A chat is news while it is unread at rest. A turn in flight is unread for as long as it runs,
/// because its clock moves with every token, so reading it is undone by the next one: the press
/// offered for it never went away, and pressing it again found the same chat unread a second
/// later. Such a row already wears its activity in the state column instead of the dot, so the
/// sweep leaves it, and its ending is news when it lands. The listed rows decide for the saved
/// copies of themselves; a saved chat that no listing holds is read on its own copy.
public struct ReadSweep: Equatable, Sendable {
    public let chats: [String]
    public let notices: Int

    public init(chats: [String], notices: Int) {
        self.chats = chats
        self.notices = notices
    }

    /// Whether the press has anything to do, which is whether it is offered.
    public var isEmpty: Bool { chats.isEmpty && notices == 0 }

    public static func reading(
        entries: [SessionEntry], saved: [SavedChat], presence: [String: SessionPresence],
        unreachable: Set<String>, notices: Int, isUnread: (String, Date) -> Bool
    ) -> ReadSweep {
        var chats: [String] = []
        var taken = Set<String>()
        var decided = Set<String>()
        for entry in entries {
            let id = entry.session.id
            guard decided.insert(SessionPinStore.key(entry.profileID, id)).inserted else { continue }
            let state = SessionRowModel.resolvedState(
                entry: entry, unreachable: unreachable.contains(entry.profileID),
                presence: presence[id] ?? .unobserved)
            guard !state.isInFlight, isUnread(id, entry.session.updatedAt) else { continue }
            if taken.insert(id).inserted { chats.append(id) }
        }
        for chat in saved
        where decided.insert(SessionPinStore.key(chat.profileID, chat.sessionID)).inserted {
            guard isUnread(chat.sessionID, chat.updatedAt) else { continue }
            if taken.insert(chat.sessionID).inserted { chats.append(chat.sessionID) }
        }
        return ReadSweep(chats: chats, notices: notices)
    }
}
