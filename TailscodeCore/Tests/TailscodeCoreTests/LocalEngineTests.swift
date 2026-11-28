import CodingAgentKit
import Testing

@testable import TailscodeCore

@Suite("A model is served by an engine, and found by the words its descriptor uses")
struct LocalEngineTests {
    private func source(
        profile: String = "arch", providers: [String: [(String, String)]]
    ) -> ModelSource {
        ModelSource(
            profileID: profile, name: profile, backend: .openCode,
            models: providers.flatMap { providerID, entries in
                entries.map { ModelInfo(id: $0.0, name: $0.1, providerID: providerID) }
            },
            isCurrent: true, allowsServerDefault: true, acceptsAnyModelID: false)
    }

    @Test("SGLang is a local engine with a name of its own, like llama.cpp is")
    func identity() {
        #expect(ProviderIdentity.displayName("sglang") == "SGLang")
        #expect(ProviderIdentity.isLocal("sglang"))
        #expect(ProviderIdentity.displayName("llama-server") == "llama.cpp")
    }

    @Test("An engine that is not llama.cpp is its own door, so the row does not call it llama.cpp")
    func doors() {
        let chooser = ModelChooser(
            models: source(providers: [
                "llama-server": [("bolt", "Bolt")],
                "sglang": [("inkling-2-mini-26b-gguf", "Inkling")],
            ]).models,
            selected: nil, recents: [])
        #expect(chooser.showsDoors)
        #expect(Set(chooser.doors.map(\.title)) == ["llama.cpp", "SGLang"])
        #expect(chooser.rows.first { $0.title == "Inkling" }?.detail.contains("SGLang") == true)
    }

    @Test("A descriptor finds its model even where the catalog carries none of the descriptor")
    func descriptor() {
        var chooser = ModelChooser(
            models: source(providers: [
                "llama-server": [("bolt-nvfp4", "Bolt")],
                "sglang": [("inkling-2-mini-26b-gguf", "Inkling")],
            ]).models,
            selected: nil, recents: [])
        chooser.search("inkling 2 mini nvfp4")
        #expect(chooser.rows.first?.title == "Inkling")
    }

    @Test("A query every word of which the catalog answers is answered strictly")
    func strict() {
        var chooser = ModelChooser(
            models: [
                ModelInfo(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", providerID: "anthropic"),
                ModelInfo(id: "claude-opus-4-5", name: "Claude Opus 4.5", providerID: "anthropic"),
            ],
            selected: nil, recents: [])
        chooser.search("sonnet 4.5")
        #expect(chooser.rows.count == 1)
        #expect(chooser.rows.first?.title == "Claude Sonnet 4.5")
    }

    @Test("A word nothing in the catalog says still finds nothing")
    func nothing() {
        var chooser = ModelChooser(
            models: source(providers: ["sglang": [("inkling-2-mini-26b-gguf", "Inkling")]]).models,
            selected: nil, recents: [])
        chooser.search("nvfp4")
        #expect(chooser.rows.isEmpty)
    }
}
