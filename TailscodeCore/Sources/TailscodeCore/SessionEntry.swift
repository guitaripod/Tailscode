import CodingAgentKit
import Foundation

/// One session as the cross-server list knows it: the session itself plus which machine and
/// profile it came from. Identity is the pair (profile, session) — the same session id on two
/// servers is two different chats, and a session whose title or timestamp moved is still the
/// same row.
public struct SessionEntry: Hashable, Sendable {
    public let profileID: String
    public let profileName: String
    public let host: String
    public let backendType: AgentType
    public let session: AgentSession

    public init(
        profileID: String, profileName: String, host: String, backendType: AgentType,
        session: AgentSession
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.host = host
        self.backendType = backendType
        self.session = session
    }

    public static func == (lhs: SessionEntry, rhs: SessionEntry) -> Bool {
        lhs.profileID == rhs.profileID && lhs.session.id == rhs.session.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(profileID)
        hasher.combine(session.id)
    }

    /// The entry a pane should wear once a listing has named its conversation, or nil when there
    /// is nothing to take.
    ///
    /// A pane keeps the entry it was opened with, so a conversation the server titled after the
    /// pane opened would wear its first name for as long as it stayed open. The listing's title is
    /// taken only when it is a name: the untitled placeholder never replaces one a person has
    /// been reading, and an unchanged title is nothing to redraw. Everything else the pane opened
    /// with is kept, and a listing for another conversation is never adopted.
    public func adoptingTitle(from listed: SessionEntry) -> SessionEntry? {
        guard profileID == listed.profileID, session.id == listed.session.id,
            !listed.session.hasPlaceholderTitle, listed.session.title != session.title
        else { return nil }
        var renamed = session
        renamed.title = listed.session.title
        return SessionEntry(
            profileID: profileID, profileName: profileName, host: host,
            backendType: backendType, session: renamed)
    }
}
