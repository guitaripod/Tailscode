import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A chat opens with the model config its row wears: the server's own report of what the
/// session runs outranks this device's remembered picks, and a bare model name resolves
/// through the server's cached catalog into something a send can carry.
@Suite struct ModelSeedTests {
    private let contextID = "seed-tests-\(UUID().uuidString)"

    private var catalog: [ModelInfo] {
        [
            ModelInfo(id: "fable", name: "Fable", providerID: "anthropic"),
            ModelInfo(id: "opus[1m]", name: "Opus 1M", providerID: "anthropic"),
            ModelInfo(id: "anthropic/claude-sonnet-5", name: "Claude Sonnet 5", providerID: "openrouter"),
        ]
    }

    @Test func openingReadsInTheRowsOrder() {
        ModelCatalogStore.store(catalog, for: contextID)
        let picked = "session-picked-\(UUID().uuidString)"
        ModelPreferenceStore.setModel(
            ModelSelection(providerID: "anthropic", modelID: "opus[1m]"), forKey: picked)
        ModelPreferenceStore.setGlobalModel(
            ModelSelection(providerID: "anthropic", modelID: "haiku"), forContextID: contextID)

        #expect(
            ModelPreferenceStore.initialModel(
                sessionKey: picked, contextID: contextID, sessionModel: "fable")
                == ModelSelection(providerID: "anthropic", modelID: "opus[1m]"))
        #expect(
            ModelPreferenceStore.initialModel(
                sessionKey: "unpicked-\(UUID().uuidString)", contextID: contextID,
                sessionModel: "fable")
                == ModelSelection(providerID: "anthropic", modelID: "fable"))
        #expect(
            ModelPreferenceStore.initialModel(
                sessionKey: "unpicked-\(UUID().uuidString)", contextID: contextID,
                sessionModel: nil)
                == ModelSelection(providerID: "anthropic", modelID: "haiku"))
    }

    @Test func aBridgeRecordResolvesThroughItsFamilyName() {
        ModelCatalogStore.store(
            [
                ModelInfo(id: "fable", name: "Fable", providerID: "anthropic"),
                ModelInfo(id: "opus", name: "Opus", providerID: "anthropic"),
                ModelInfo(id: "opus[1m]", name: "Opus 1M", providerID: "anthropic"),
            ], for: contextID)
        #expect(
            ModelPreferenceStore.resolveSessionModel("claude-fable-5", contextID: contextID)
                == ModelSelection(providerID: "anthropic", modelID: "fable"))
        #expect(
            ModelPreferenceStore.resolveSessionModel("claude-opus-5", contextID: contextID)
                == ModelSelection(providerID: "anthropic", modelID: "opus"))
    }

    @Test func bareNamesResolveThroughTheCatalogByIdThenName() {
        ModelCatalogStore.store(catalog, for: contextID)
        #expect(
            ModelPreferenceStore.resolveSessionModel("opus[1m]", contextID: contextID)
                == ModelSelection(providerID: "anthropic", modelID: "opus[1m]"))
        #expect(
            ModelPreferenceStore.resolveSessionModel("Opus 1M", contextID: contextID)
                == ModelSelection(providerID: "anthropic", modelID: "opus[1m]"))
        #expect(
            ModelPreferenceStore.resolveSessionModel("anthropic/fable", contextID: contextID)
                == ModelSelection(providerID: "anthropic", modelID: "fable"))
        #expect(
            ModelPreferenceStore.resolveSessionModel(
                "anthropic/claude-sonnet-5", contextID: contextID)
                == ModelSelection(providerID: "openrouter", modelID: "anthropic/claude-sonnet-5"))
    }

    @Test func unresolvableSessionModelFallsBackToRecordedPicks() {
        let empty = "no-catalog-\(UUID().uuidString)"
        let key = "session-2"
        let pick = ModelSelection(providerID: "anthropic", modelID: "sonnet")
        ModelPreferenceStore.setModel(pick, forKey: key)

        let opened = ModelPreferenceStore.initialModel(
            sessionKey: key, contextID: empty, sessionModel: "mystery-model")

        #expect(opened == pick)
    }

    @Test func effortReadsInTheRowsOrder() {
        let picked = "session-picked-effort-\(UUID().uuidString)"
        EffortPreferenceStore.setEffort("low", forKey: picked)
        EffortPreferenceStore.setGlobalEffort("medium", forContextID: contextID)

        #expect(
            EffortPreferenceStore.initialEffort(
                sessionKey: picked, contextID: contextID, sessionEffort: "xhigh") == "low")
        #expect(
            EffortPreferenceStore.initialEffort(
                sessionKey: "unpicked-\(UUID().uuidString)", contextID: contextID,
                sessionEffort: "xhigh") == "xhigh")
        #expect(
            EffortPreferenceStore.initialEffort(
                sessionKey: "unpicked-\(UUID().uuidString)", contextID: contextID,
                sessionEffort: "") == "medium")
    }
}
