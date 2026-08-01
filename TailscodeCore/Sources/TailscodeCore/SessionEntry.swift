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
}
