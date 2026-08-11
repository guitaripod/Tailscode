import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Chat list")
struct ChatListTests {
    private func entry(
        profileID: String = "one", sessionID: String = "s1", title: String = "chat",
        active: Bool? = nil, agents: Int? = nil, task: String? = nil,
        updated: Date = Date(timeIntervalSince1970: 0)
    ) -> SessionEntry {
        SessionEntry(
            profileID: profileID, profileName: profileID, host: profileID,
            backendType: .claudeCode,
            session: AgentSession(
                id: sessionID, agentType: .claudeCode, title: title, directory: "/tmp/\(profileID)",
                createdAt: updated, updatedAt: updated, isActive: active, activeAgents: agents,
                agentTask: task))
    }

    private func row(
        _ entry: SessionEntry, unreachable: Bool = false, saved: Bool = false,
        presence: SessionPresence = .unobserved
    ) -> SessionRowModel {
        SessionRowModel(
            entry: entry, unreachable: unreachable, unread: false, saved: saved,
            presence: presence)
    }

    @Test("A listing that reports a turn open is live")
    func listingLiveness() {
        #expect(row(entry(active: true)).state == .live)
        #expect(row(entry(active: false)).state == .idle)
        #expect(row(entry()).state == .idle)
    }

    @Test("Subagents still out count as a turn in flight")
    func subagentsAreLive() {
        #expect(row(entry(active: false, agents: 2)).state == .live)
    }

    @Test("What this device watches beats what the listing remembered")
    func presenceWins() {
        #expect(row(entry(active: false), presence: .running(nil)).state == .live)
        #expect(row(entry(active: true), presence: .awaitingApproval).state == .awaitingApproval)
        #expect(row(entry(active: false), presence: .failed).state == .failed)
    }

    @Test("A conversation streaming here cannot be shown as offline")
    func presenceOutranksUnreachable() {
        #expect(row(entry(), unreachable: true, presence: .running(nil)).state == .live)
        #expect(row(entry(), unreachable: true, presence: .awaitingApproval).state == .awaitingApproval)
        #expect(row(entry(active: true), unreachable: true).state == .offline)
        #expect(row(entry(), unreachable: true, presence: .failed).state == .offline)
    }

    @Test("The busy line prefers the step this device is watching")
    func snippet() {
        #expect(row(entry(active: true, task: "Edit"), presence: .unobserved).snippet == "Edit")
        #expect(row(entry(active: true, task: "Edit"), presence: .running("Running Bash")).snippet == "Running Bash")
        #expect(row(entry(active: false, task: "Edit")).snippet == nil)
    }

    @Test("One machine answering is a word every row can stop saying")
    func vocabularyDropsWhatEveryRowShares() {
        let alone = [row(entry(sessionID: "a")), row(entry(sessionID: "b"))]
        let one = ChatListVocabulary(rows: alone)
        #expect(!one.namesServer)
        #expect(!one.namesBackend)
        #expect(alone[0].facets(one).origin == nil)
        #expect(alone[0].facets(one).project == "one")

        let fleet = alone + [row(entry(profileID: "two", sessionID: "c"))]
        let many = ChatListVocabulary(rows: fleet)
        #expect(many.namesServer)
        #expect(!many.namesBackend)
        #expect(fleet[0].facets(many).origin == "one")
    }

    @Test("The agent is named only when its machine does not already imply it")
    func backendNamedOnlyWhenAmbiguous() {
        let mixedFleet = [
            row(entry(profileID: "one", sessionID: "a")),
            row(openCode(profileID: "two", sessionID: "b")),
        ]
        #expect(!ChatListVocabulary(rows: mixedFleet).namesBackend)

        let mixedServer = [
            row(entry(profileID: "one", sessionID: "a")),
            row(openCode(profileID: "one", sessionID: "b")),
        ]
        let vocabulary = ChatListVocabulary(rows: mixedServer)
        #expect(vocabulary.namesBackend)
        #expect(!vocabulary.namesServer)
        #expect(mixedServer[0].facets(vocabulary).origin == "Claude Code")
    }

    private func openCode(profileID: String, sessionID: String) -> SessionEntry {
        SessionEntry(
            profileID: profileID, profileName: profileID, host: profileID, backendType: .openCode,
            session: AgentSession(
                id: sessionID, agentType: .openCode, title: "chat", directory: "/tmp/\(profileID)",
                createdAt: Date(), updatedAt: Date()))
    }

    @Test("A row left with nothing to say names its server rather than going blank")
    func facetsNeverGoSilent() {
        let noProject = SessionEntry(
            profileID: "one", profileName: "macbook", host: "one", backendType: .claudeCode,
            session: AgentSession(
                id: "s1", agentType: .claudeCode, title: "chat", directory: nil,
                createdAt: Date(), updatedAt: Date()))
        let facets = row(noProject).facets(ChatListVocabulary(namesServer: false, namesBackend: false))
        #expect(facets.project == nil)
        #expect(facets.origin == "macbook")
    }

    @Test("The age is its own fact, not the tail of a sentence")
    func facetsCarryTheAge() {
        let recent = row(entry(updated: Date(timeIntervalSinceNow: -7200)))
        #expect(recent.facets().age == "2h")
        #expect(recent.age == recent.facets().age)
    }

    @Test("A server that already names its agent does not say it twice")
    func originDoesNotRepeatTheAgent() {
        let named = SessionEntry(
            profileID: "one", profileName: "Claude Code", host: "one", backendType: .claudeCode,
            session: AgentSession(
                id: "s1", agentType: .claudeCode, title: "chat", directory: "/tmp/p",
                createdAt: Date(), updatedAt: Date()))
        #expect(row(named).facets(.full).origin == "Claude Code")
    }

    @Test("A turn stopped for an approval leads LIVE NOW with the running ones")
    func inFlight() {
        #expect(SessionRowState.live.isInFlight)
        #expect(SessionRowState.awaitingApproval.isInFlight)
        #expect(!SessionRowState.idle.isInFlight)
        #expect(!SessionRowState.offline.isInFlight)
        #expect(!SessionRowState.failed.isInFlight)
    }

    @Test("Sections drop what is empty and never repeat a row")
    func sections() {
        let live = row(entry(sessionID: "a", active: true))
        let saved = row(entry(sessionID: "b"), saved: true)
        let plain = row(entry(sessionID: "c"))
        let grouped = groupIntoSections([live, saved, plain])
        #expect(grouped.map(\.0) == [.live, .saved, .recent])
        #expect(grouped[0].1.map(\.entry.session.id) == ["a"])
        #expect(grouped[1].1.map(\.entry.session.id) == ["b"])
        #expect(grouped[2].1.map(\.entry.session.id) == ["c"])
    }

    @Test("LIVE NOW holds still while its rows work")
    func liveOrderDoesNotFollowActivity() {
        let older = entry(sessionID: "a", active: true, updated: Date(timeIntervalSince1970: 100))
        let newer = entry(sessionID: "b", active: true, updated: Date(timeIntervalSince1970: 200))
        let settled = groupIntoSections([row(older), row(newer)])[0].1
        #expect(settled.map(\.entry.session.id) == ["b", "a"])

        let ticked = SessionEntry(
            profileID: "one", profileName: "one", host: "one", backendType: .claudeCode,
            session: AgentSession(
                id: "a", agentType: .claudeCode, title: "chat", directory: "/tmp/one",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 9999), isActive: true))
        let afterATokenLanded = groupIntoSections([row(ticked), row(newer)])[0].1
        #expect(
            afterATokenLanded.map(\.entry.session.id) == ["b", "a"],
            "a token landing in one live chat moved it past the other")

        let reversed = groupIntoSections([row(newer), row(older)])[0].1
        #expect(reversed.map(\.entry.session.id) == ["b", "a"])
    }

    @Test("A saved chat that goes live is listed once, in LIVE NOW")
    func savedAndLive() {
        let both = row(entry(sessionID: "a", active: true), saved: true)
        let grouped = groupIntoSections([both])
        #expect(grouped.map(\.0) == [.live])
    }

    @Test("The same session id on two servers is two rows, not one")
    func sameIDOnTwoServers() {
        let here = row(entry(profileID: "one", sessionID: "s1", active: true))
        let there = row(entry(profileID: "two", sessionID: "s1"))
        let grouped = groupIntoSections([here, there])
        #expect(grouped.map(\.0) == [.live, .recent])
        #expect(grouped[1].1.map(\.entry.profileID) == ["two"])
    }

    @Test("Self-check of the selection stays clean")
    func selectionCheck() {
        let issues = ChatSelectionCheck.run()
        #expect(issues.isEmpty, "ChatSelectionCheck: \(issues)")
    }

    @Test("Self-check of the new-conversation modal stays clean")
    func newChatCheck() {
        let issues = NewChatChooserCheck.run()
        #expect(issues.isEmpty, "NewChatChooserCheck: \(issues)")
    }

    @Test("Paths are found the way command names are")
    func fuzzyPaths() {
        #expect(FuzzyRank.hit("kontu", in: "/home/m/Dev/kontu", separators: ["/"])?.tier == .segment)
        #expect(FuzzyRank.hit("/home", in: "/home/m")?.tier == .prefix)
        #expect(FuzzyRank.hit("/home/m", in: "/home/m")?.tier == .exact)
        #expect(FuzzyRank.hit("ome", in: "/home/m")?.tier == .inner)
        #expect(FuzzyRank.hit("hm", in: "/home/m")?.tier == .scattered)
        #expect(FuzzyRank.hit("zz", in: "/home/m") == nil)
        #expect(FuzzyRank.hit("", in: "/home/m")?.highlight.isEmpty == true)
    }

    @Test("A folder name is read off the path, parent and all")
    func pathParts() {
        #expect(NewChatChooser.name(of: "/home/m/Dev/thing") == "thing")
        #expect(NewChatChooser.parent(of: "/home/m/Dev/thing") == "/home/m/Dev")
        #expect(NewChatChooser.name(of: "/home/m/Dev/thing/") == "thing")
        #expect(NewChatChooser.parent(of: "/thing") == "/")
        #expect(NewChatChooser.name(of: "thing") == "thing")
        #expect(NewChatChooser.isPathLike("~/Dev"))
        #expect(NewChatChooser.isPathLike("/srv"))
        #expect(NewChatChooser.isPathLike("./here"))
        #expect(!NewChatChooser.isPathLike("dev"))
        #expect(!NewChatChooser.isPathLike(""))
    }

    @Test("Marking and deleting are bound, and delete still answers x")
    func shortcuts() {
        let set = ShortcutSet.build(overrides: [:])
        #expect(set.issues.isEmpty, "shortcut issues: \(set.issues)")
        guard let space = KeyChord.canonical(keyval: 0x20, state: 0),
            let x = KeyChord.canonical(keyval: UInt32(UnicodeScalar("x").value), state: 0),
            let all = KeyChord.canonical(
                keyval: UInt32(UnicodeScalar("a").value), state: KeyChord.controlMask)
        else {
            Issue.record("chords do not canonicalize")
            return
        }
        #expect(set.resolve(space, context: .normal, pending: [], awaitingApproval: false) == .run(.toggleMarked))
        #expect(set.resolve(all, context: .normal, pending: [], awaitingApproval: false) == .run(.toggleMarkAll))
        #expect(set.resolve(x, context: .normal, pending: [], awaitingApproval: false) == .run(.deleteSelected))
    }
}
