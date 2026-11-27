import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Chat nudges")
struct ChatNudgeTests {
    private func entry(_ id: String, active: Bool? = nil, turnOpen: Bool? = nil) -> SessionEntry {
        let now = Date()
        var session = AgentSession(
            id: id, agentType: .claudeCode, title: id, createdAt: now, updatedAt: now,
            isActive: active)
        session.turnOpen = turnOpen
        return SessionEntry(
            profileID: "p", profileName: "arch", host: "arch", backendType: .claudeCode,
            session: session)
    }

    @Test func theWordsSentAreTheOnesPeopleType() {
        #expect(ChatNudge.all.map(\.id) == ["resume", "status"])
        #expect(ChatNudge.resume.prompt == "resume")
        #expect(ChatNudge.status.prompt == "status?")
        #expect(ChatNudge.status.hint.contains("status?"))
    }

    @Test func theChatOnScreenOffersThemOnlyWhenQuietAndSpokenTo() {
        #expect(ChatNudge.offers(running: false, hasTranscript: true))
        #expect(ChatNudge.offers(running: true, hasTranscript: true) == false)
        #expect(ChatNudge.offers(running: false, hasTranscript: false) == false)
    }

    @Test func workLeftRunningBetweenTurnsIsNotAnOpenTurn() {
        #expect(ChatNudge.turnOpen(entry("a", active: true, turnOpen: false)) == false)
        #expect(ChatNudge.turnOpen(entry("b", active: true, turnOpen: true)))
        #expect(ChatNudge.turnOpen(entry("c", active: true)))
        #expect(ChatNudge.turnOpen(entry("d")) == false)
    }

    @Test func aRunPassesOverChatsWhoseTurnIsOut() {
        let ready = ChatNudgeRun.ready([
            entry("quiet"), entry("busy", active: true), entry("background", active: true, turnOpen: false),
        ])
        #expect(ready.map(\.session.id) == ["quiet", "background"])
    }

    @Test func theBulkVerbsCarryTheirNudge() {
        #expect(BulkChatAction.resume.nudge == .resume)
        #expect(BulkChatAction.status.nudge == .status)
        #expect(BulkChatAction.archive.nudge == nil)
        #expect(BulkChatCopy.button(.status, count: 3) == ChatNudge.status.title)
        #expect(BulkChatAction.resume.isDestructive == false)
    }

    @Test func theOutcomeSaysWhatWentAndWhatDidNot() {
        let clean = ChatNudgeOutcome(nudge: .resume, sent: 4, working: 0, failed: 0, reason: nil)
        #expect(clean.isClean)
        #expect(clean.sentence == "Sent “resume” to 4 chats")
        let one = ChatNudgeOutcome(nudge: .status, sent: 1, working: 0, failed: 0, reason: nil)
        #expect(one.sentence == "Sent “status?”")
        let mixed = ChatNudgeOutcome(
            nudge: .resume, sent: 2, working: 1, failed: 1, reason: "the server is asleep")
        #expect(mixed.isClean == false)
        #expect(
            mixed.sentence
                == "Sent “resume” to 2 chats · 1 was working and was left alone · 1 did not go: the server is asleep"
        )
    }

    @Test func aRunSendsOnlyToQuietChatsAndCountsTheRest() async {
        let backend = MockBackend()
        let outcome = await ChatNudgeRun.send(
            .resume, to: [entry("quiet"), entry("busy", active: true)],
            backend: { _ in backend })
        #expect(outcome.sent == 1)
        #expect(outcome.working == 1)
        #expect(outcome.failed == 0)
        let missing = await ChatNudgeRun.send(.status, to: [entry("gone")], backend: { _ in nil })
        #expect(missing.failed == 1)
    }
}
