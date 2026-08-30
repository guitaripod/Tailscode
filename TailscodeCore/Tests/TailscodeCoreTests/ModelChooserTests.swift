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

    @Test("A door narrows the list to one provider and a pick goes through it")
    func doors() {
        let models = [
            ModelInfo(id: "gpt-oss:120b", name: "gpt-oss:120b", providerID: "ollama-cloud"),
            ModelInfo(id: "glm-5.3-flash", name: "glm-5.3-flash", providerID: "ollama-cloud"),
            ModelInfo(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", providerID: "opencode-go"),
            ModelInfo(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", providerID: "openrouter"),
            ModelInfo(id: "qwen3:14b", name: "qwen3:14b", providerID: "ollama"),
        ]
        var chooser = ModelChooser(models: models, selected: nil, recents: [], quotas: [])
        #expect(chooser.showsDoors)
        #expect(chooser.doors.map(\.providerID) == ["ollama-cloud", "ollama", "opencode-go", "openrouter"])
        #expect(chooser.doors.first { $0.providerID == "ollama" }?.isLocal == true)
        #expect(chooser.doorIndex == 0)
        let openrouter = chooser.setDoor("openrouter")
        #expect(openrouter)
        #expect(chooser.doorIndex == 4)
        #expect(chooser.isNarrowed)
        let names = chooser.rows.filter { !$0.isAuto }.map(\.title)
        #expect(names == ["DeepSeek V4 Pro"])
        #expect(chooser.rows.first { !$0.isAuto }?.selection?.providerID == "openrouter")
        #expect(chooser.summary.contains("OpenRouter"))
        let nowhere = chooser.setDoor("nowhere")
        #expect(!nowhere)
        let cloud = chooser.setDoor("ollama-cloud")
        #expect(cloud)
        #expect(chooser.rows.filter { !$0.isAuto }.count == 2)
        chooser.search("zzz")
        #expect(chooser.emptyResult?.contains("Ollama Cloud") == true)
        chooser.search("")
        let every = chooser.setDoor(nil)
        #expect(every)
        #expect(!chooser.isNarrowed)
        #expect(chooser.rows.filter { !$0.isAuto }.count == 4)
        #expect(ModelChooser.command(for: KeyChord(keyval: 0x0032, control: false, shift: false, alt: true)) == .door(1))
        #expect(ModelChooser.command(for: KeyChord(keyval: 0x0030, control: false, shift: false, alt: true)) == .door(nil))
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

    @Test("Shut families are a list, not an empty one")
    func foldedCatalogIsNotEmpty() {
        let models = (0..<(ModelChooser.foldFrom + 6)).map { index in
            ModelInfo(
                id: "model-\(index)", name: index % 2 == 0 ? "GPT \(index)" : "Claude \(index)",
                providerID: "openrouter")
        }
        let chooser = ModelChooser(models: models, selected: nil)
        #expect(chooser.rows.isEmpty == false || chooser.hidden > 0)
        #expect(chooser.emptyResult == nil)
        var narrowed = chooser
        narrowed.search("zzzzzz-nothing")
        #expect(narrowed.emptyResult != nil)
    }

    @Test("A machine's state is one of four faces and the doors know their kind")
    func stateAndDoorKinds() {
        #expect(
            ModelMachine(
                profileID: "a", title: "a", backend: .openCode, count: 0, localCount: 0,
                isCurrent: true, isReachable: nil
            ).state == .asking)
        #expect(
            ModelMachine(
                profileID: "a", title: "a", backend: .openCode, count: 3, localCount: 0,
                isCurrent: true, isReachable: false
            ).state == .remembered)
        #expect(ModelMachineState.notAnswering.tone == .danger)
        #expect(ModelDoorKind.classify("opencode-go") == .subscription)
        #expect(ModelDoorKind.classify("openrouter") == .gateway)
        #expect(ModelDoorKind.classify("deepseek") == .key)
        #expect(ModelDoor(providerID: "ollama", title: "Ollama", count: 1, isLocal: true).kind == .local)
    }

    @Test("A briefing names the machine, its state, its catalog and its doors")
    func briefing() {
        let source = ModelSource(
            profileID: "p1", name: "arch", backend: .openCode,
            models: [
                ModelInfo(id: "gpt-5", name: "GPT-5", providerID: "openrouter"),
                ModelInfo(id: "gpt-5", name: "GPT-5", providerID: "openai"),
                ModelInfo(id: "qwen3", name: "Qwen 3", providerID: "ollama"),
            ], isCurrent: true, allowsServerDefault: true, acceptsAnyModelID: false,
            isReachable: true)
        let chooser = ModelChooser(sources: [source], selected: nil)
        let card = chooser.briefing(machine: "p1")
        #expect(card?.tone == .live)
        #expect(card?.sections.map(\.heading).count == 3)
        #expect(card?.sections.last?.lines.count == 3)
        let door = chooser.briefing(door: "openrouter")
        #expect(door?.sections.first?.lines.first?.value == ModelDoorKind.gateway.title)
        #expect(chooser.briefing(door: "nope") == nil)
    }
}
