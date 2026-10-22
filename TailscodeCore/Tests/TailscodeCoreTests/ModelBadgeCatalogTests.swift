import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("A model badge reads the codename of the door it runs through")
struct ModelBadgeCatalogTests {
    private static let bolt = "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf"

    private static func catalog() -> [ModelInfo] {
        [
            ModelInfo(id: bolt, name: "Bolt Unchained", providerID: "llama-server"),
            ModelInfo(id: bolt, name: "Bolt Ollama", providerID: "ollama"),
        ]
    }

    @Test("A session on one door never wears the codename another door gave the same id")
    func doorsKeepTheirOwnCodename() {
        let catalog = Self.catalog()
        #expect(
            ModelBadge.chip(
                model: Self.bolt, effort: nil, providerID: "llama-server", catalog: catalog)?.name
                == "Bolt Unchained")
        #expect(
            ModelBadge.chip(model: Self.bolt, effort: nil, providerID: "ollama", catalog: catalog)?
                .name == "Bolt Ollama")
        let elsewhere = ModelBadge.chip(
            model: Self.bolt, effort: nil, providerID: "vllm", catalog: catalog)?.name
        #expect(elsewhere != "Bolt Unchained")
        #expect(elsewhere != "Bolt Ollama")
    }

    @Test("A model with no stated door takes the first row that carries its id")
    func unstatedDoor() {
        #expect(
            ModelBadge.chip(model: Self.bolt, effort: nil, providerID: nil, catalog: Self.catalog())?
                .name == "Bolt Unchained")
    }

    @Test("A picked model is worded by its own door's row")
    func wordForAPick() {
        let pick = ModelSelection(providerID: "ollama", modelID: Self.bolt)
        #expect(ModelBadge.word(for: pick, in: Self.catalog()) == "Bolt Ollama")
        let stray = ModelSelection(providerID: "vllm", modelID: Self.bolt)
        #expect(!["Bolt Unchained", "Bolt Ollama"].contains(ModelBadge.word(for: stray, in: Self.catalog())))
    }

    @Test("A listed chat reads the catalog its server last gave")
    func rowChipReadsTheCachedCatalog() {
        let profile = "badge-test-profile"
        let key = "\(profile)/badge-session"
        let entry = SessionEntry(
            profileID: profile, profileName: "srv", host: "srv", backendType: .claudeCode,
            session: AgentSession(
                id: "badge-session", agentType: .claudeCode, title: "chat", directory: nil,
                createdAt: Date(), updatedAt: Date(), model: Self.bolt, modelProviderID: "llama-server"))
        ModelPreferenceStore.setModel(nil, forKey: key)
        EffortPreferenceStore.setEffort(nil, forKey: key)
        ModelCatalogStore.forget(profile)
        #expect(ModelBadge.chip(for: entry)?.name != "Bolt Unchained")
        ModelCatalogStore.store(Self.catalog(), for: profile)
        #expect(ModelBadge.chip(for: entry)?.name == "Bolt Unchained")
        ModelCatalogStore.forget(profile)
    }
}
