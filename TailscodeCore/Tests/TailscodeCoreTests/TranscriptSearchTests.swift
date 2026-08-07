import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A search is read as an absence of results, and an absence is read as an answer. These pin the
/// two things that makes true: the ranking that decides what the first row is, and the caveat that
/// admits what was never looked at.
@Suite("Transcript search")
struct TranscriptSearchTests {

    private func row(
        _ title: String, session: String = "s", profile: String = "p", ago: TimeInterval = 0,
        matches: [TranscriptMatch] = []
    ) -> TranscriptSearch.Row {
        TranscriptSearch.Row(
            profileID: profile, profileName: profile, sessionID: session, title: title,
            directory: "/home/m/tailscode", updatedAt: Date().addingTimeInterval(-ago),
            matches: matches, total: matches.count)
    }

    private func match(_ text: String, kind: String = "text", role: MessageRole = .assistant)
        -> TranscriptMatch
    {
        TranscriptMatch(kind: kind, role: role, text: text)
    }

    @Test("A title that says the words outranks a conversation that merely contains them")
    func titleOutranksBody() {
        let board = TranscriptSearch.merge(
            query: "cascade",
            rows: [
                row("something else", session: "body", matches: [match("the cascade is a wave")]),
                row("cascade rewrite", session: "title", ago: 5000),
            ], outcomes: [])
        #expect(board.rows.first?.sessionID == "title")
    }

    @Test("Words actually said outrank a title match nobody read the inside of")
    func bodyOutranksTitleOnly() {
        let board = TranscriptSearch.merge(
            query: "beacon",
            rows: [
                row("beacon notes", session: "titleOnly", ago: 10),
                row("beacon notes", session: "read", ago: 20, matches: [match("the beacon fired")]),
            ], outcomes: [])
        #expect(board.rows.first?.sessionID == "read")
    }

    @Test("Recency breaks a tie, because what someone wants again is usually recent")
    func recencyBreaksTies() {
        let board = TranscriptSearch.merge(
            query: "x",
            rows: [row("a", session: "old", ago: 9000), row("b", session: "new", ago: 5)],
            outcomes: [])
        #expect(board.rows.first?.sessionID == "new")
    }

    @Test("One conversation reachable twice is one row")
    func deduplicates() {
        let board = TranscriptSearch.merge(
            query: "x", rows: [row("a", session: "s"), row("a", session: "s")], outcomes: [])
        #expect(board.rows.count == 1)
    }

    @Test("Every word must be there — several words narrow rather than widen")
    func titleTermsAreConjunctive() {
        let entries = [entry("the cascade renders markdown"), entry("the cascade is a wave")]
        let found = TranscriptSearch.titleRows(
            matching: "cascade markdown", entries: entries, profileName: { _ in "arch" })
        #expect(found.count == 1)
    }

    @Test("A row matched only on its title says so")
    func titleOnlyIsMarked() {
        #expect(row("a").isTitleOnly)
        #expect(!row("a", matches: [match("found")]).isTitleOnly)
    }

    @Test("A fleet that searched everything has nothing to admit")
    func noCaveatWhenComplete() {
        let board = TranscriptSearch.merge(
            query: "x", rows: [],
            outcomes: [
                .init(profileID: "a", name: "arch", coverage: .searched(scanned: 40, truncated: false))
            ])
        #expect(TranscriptSearch.caveat(for: board) == nil)
    }

    @Test("A server that could not look inside, gave up early, or never answered is named")
    func caveatNamesEveryShortfall() {
        let board = TranscriptSearch.merge(
            query: "x", rows: [],
            outcomes: [
                .init(profileID: "a", name: "opencode·arch", coverage: .titlesOnly),
                .init(
                    profileID: "b", name: "macbook",
                    coverage: .searched(scanned: 400, truncated: true)),
                .init(profileID: "c", name: "old-laptop", coverage: .failed("offline")),
            ])
        let caveat = try! #require(TranscriptSearch.caveat(for: board))
        #expect(caveat.contains("opencode·arch"))
        #expect(caveat.contains("macbook"))
        #expect(caveat.contains("old-laptop"))
    }

    @Test("A match names the register it was in, in the app's own words")
    func matchLabels() {
        #expect(TranscriptSearch.label(for: match("x", role: .assistant)) == "answer")
        #expect(TranscriptSearch.label(for: match("x", role: .user)) == "you")
        #expect(TranscriptSearch.label(for: match("x", kind: "reasoning")) == "thinking")
        #expect(TranscriptSearch.label(for: match("x", kind: "result")) == "output")
        #expect(TranscriptSearch.label(for: match("x", kind: "Bash")) == "Bash")
    }

    @Test("Nothing typed is not a search")
    func blankIsNotASearch() {
        #expect(!TranscriptSearch.isSearchable("   "))
        #expect(TranscriptSearch.isSearchable("a"))
    }

    private func entry(_ title: String) -> SessionEntry {
        SessionEntry(
            profileID: "p", profileName: "arch", host: "arch", backendType: .claudeCode,
            session: AgentSession(
                id: UUID().uuidString, agentType: .claudeCode, title: title,
                createdAt: Date(), updatedAt: Date()))
    }
}
