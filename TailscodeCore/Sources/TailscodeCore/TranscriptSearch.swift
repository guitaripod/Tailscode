import CodingAgentKit
import Foundation

/// Searching every conversation on every machine, as one list.
///
/// A chat list matches titles, so everything actually said — the answer, the diff, the command
/// that finally worked — stops being findable the moment it scrolls off. This is the other half:
/// the fleet answers one query at once, and the results are one ranked list rather than a pile
/// per server.
///
/// It has to stay honest about coverage, because a search is read as an absence of results and an
/// absence is read as an answer. Servers differ: a bridge searches inside its own transcripts,
/// while a backend without the capability can only be matched on the titles this device already
/// holds. Every server says which of those it did, and a server that failed says so rather than
/// contributing nothing quietly.
public enum TranscriptSearch {
    /// Where a row came from and how much of it was actually looked at.
    public enum Coverage: Equatable, Sendable {
        /// The server read its own conversations.
        case searched(scanned: Int, truncated: Bool)
        /// The server cannot search inside conversations, so only the titles this device already
        /// knows were matched.
        case titlesOnly
        case failed(String)

        public var isFullySearched: Bool {
            if case .searched(_, let truncated) = self { return !truncated }
            return false
        }
    }

    public struct ServerOutcome: Equatable, Sendable, Identifiable {
        public let profileID: String
        public let name: String
        public let coverage: Coverage

        public var id: String { profileID }

        public init(profileID: String, name: String, coverage: Coverage) {
            self.profileID = profileID
            self.name = name
            self.coverage = coverage
        }
    }

    /// One conversation that matched, on one server.
    public struct Row: Hashable, Sendable, Identifiable {
        public let profileID: String
        public let profileName: String
        public let sessionID: String
        public let title: String
        public let directory: String?
        public let updatedAt: Date
        public let matches: [TranscriptMatch]
        /// Every place that matched in this conversation, which is usually more than are carried.
        public let total: Int

        public var id: String { "\(profileID)/\(sessionID)" }

        /// A conversation whose title matched but whose contents were never read. Worth saying: it
        /// is the difference between "this is where it was said" and "this might be the one".
        public var isTitleOnly: Bool { matches.isEmpty }

        /// The project the conversation lives in, as a person would name it.
        public var project: String? {
            guard let directory, !directory.isEmpty else { return nil }
            return (directory as NSString).lastPathComponent
        }

        public init(
            profileID: String, profileName: String, sessionID: String, title: String,
            directory: String?, updatedAt: Date, matches: [TranscriptMatch], total: Int
        ) {
            self.profileID = profileID
            self.profileName = profileName
            self.sessionID = sessionID
            self.title = title
            self.directory = directory
            self.updatedAt = updatedAt
            self.matches = matches
            self.total = total
        }
    }

    public struct Board: Equatable, Sendable {
        public let query: String
        public let rows: [Row]
        public let outcomes: [ServerOutcome]

        public init(query: String, rows: [Row], outcomes: [ServerOutcome]) {
            self.query = query
            self.rows = rows
            self.outcomes = outcomes
        }

        public var isEmpty: Bool { rows.isEmpty }
    }

    /// One server to ask, and what this device already knows about it.
    public struct Source: Sendable {
        public let profileID: String
        public let name: String
        public let backend: any CodingAgentBackend
        /// Sessions this device has already listed for the server, so a backend that cannot search
        /// inside its conversations can still be matched on their titles.
        public let entries: [SessionEntry]

        public init(
            profileID: String, name: String, backend: any CodingAgentBackend,
            entries: [SessionEntry]
        ) {
            self.profileID = profileID
            self.name = name
            self.backend = backend
            self.entries = entries
        }
    }

    /// Asks the whole fleet at once and merges the answers.
    ///
    /// Concurrent because the machines are: a fleet is only as slow as its slowest member, and one
    /// unreachable peer must not make the other two feel broken. A server that throws contributes
    /// its titles and an outcome that says it failed — never silence, which would read as "nothing
    /// there".
    public static func run(
        query: String, limit: Int = 40, deadline: Double = 15, sources: [Source]
    ) async -> Board {
        guard isSearchable(query) else { return Board(query: query, rows: [], outcomes: []) }
        var rows: [Row] = []
        var outcomes: [ServerOutcome] = []
        await withTaskGroup(of: (found: [Row], outcome: ServerOutcome).self) { group in
            for source in sources {
                group.addTask {
                    let titles = titleRows(
                        matching: query, entries: source.entries, profileName: { _ in source.name })
                    guard source.backend.capabilities.supportsTranscriptSearch else {
                        return (
                            titles,
                            ServerOutcome(
                                profileID: source.profileID, name: source.name,
                                coverage: .titlesOnly)
                        )
                    }
                    do {
                        let result = try await withDeadline(seconds: deadline) {
                            try await source.backend.searchTranscripts(query, limit: limit)
                        }
                        return (
                            Self.rows(
                                from: result, profileID: source.profileID,
                                profileName: source.name) + titles,
                            ServerOutcome(
                                profileID: source.profileID, name: source.name,
                                coverage: .searched(
                                    scanned: result.scanned, truncated: result.truncated))
                        )
                    } catch {
                        return (
                            titles,
                            ServerOutcome(
                                profileID: source.profileID, name: source.name,
                                coverage: .failed(Self.reason(error)))
                        )
                    }
                }
            }
            for await answer in group {
                rows.append(contentsOf: answer.found)
                outcomes.append(answer.outcome)
            }
        }
        return merge(query: query, rows: rows, outcomes: outcomes)
    }

    private struct Timeout: Error {}

    /// Bounds one server's answer. A fleet is only as slow as its slowest member, and a peer that
    /// has gone away holds an ordinary request open for the whole transport timeout — long enough
    /// that the two machines which did answer look broken too.
    private static func withDeadline<Value: Sendable>(
        seconds: Double, _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Timeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Timeout() }
            return first
        }
    }

    /// Why a server could not answer, in a few words rather than a raw URLError. A bridge too old
    /// to have the route is the common case and reads as a version, not a fault.
    private static func reason(_ error: any Error) -> String {
        if error is Timeout { return Localized.text("took too long") }
        if case AgentError.unsupported = error { return Localized.text("needs a newer bridge") }
        if let urlError = error as? URLError, urlError.code == .cannotConnectToHost {
            return Localized.text("unreachable")
        }
        return Localized.text("failed")
    }

    /// The words, as the search actually treats them: lowercased, split, all of them required.
    public static func terms(in query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    public static func isSearchable(_ query: String) -> Bool {
        !terms(in: query).isEmpty
    }

    /// Titles this device already holds, for a server that cannot search inside its own
    /// conversations. It is a poor substitute and it is labelled as one, but a fleet where one
    /// machine simply vanishes from every search is worse.
    public static func titleRows(
        matching query: String, entries: [SessionEntry], profileName: (String) -> String
    ) -> [Row] {
        let needles = terms(in: query)
        guard !needles.isEmpty else { return [] }
        return entries.filter { entry in
            let title = entry.session.title.lowercased()
            return needles.allSatisfy { title.contains($0) }
        }.map { entry in
            Row(
                profileID: entry.profileID, profileName: profileName(entry.profileID),
                sessionID: entry.session.id, title: entry.session.title,
                directory: entry.session.directory, updatedAt: entry.session.updatedAt,
                matches: [], total: 0)
        }
    }

    public static func rows(
        from result: TranscriptSearchResult, profileID: String, profileName: String
    ) -> [Row] {
        result.hits.map {
            Row(
                profileID: profileID, profileName: profileName, sessionID: $0.sessionID,
                title: $0.title, directory: $0.directory, updatedAt: $0.updatedAt,
                matches: $0.matches, total: $0.total)
        }
    }

    /// Merges what every server said into one list.
    ///
    /// Ranked by how likely the row is to be the one being looked for, not by which machine
    /// answered first: a conversation whose title says the words outranks one that merely contains
    /// them, one with the words in it outranks one matched on its title alone, and recency breaks
    /// every remaining tie because the thing someone is trying to find again is usually recent.
    /// The same conversation reachable through two profiles is one row.
    public static func merge(query: String, rows: [Row], outcomes: [ServerOutcome]) -> Board {
        let needles = terms(in: query)
        var seen = Set<String>()
        var unique: [Row] = []
        for row in rows where seen.insert(row.id).inserted { unique.append(row) }
        let ranked = unique.sorted { lhs, rhs in
            let left = score(lhs, needles: needles)
            let right = score(rhs, needles: needles)
            if left != right { return left > right }
            return lhs.updatedAt > rhs.updatedAt
        }
        return Board(query: query, rows: ranked, outcomes: outcomes)
    }

    private static func score(_ row: Row, needles: [String]) -> Int {
        var score = 0
        let title = row.title.lowercased()
        if !needles.isEmpty, needles.allSatisfy({ title.contains($0) }) { score += 4 }
        if !row.matches.isEmpty { score += 2 }
        if row.matches.contains(where: { $0.kind == "text" }) { score += 1 }
        return score
    }

    /// One line under the results saying what was and was not looked at. Nil when every server
    /// searched everything, because a search that covered the fleet has nothing to admit.
    public static func caveat(for board: Board) -> String? {
        var notes: [String] = []
        let titlesOnly = board.outcomes.filter { $0.coverage == .titlesOnly }
        let failed = board.outcomes.compactMap { outcome -> String? in
            guard case .failed = outcome.coverage else { return nil }
            return outcome.name
        }
        let truncated = board.outcomes.filter {
            if case .searched(_, let truncated) = $0.coverage { return truncated }
            return false
        }
        if !titlesOnly.isEmpty {
            notes.append(
                Localized.text(
                    "%@ can only be searched by title",
                    titlesOnly.map(\.name).joined(separator: ", ")))
        }
        if !truncated.isEmpty {
            notes.append(
                Localized.text(
                    "%@ stopped early — narrow the words",
                    truncated.map(\.name).joined(separator: ", ")))
        }
        if !failed.isEmpty {
            notes.append(
                Localized.text("%@ did not answer", failed.joined(separator: ", ")))
        }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    /// How a match names itself in a result row: the register it was in, in the words the rest of
    /// the app already uses for those things.
    public static func label(for match: TranscriptMatch) -> String {
        switch match.kind {
        case "text": return match.role == .assistant
            ? Localized.text("answer") : Localized.text("you")
        case "reasoning": return Localized.text("thinking")
        case "result": return Localized.text("output")
        default: return match.kind
        }
    }
}
