import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// These stores were app-target code until they moved into this package, and every one of them
/// owns a format already sitting on a shipped device. A key rename or a changed field name is a
/// silent data loss the compiler cannot see, so the shapes are pinned here against fixtures
/// captured from the 1.3 build.
/// Nested under `DeviceStores` on purpose: every device-local store shares one
/// `UserDefaults`, and corelibs' is not safe to write from two threads at once, so a
/// suite that writes one has to be serialized against every other suite that does.
extension DeviceStores {
    @Suite("On-disk compatibility")
    struct PersistenceCompatibilityTests {

        @Test("A saved chat still decodes from what 1.3 wrote")
        func savedChatDecodesShippedJSON() throws {
            let shipped = """
                [{
                  "profileID": "debug",
                  "sessionID": "8B1F0C2E-77A1-4D6E-9C1A-1D2E3F405162",
                  "title": "Fix the flaky reconnect test",
                  "profileName": "studio",
                  "backend": "claudeCode",
                  "directory": "/Users/marcus/Dev/pulse-server",
                  "updatedAt": 776000000,
                  "savedAt": 776000100
                }]
                """
            let decoded = try JSONDecoder().decode([SavedChat].self, from: Data(shipped.utf8))
            let chat = try #require(decoded.first)

            #expect(chat.profileID == "debug")
            #expect(chat.sessionID == "8B1F0C2E-77A1-4D6E-9C1A-1D2E3F405162")
            #expect(chat.title == "Fix the flaky reconnect test")
            #expect(chat.profileName == "studio")
            #expect(chat.backend == .claudeCode)
            #expect(chat.directory == "/Users/marcus/Dev/pulse-server")
            #expect(chat.projectName == "pulse-server")
            #expect(chat.displayTitle == "Fix the flaky reconnect test")
        }

        @Test("A saved chat re-encodes to the same field names")
        func savedChatEncodesTheSameFieldNames() throws {
            let chat = SavedChat(
                profileID: "debug", sessionID: "s1", title: "t", profileName: "studio",
                backend: .openCode, directory: "/tmp/x", updatedAt: Date(timeIntervalSince1970: 1),
                savedAt: Date(timeIntervalSince1970: 2))
            let data = try JSONEncoder().encode([chat])
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            #expect(
                Set(try #require(object.first).keys) == [
                    "profileID", "sessionID", "title", "profileName", "backend", "directory",
                    "updatedAt", "savedAt",
                ])
        }

        @Test("A placeholder title still reads as a sentence rather than a blank")
        func placeholderTitlesStayReadable() {
            let empty = SavedChat(
                profileID: "p", sessionID: "s", title: "   ", profileName: "n", backend: .claudeCode,
                directory: nil, updatedAt: Date(), savedAt: Date())
            #expect(empty.displayTitle == Localized.text("Empty conversation"))
        }

        @Test("The UserDefaults keys these stores own have not moved")
        func defaultsKeysAreUnchanged() {
            #expect(SavedChatStore.storageKey == "tailscode.saved.chats")
            #expect(SessionSeenStore.seenKey == "tailscode.seen.sessions")
            #expect(SessionSeenStore.baselineKey == "tailscode.seen.baseline")
            #expect(RecentModelsStore.storageKey == "tailscode.recentModels")
            #expect(EffortPreferenceStore.storagePrefix == "tailscode.effort.")
            #expect(PresenceOrbSetting.defaultsKey == "tailscode.presenceOrb")
        }

        @Test("A model badge reads the same as it did in the app target")
        func modelBadgeLabels() {
            #expect(ModelBadge.label(model: nil, effort: nil) == Localized.text("Auto"))
            let opus = ModelSelection(providerID: "anthropic", modelID: "claude-opus-4-20250514")
            #expect(ModelBadge.label(model: opus, effort: "high").hasSuffix("· high"))
        }

        @Test("An address types the same way it did before the move")
        func hostAddressReadings() {
            guard case .address(let plain) = HostAddress.read("100.91.211.44", defaultPort: 4098) else {
                Issue.record("a bare tailnet address should read as an address")
                return
            }
            #expect(plain.url.absoluteString == "http://100.91.211.44:4098")
            #expect(plain.portWasInferred)
            #expect(plain.isTailnetRange)

            guard case .address(let explicit) = HostAddress.read("http://box:4096", defaultPort: 4098) else {
                Issue.record("an explicit URL should read as an address")
                return
            }
            #expect(explicit.url.absoluteString == "http://box:4096")
            #expect(!explicit.portWasInferred)
            #expect(explicit.probeCandidates().count == 1)
        }

        @Test("An entry is the pair of profile and session, not the session alone")
        func sessionEntryIdentity() {
            let session = AgentSession(id: "s1", agentType: .claudeCode, title: "t", createdAt: Date(), updatedAt: Date())
            let a = SessionEntry(
                profileID: "p1", profileName: "studio", host: "h", backendType: .claudeCode,
                session: session)
            var renamed = session
            renamed.title = "renamed"
            let b = SessionEntry(
                profileID: "p1", profileName: "studio", host: "h", backendType: .claudeCode,
                session: renamed)
            let elsewhere = SessionEntry(
                profileID: "p2", profileName: "homelab", host: "h", backendType: .claudeCode,
                session: session)

            #expect(a == b)
            #expect(a != elsewhere)
            #expect(Set<SessionEntry>([a, b, elsewhere]).count == 2)
        }
    }
}
