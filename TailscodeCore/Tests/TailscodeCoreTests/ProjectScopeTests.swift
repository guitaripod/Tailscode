import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Project scope")
struct ProjectScopeTests {

    private func entry(
        profileID: String = "one", sessionID: String = "s1", directory: String? = "/home/m/Dev/app"
    ) -> SessionEntry {
        SessionEntry(
            profileID: profileID, profileName: "studio", host: "studio.tail", backendType: .claudeCode,
            session: AgentSession(
                id: sessionID, agentType: .claudeCode, title: "chat", directory: directory,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)))
    }

    @Test("A scope matches on the exact pair, never a substring")
    func exactPair() {
        let scope = ProjectScope(profileID: "one", directory: "/home/m/Dev/app")
        #expect(scope.matches(entry()))
        #expect(!scope.matches(entry(directory: "/home/m/Dev/app-site")))
        #expect(!scope.matches(entry(directory: "/home/m/Dev/app/sub")))
        #expect(!scope.matches(entry(profileID: "two")))
    }

    @Test("The same path on two servers is two projects")
    func serverSplitsIdentity() {
        let here = ProjectScope(profileID: "one", directory: "/home/m/Dev/app")
        let there = ProjectScope(profileID: "two", directory: "/home/m/Dev/app")
        #expect(here != there)
        #expect(!there.matches(entry()))
    }

    @Test("No directory is a real scope of its own")
    func nilDirectoryScope() {
        let scope = ProjectScope(profileID: "one", directory: nil)
        #expect(scope.matches(entry(directory: nil)))
        #expect(!scope.matches(entry()))
        #expect(scope.name == "No project")
    }

    @Test("Applying a scope keeps order and drops everything else")
    func applyFilters() {
        let mine = entry(sessionID: "a")
        let older = entry(sessionID: "b")
        let other = entry(sessionID: "c", directory: "/tmp/other")
        let scoped = ProjectScope(of: mine).apply([mine, other, older])
        #expect(scoped == [mine, older])
    }

    @Test("A scope is named by the directory's last component")
    func nameIsLastComponent() {
        #expect(ProjectScope(profileID: "one", directory: "/home/m/Dev/app").name == "app")
        #expect(ProjectScope(of: entry()).name == "app")
    }

    @Test("The banner names both halves of the identity")
    func bannerNamesProjectAndServer() {
        let scope = ProjectScope(profileID: "one", directory: "/home/m/Dev/app")
        #expect(scope.banner(serverName: "studio") == "Only app on studio")
    }
}
