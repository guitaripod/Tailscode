import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Which catalog row answers for a model's window")
struct ContextWindowCatalogTests {
    private static func row(_ id: String, _ provider: String, _ window: Int?) -> ModelInfo {
        ModelInfo(id: id, name: id, providerID: provider, contextWindow: window)
    }

    private static func window(
        _ model: String, provider: String? = nil, catalog: [ModelInfo], observed: Int = 1_000
    ) -> Int? {
        ContextWindow.resolve(model: model, providerID: provider, catalog: catalog, observed: observed)
    }

    @Test("A stated provider that lists the model keeps another provider's window out of it")
    func statedProviderIsNotOverridden() {
        let catalog = [
            Self.row("glm-5.3", "opencode-go", 500_000),
            Self.row("other-model", "ollama-cloud", 131_072),
        ]
        #expect(Self.window("glm-5.3", provider: "ollama-cloud", catalog: catalog) == 200_000)
    }

    @Test("A stated provider the catalog has never heard of still falls back to the others")
    func unknownProviderFallsThrough() {
        let catalog = [Self.row("glm-5.3", "opencode-go", 200_000)]
        #expect(Self.window("glm-5.3", provider: "mystery", catalog: catalog) == 200_000)
    }

    @Test("A million-token variant that only the catalog carries does not answer for the plain model")
    func variantRowIsNotThePlainModel() {
        let catalog = [Self.row("claude-opus-4-8[1m]", "anthropic", 1_000_000)]
        #expect(Self.window("claude-opus-4-8", catalog: catalog) == 200_000)
        #expect(Self.window("claude-opus-4-8[1m]", catalog: catalog) == 1_000_000)
    }

    @Test("A plain catalog row does not answer for a model that names its variant")
    func plainRowIsNotTheVariant() {
        let catalog = [Self.row("claude-opus-4-8", "anthropic", 200_000)]
        #expect(Self.window("claude-opus-4-8[1m]", catalog: catalog) == 1_000_000)
    }

    @Test("A model that starts with the catalog's alias is that alias")
    func aliasAtTheStart() {
        let catalog = [Self.row("opus", "anthropic", 500_000)]
        #expect(Self.window("opus-4-8-20260101", catalog: catalog) == 500_000)
        #expect(Self.window("claude-opus-4-8-20260101", catalog: catalog) == 500_000)
    }

    @Test("A free tier never reads the paid model's window")
    func freeTierIsItsOwnModel() {
        let catalog = [Self.row("deepseek-v4.1-flash", "opencode", 1_000_000)]
        #expect(
            Self.window("opencode-deepseek-v4.1-flash-free", catalog: catalog) == 200_000)
        #expect(
            Self.window("opencode-deepseek-v4.1-flash-20260101", catalog: catalog) == 1_000_000)
    }

    @Test("Only a real variant marker declares the million")
    func millionNeedsAMarker() {
        #expect(Self.window("claude-sonnet-4-1mini", catalog: []) == 200_000)
        #expect(Self.window("claude-sonnet-4-1m", catalog: []) == 1_000_000)
        #expect(Self.window("claude-sonnet-4-1m-20260101", catalog: []) == 1_000_000)
        #expect(Self.window("claude-sonnet-4[1m]", catalog: []) == 1_000_000)
    }

    @Test("The catalog is believed before a name that merely contains -1m")
    func catalogOutranksTheSubstring() {
        let catalog = [Self.row("vendor-1mx", "vendor", 64_000)]
        #expect(Self.window("vendor-1mx", catalog: catalog) == 64_000)
    }

    @Test("A fill never rewindows to a nil provider by recomputing")
    func rewindowKeepsWhatItHas() {
        let fill = ContextFill(
            used: 10_000, window: 200_000, model: "glm-5.3", basis: .reported,
            providerID: "opencode-go")
        #expect(fill.rewindowed(model: "glm-5.3", providerID: nil) == fill)
        #expect(fill.rewindowed(model: "glm-5.3", providerID: "opencode-go") == fill)
        let moved = fill.rewindowed(
            model: "glm-5.3", providerID: "ollama-cloud",
            catalog: [Self.row("glm-5.3", "ollama-cloud", 131_072)])
        #expect(moved.window == 131_072)
        #expect(moved.providerID == "ollama-cloud")
    }

    @Test("The model and the provider come from the same author")
    func authorOwnsBoth() {
        let catalog = [
            Self.row("glm-5.3", "opencode-go", 200_000),
            Self.row("glm-5.3", "ollama-cloud", 131_072),
        ]
        let message = ChatMessage(
            id: "a1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("ok"))], createdAt: Date(),
            providerID: nil, modelID: "glm-5.3",
            context: MessageUsage(input: 10_000, output: 100))
        let fill = ContextFill.read(
            messages: [message], sessionModel: "other", sessionProvider: "ollama-cloud",
            catalog: catalog)
        #expect(fill?.model == "glm-5.3")
        #expect(fill?.providerID == nil)
        #expect(fill?.window == 131_072)
    }
}
