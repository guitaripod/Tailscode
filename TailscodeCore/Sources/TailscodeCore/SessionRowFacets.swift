import CodingAgentKit
import Foundation

/// A chat row's second line, kept in pieces instead of joined into one dim run of words.
///
/// Four facts at one weight is a line that has to be read; the same four given three weights and
/// a column is a line that is scanned. The project is what a person recognises a conversation by,
/// the origin is only ever used to tell two machines apart, and the age belongs in a column of its
/// own down the right edge — a number that means "how stale is this" is worthless when it sits at
/// the end of a sentence whose length changes every row.
public struct SessionRowFacets: Equatable, Sendable {
    /// The directory the conversation is in, which is the name people actually use for it.
    public let project: String?
    /// Which machine and which agent — omitted entirely when every row would say the same thing.
    public let origin: String?
    /// How long ago it last moved, compact enough to line up as a column.
    public let age: String

    public init(project: String?, origin: String?, age: String) {
        self.project = project
        self.origin = origin
        self.age = age
    }

    /// The two left-hand facts as one string, for the clients and surfaces that only have room
    /// for a single label.
    public var lead: String {
        [project, origin].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What every row in a listing already has in common, so no row spends words repeating it.
///
/// A fleet of one server named on all 572 rows, or "Claude Code" written out once per row when
/// nothing else answers, is not information — it is the same word 572 times in the position a
/// reader's eye lands on. Computed once from the whole listing rather than per row, because
/// whether a fact distinguishes anything is a property of the list, never of one line in it.
public struct ChatListVocabulary: Equatable, Sendable {
    public let namesServer: Bool
    public let namesBackend: Bool

    public static let full = ChatListVocabulary(namesServer: true, namesBackend: true)

    public init(namesServer: Bool, namesBackend: Bool) {
        self.namesServer = namesServer
        self.namesBackend = namesBackend
    }

    /// The agent is named only when the machine does not already imply it — one server running
    /// two backends. Two servers each running their own is a distinction the machine's name
    /// already draws, and in a sidebar the width spent writing "Claude Code" on every row is
    /// taken straight out of the title, which is the only part that identifies the conversation.
    public init(rows: [SessionRowModel]) {
        var backendsPerServer: [String: Set<AgentType>] = [:]
        for row in rows {
            backendsPerServer[row.entry.profileID, default: []].insert(row.entry.backendType)
        }
        self.init(
            namesServer: backendsPerServer.count > 1,
            namesBackend: backendsPerServer.values.contains { $0.count > 1 })
    }
}
