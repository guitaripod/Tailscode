import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Mark all as read")
struct ReadSweepTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, profile: String = "one", active: Bool = false) -> SessionEntry {
        SessionEntry(
            profileID: profile, profileName: profile, host: profile, backendType: .claudeCode,
            session: AgentSession(
                id: id, agentType: .claudeCode, title: "chat \(id)", directory: "/tmp/\(id)",
                createdAt: now.addingTimeInterval(-3600), updatedAt: now, isActive: active))
    }

    private func saved(_ id: String, profile: String = "one") -> SavedChat {
        SavedChat(
            profileID: profile, sessionID: id, title: "saved \(id)", profileName: profile,
            backend: .claudeCode, directory: nil, updatedAt: now, savedAt: now)
    }

    private func sweep(
        _ entries: [SessionEntry], saved: [SavedChat] = [],
        presence: [String: SessionPresence] = [:], unreachable: Set<String> = [], notices: Int = 0,
        read: Set<String> = []
    ) -> ReadSweep {
        ReadSweep.reading(
            entries: entries, saved: saved, presence: presence, unreachable: unreachable,
            notices: notices, isUnread: { id, _ in !read.contains(id) })
    }

    @Test("A turn in flight is left to say its ending, so the press goes away once it is pressed")
    func inFlightIsNotNews() {
        let result = sweep(
            [entry("streaming"), entry("listedBusy", active: true), entry("asking"), entry("done")],
            presence: ["streaming": .running("Writing"), "asking": .awaitingApproval])
        #expect(result.chats == ["done"])
        let working = sweep([entry("streaming")], presence: ["streaming": .running(nil)])
        #expect(working.isEmpty, "a board where only a turn is running has nothing to read")
    }

    @Test("A chat whose machine is out of reach is read like any other at rest")
    func offlineIsRead() {
        let result = sweep([entry("far", profile: "two", active: true)], unreachable: ["two"])
        #expect(result.chats == ["far"])
    }

    @Test("Saved copies are read on their own only when no listing decides for them")
    func savedCopies() {
        let result = sweep(
            [entry("busy"), entry("listed")],
            saved: [saved("busy"), saved("listed"), saved("gone"), saved("old")],
            presence: ["busy": .running(nil)], read: ["old"])
        #expect(result.chats == ["listed", "gone"])
    }

    @Test("A notice still filed is something to read, and nothing at all is nothing")
    func notices() {
        #expect(!sweep([], notices: 1).isEmpty)
        #expect(sweep([entry("a")], read: ["a"]).isEmpty)
    }

    @Test("The same chat listed twice is read once")
    func once() {
        let result = sweep([entry("a"), entry("a", profile: "two")], saved: [saved("a")])
        #expect(result.chats == ["a"])
    }
}
