import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The model and level the new-chat modal shows are the ones the chat it starts opens on, even
/// when the server's record of the fresh session names its own default.
/// Nested under `DeviceStores` on purpose: every device-local store shares one
/// `UserDefaults`, and corelibs' is not safe to write from two threads at once.
extension DeviceStores {
    @Suite struct NewChatDefaultsTests {
        private let profileID = "new-chat-defaults-\(UUID().uuidString)"
        private let fable = ModelSelection(providerID: "anthropic", modelID: "fable")

        @Test("a stamped chat opens on the modal's model and level, not the record's default")
        func stampedChatOpensOnWhatTheModalShowed() {
            ModelCatalogStore.store(
                [
                    ModelInfo(id: "fable", name: "Fable", providerID: "anthropic"),
                    ModelInfo(id: "opus", name: "Opus", providerID: "anthropic"),
                ], for: profileID)
            ModelPreferenceStore.setGlobalModel(fable, forContextID: profileID)
            EffortPreferenceStore.setGlobalEffort("xhigh", forContextID: profileID)
            let shown = NewChatDefaults.resolve(
                profileID: profileID, agentOptions: ["low", "medium", "high", "xhigh", "max"])
            #expect(shown.model == fable)
            #expect(shown.effort == "xhigh")
            #expect(shown.chip?.name == "Fable")

            let sessionID = "fresh-\(UUID().uuidString)"
            let key = QuickAskDefaults.sessionPreferenceKey(
                profileID: profileID, sessionID: sessionID)
            #expect(
                ModelPreferenceStore.initialModel(
                    sessionKey: key, contextID: profileID, sessionModel: "claude-opus-5")
                    != fable,
                "unstamped, the record's default wins — the bug")

            shown.stamp(profileID: profileID, sessionID: sessionID)
            #expect(
                ModelPreferenceStore.initialModel(
                    sessionKey: key, contextID: profileID, sessionModel: "claude-opus-5")
                    == fable)
            #expect(
                EffortPreferenceStore.initialEffort(
                    sessionKey: key, contextID: profileID, sessionEffort: "medium") == "xhigh")
        }

        @Test("a level the model does not take is never named, and is not stamped")
        func unofferedLevelIsDropped() {
            ModelCatalogStore.store(
                [ModelInfo(id: "duo", name: "Duo", providerID: "google", variants: ["low", "high"])],
                for: profileID)
            let duo = ModelSelection(providerID: "google", modelID: "duo")
            ModelPreferenceStore.setGlobalModel(duo, forContextID: profileID)
            EffortPreferenceStore.setGlobalEffort("max", forContextID: profileID)
            let shown = NewChatDefaults.resolve(profileID: profileID, agentOptions: [])
            #expect(shown.effort == nil)
            #expect(shown.chip?.effort == nil)
            #expect(shown.options == ["low", "high"])

            let unasked = NewChatDefaults.resolve(profileID: profileID)
            #expect(unasked.effort == "max", "a client that never asked judges nothing")
            #expect(unasked.levels == ["max"], "and the pill still wears the level that travels")
        }

        @Test("the server's own default on an agent with no ladder leaves the level unjudged")
        func serverDefaultWithoutLadderKeepsTheLevel() {
            EffortPreferenceStore.setGlobalEffort("high", forContextID: profileID)
            let opencode = NewChatDefaults.resolve(profileID: profileID, agentOptions: [])
            #expect(opencode.model == nil && opencode.effort == "high")
            #expect(opencode.options == nil && opencode.levels == ["high"])
            #expect(opencode.line.contains("high"))

            let claude = NewChatDefaults.resolve(profileID: profileID, agentOptions: ["low", "medium"])
            #expect(claude.effort == nil, "an agent's own ladder still judges the server's default")
            #expect(claude.levels == ["low", "medium"])
        }

        @Test("a pick in the modal is the server's default from then on, and nil hands it back")
        func pickInTheModalIsRecorded() {
            NewChatDefaults.record(model: fable, profileID: profileID)
            NewChatDefaults.record(effort: "high", profileID: profileID)
            var shown = NewChatDefaults.resolve(profileID: profileID, agentOptions: ["high"])
            #expect(shown.model == fable && shown.effort == "high")

            NewChatDefaults.record(model: nil, profileID: profileID)
            NewChatDefaults.record(effort: nil, profileID: profileID)
            shown = NewChatDefaults.resolve(profileID: profileID, agentOptions: ["high"])
            #expect(shown.model == nil && shown.effort == nil && shown.chip == nil)
            #expect(shown.line == NewChatDefaults.made(model: nil, effort: nil, catalog: []).line)

            let sessionID = "fresh-\(UUID().uuidString)"
            shown.stamp(profileID: profileID, sessionID: sessionID)
            let key = QuickAskDefaults.sessionPreferenceKey(
                profileID: profileID, sessionID: sessionID)
            #expect(ModelPreferenceStore.model(forKey: key) == nil)
            #expect(EffortPreferenceStore.effort(forKey: key) == nil)
        }
    }
}
