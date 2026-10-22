import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct SessionEntryTitleTests {
    private func entry(
        _ title: String, id: String = "s1", profile: String = "p1", directory: String? = "/work"
    ) -> SessionEntry {
        var session = AgentSession(
            id: id, agentType: .openCode, title: title,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        session.directory = directory
        return SessionEntry(
            profileID: profile, profileName: "studio", host: "studio", backendType: .openCode,
            session: session)
    }

    @Test func aPaneTakesTheNameTheServerGaveAfterItOpened() {
        let opened = entry(AgentSession.untitledTitle)
        let adopted = opened.adoptingTitle(from: entry("Fix login", directory: "/other"))
        #expect(adopted?.session.title == "Fix login")
        #expect(adopted?.session.directory == "/work", "only the name is taken, not the rest of the record")
        #expect(adopted?.profileName == "studio")
    }

    @Test func aPlaceholderNeverReplacesANameThePersonHasBeenReading() {
        let opened = entry("Fix login")
        for placeholder in [AgentSession.untitledTitle, "New session - 2026-10-21", "New chat", "", "  "] {
            #expect(opened.adoptingTitle(from: entry(placeholder)) == nil, "\(placeholder)")
        }
    }

    @Test func anUnchangedTitleIsNothingToAdopt() {
        #expect(entry("Fix login").adoptingTitle(from: entry("Fix login")) == nil)
    }

    @Test func aRenameIsAdopted() {
        let adopted = entry("Fix login").adoptingTitle(from: entry("Fix logout"))
        #expect(adopted?.session.title == "Fix logout")
    }

    @Test func aListingForAnotherConversationIsNeverAdopted() {
        let opened = entry("Fix login")
        #expect(opened.adoptingTitle(from: entry("Other", id: "s2")) == nil)
        #expect(opened.adoptingTitle(from: entry("Other", profile: "p2")) == nil)
    }

    @Test func theOriginalEntryIsLeftAlone() {
        let opened = entry(AgentSession.untitledTitle)
        _ = opened.adoptingTitle(from: entry("Fix login"))
        #expect(opened.session.title == AgentSession.untitledTitle)
    }

    @Test func aListingMovesTheModelAndLevelAndStillRefusesAPlaceholderTitle() {
        let opened = entry("Fix login")
        var listed = entry(AgentSession.untitledTitle)
        listed.session.model = "gpt-5.6"
        listed.session.modelProviderID = "openai"
        listed.session.reasoningEffort = "high"
        let adopted = opened.adoptingListing(from: listed)
        #expect(adopted?.session.title == "Fix login")
        #expect(adopted?.session.model == "gpt-5.6")
        #expect(adopted?.session.modelProviderID == "openai")
        #expect(adopted?.session.reasoningEffort == "high")
        #expect(adopted?.adoptingListing(from: listed) == nil, "nothing new is nothing to redraw")
    }

    @Test func aListingForAnotherChatIsNeverAdopted() {
        #expect(entry("Fix login").adoptingListing(from: entry("Other", id: "s2")) == nil)
        #expect(entry("Fix login").adoptingListing(from: entry("Other", profile: "p2")) == nil)
    }
}
