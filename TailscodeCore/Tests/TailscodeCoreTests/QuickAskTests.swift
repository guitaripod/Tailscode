import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quick ask", .serialized)
struct QuickAskTests {

    private func withCleanStore(_ body: () -> Void) {
        let key = "tailscode.quickask.server"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        body()
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test("The last quick ask's server answers the next one")
    func lastServerWins() {
        withCleanStore {
            QuickAskDefaults.record(profileID: "two")
            #expect(QuickAskDefaults.target(among: ["one", "two"], fallback: "one") == "two")
        }
    }

    @Test("A remembered server that left the fleet falls back")
    func staleMemoryFallsBack() {
        withCleanStore {
            QuickAskDefaults.record(profileID: "gone")
            #expect(QuickAskDefaults.target(among: ["one", "two"], fallback: "two") == "two")
        }
    }

    @Test("No memory and no fallback still aims at a server")
    func firstServerAsLastResort() {
        withCleanStore {
            #expect(QuickAskDefaults.target(among: ["one", "two"], fallback: nil) == "one")
            #expect(QuickAskDefaults.target(among: ["one"], fallback: "absent") == "one")
        }
    }

    @Test("No servers means no target — the surface's cue to offer setup")
    func emptyFleetIsNil() {
        withCleanStore {
            QuickAskDefaults.record(profileID: "one")
            #expect(QuickAskDefaults.target(among: [], fallback: nil) == nil)
        }
    }

    @Test("Clearing forgets the memory")
    func clearForgets() {
        withCleanStore {
            QuickAskDefaults.record(profileID: "one")
            QuickAskDefaults.clear()
            #expect(QuickAskDefaults.lastProfileID == nil)
        }
    }

    private func withCleanAim(_ profileID: String, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let composer = ModelPreferenceStore.globalModel(forContextID: profileID)
        defaults.removeObject(forKey: "tailscode.quickask.aimed." + profileID)
        ModelPreferenceStore.setGlobalModel(
            nil, forContextID: QuickAskDefaults.contextID(forProfileID: profileID))
        EffortPreferenceStore.setGlobalEffort(
            nil, forContextID: QuickAskDefaults.contextID(forProfileID: profileID))
        body()
        defaults.removeObject(forKey: "tailscode.quickask.aimed." + profileID)
        ModelPreferenceStore.setGlobalModel(composer, forContextID: profileID)
    }

    @Test("Until a model is picked the aim follows the server")
    func aimFollowsTheServerFirst() {
        withCleanAim("studio") {
            let opus = ModelSelection(providerID: "anthropic", modelID: "opus")
            ModelPreferenceStore.setGlobalModel(opus, forContextID: "studio")
            #expect(!QuickAskDefaults.hasOwnAim(forProfileID: "studio"))
            #expect(QuickAskDefaults.aimContext(forProfileID: "studio") == "studio")
            #expect(QuickAskDefaults.model(forProfileID: "studio") == opus)
        }
    }

    @Test("A picked model is the quick ask's own and leaves the server's alone")
    func pickedModelStaysSeparate() {
        withCleanAim("studio") {
            let opus = ModelSelection(providerID: "anthropic", modelID: "opus")
            let haiku = ModelSelection(providerID: "anthropic", modelID: "haiku")
            ModelPreferenceStore.setGlobalModel(opus, forContextID: "studio")
            QuickAskDefaults.recordModel(haiku, forProfileID: "studio")
            #expect(QuickAskDefaults.hasOwnAim(forProfileID: "studio"))
            #expect(QuickAskDefaults.model(forProfileID: "studio") == haiku)
            #expect(ModelPreferenceStore.globalModel(forContextID: "studio") == opus)
        }
    }

    @Test("Aiming at the server's own default is a pick, not a lack of one")
    func serverDefaultIsAPick() {
        withCleanAim("studio") {
            let opus = ModelSelection(providerID: "anthropic", modelID: "opus")
            ModelPreferenceStore.setGlobalModel(opus, forContextID: "studio")
            QuickAskDefaults.recordModel(nil, forProfileID: "studio")
            #expect(QuickAskDefaults.model(forProfileID: "studio") == nil)
            QuickAskDefaults.clearOwnAim(forProfileID: "studio")
            #expect(QuickAskDefaults.model(forProfileID: "studio") == opus)
        }
    }

    @Test("The minted conversation is stamped with the aim it was asked on")
    func mintCarriesTheAim() {
        withCleanAim("studio") {
            let key = QuickAskDefaults.sessionPreferenceKey(profileID: "studio", sessionID: "s1")
            let haiku = ModelSelection(providerID: "anthropic", modelID: "haiku")
            QuickAskDefaults.stamp(profileID: "studio", sessionID: "s1")
            #expect(ModelPreferenceStore.model(forKey: key) == nil)
            QuickAskDefaults.recordModel(haiku, forProfileID: "studio")
            QuickAskDefaults.recordEffort("low", forProfileID: "studio")
            QuickAskDefaults.stamp(profileID: "studio", sessionID: "s1")
            #expect(ModelPreferenceStore.model(forKey: key) == haiku)
            #expect(EffortPreferenceStore.effort(forKey: key) == "low")
            ModelPreferenceStore.setModel(nil, forKey: key)
            EffortPreferenceStore.setEffort(nil, forKey: key)
        }
    }
}
