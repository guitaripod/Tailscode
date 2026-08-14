import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Model chooser")
struct ModelChooserTests {
    @Test("Families are read from the model name, not the reseller key")
    func familyOf() {
        #expect(ModelFamily.of(name: "Claude Sonnet 5", id: "claude-sonnet-5").title == "Claude")
        #expect(ModelFamily.of(name: "GPT-5.1 Codex", id: "gpt-5.1-codex").title == "GPT")
        #expect(ModelFamily.of(name: "grok-code-fast-1", id: "xai/grok").title == "Grok")
        #expect(ModelFamily.of(name: "DeepSeek V3", id: "deepseek-chat").title == "DeepSeek")
        #expect(ModelFamily.of(name: "Mystery", id: "vendor/mystery-9").title == ModelFamily.other.title)
    }

    @Test("Tokens split letters from digits so GPT-5 and o3 still match")
    func tokens() {
        #expect(ModelFamily.tokens("GPT-5.6").contains("gpt"))
        #expect(ModelFamily.tokens("GPT-5.6").contains("5"))
        #expect(ModelFamily.tokens("deepseek-v4").contains("deepseek"))
        #expect(ModelFamily.tokens("o3-mini").contains("o"))
    }

    @Test("Fold collapses the same model offered by two doors into one candidate")
    func fold() {
        let models = [
            ModelInfo(id: "claude-sonnet-5", name: "Sonnet 5", providerID: "anthropic"),
            ModelInfo(id: "anthropic/claude-sonnet-5", name: "Claude Sonnet 5", providerID: "openrouter"),
            ModelInfo(id: "gpt-5.1", name: "GPT-5.1", providerID: "openai"),
        ]
        let folded = ModelChooser.fold(models)
        #expect(folded.count >= 2)
        #expect(folded.contains { $0.family.title == "Claude" })
        #expect(folded.contains { $0.family.title == "GPT" })
        let offers = folded.flatMap(\.offers).count
        #expect(offers == 3)
    }

    @Test("A folded row's door prefers the model's own key over the reseller")
    func foldDoorPreference() {
        let models = [
            ModelInfo(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", providerID: "opencode-go"),
            ModelInfo(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", providerID: "deepseek"),
        ]
        let folded = ModelChooser.fold(models)
        #expect(folded.count == 1)
        guard let candidate = folded.first else { return }
        #expect(candidate.offers.count == 2)
        #expect(
            candidate.selection
                == ModelSelection(providerID: "deepseek", modelID: "deepseek/deepseek-v4-pro"),
            "the keyed door is the row's pick, not the plan's copy")
    }

    @Test("The door a chat is already on wins a re-pick")
    func foldDoorStickiness() {
        let models = [
            ModelInfo(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", providerID: "opencode-go"),
            ModelInfo(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", providerID: "deepseek"),
        ]
        let onGo = ModelSelection(providerID: "opencode-go", modelID: "deepseek/deepseek-v4-pro")
        let folded = ModelChooser.fold(models, preferred: onGo)
        guard let candidate = folded.first else { return }
        #expect(candidate.selection == onGo, "re-picking keeps the door the chat is on")
    }

    @Test("Shortlist keeps the selection and recents, never invents missing ids")
    func shortlist() {
        let models = (0..<12).map { i in
            ModelInfo(id: "m\(i)", name: "Model \(i)", providerID: "p")
        }
        let selected = ModelSelection(providerID: "p", modelID: "m3")
        let recent = ModelSelection(providerID: "p", modelID: "m7")
        let missing = ModelSelection(providerID: "p", modelID: "nope")
        let short = ModelChooser.shortlist(
            models, selected: selected, limit: 3, recents: [missing, recent])
        #expect(short.count <= 3)
        #expect(short.contains { $0.carries(selected) })
        #expect(short.contains { $0.carries(recent) })
        #expect(!short.contains { $0.carries(missing) })
    }

    @Test("Self-check of the chooser tables stays clean")
    func selfCheck() {
        let issues = ModelChooserCheck.run()
        #expect(issues.isEmpty, "ModelChooserCheck: \(issues)")
    }

    @Test("A server that refused with nothing known is a state, not an empty catalog")
    func downServerReading() {
        let chooser = ModelChooser(models: [], selected: nil, isReachable: false)
        #expect(chooser.summary.contains("not answering"))
        #expect(!chooser.summary.contains("no models"))
    }

    @Test("An ask that has not answered yet says so rather than claiming none")
    func askingServerReading() {
        let chooser = ModelChooser(models: [], selected: nil, isReachable: nil)
        #expect(chooser.summary.contains("Asking"))
        #expect(!chooser.summary.contains("no models"))
    }

    @Test("A server that answered an empty catalog genuinely has no models")
    func genuinelyEmpty() {
        let chooser = ModelChooser(models: [], selected: nil, isReachable: true)
        #expect(chooser.summary == Localized.text("This server lists no models"))
    }

    @Test("A refusal with a remembered list names the list as the last one known")
    func staleListReading() {
        let models = [ModelInfo(id: "qwen3.8-27b", name: "Qwen3.8-27B", providerID: "ollama")]
        let chooser = ModelChooser(models: models, selected: nil, isReachable: false)
        #expect(chooser.catalogSummary.contains("last known"))
        #expect(chooser.catalogSummary.contains("1 model"))
    }
}
