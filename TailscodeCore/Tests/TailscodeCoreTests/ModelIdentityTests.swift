import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A model's name, hue and section are read from one table, and Claude's words make a model
/// Claude's only when it is: the door is Anthropic's, the name starts with `claude`, or the
/// whole name is an alias.
@Suite struct ModelIdentityTests {
    private let distill = "hf.co/unsloth/Qwen3.5-27B-Claude-Opus-Reasoning-Distilled:Q8_0"

    @Test func claudeIsRecognisedWhereItIsTrue() {
        let cases: [(String, String, ModelTint.Family)] = [
            ("claude-opus-4-8", "Opus", .opus),
            ("opus", "Opus", .opus),
            ("sonnet-5", "Sonnet", .sonnet),
            ("opus[1m]", "Opus", .opus),
            ("anthropic/claude-opus-4", "Opus", .opus),
            ("openrouter/anthropic/claude-3.5-sonnet", "Sonnet", .sonnet),
            ("claude-haiku-4-5-20251001", "Haiku", .haiku),
            ("claude-fable-5", "Fable", .fable),
        ]
        for (id, word, family) in cases {
            #expect(ModelNeedles.isClaude(id), "\(id)")
            #expect(ModelBadge.shortName(id) == word, "\(id)")
            #expect(ModelTint.family(id) == family, "\(id)")
            #expect(ModelFamily.of(name: id, id: id).title == "Claude", "\(id)")
        }
        #expect(ModelBadge.shortName("claude-mythos-5") == "claude-mythos-5")
        #expect(ModelTint.family("claude-mythos-5") == .fable)
    }

    @Test func theDoorSettlesClaude() {
        #expect(ModelNeedles.isClaude("opus-preview", providerID: "anthropic"))
        #expect(ModelBadge.chip(model: "opus-preview", effort: nil, providerID: "anthropic")?.family == .opus)
        #expect(ModelBadge.chip(model: "opus-preview", effort: nil)?.family == nil)
        #expect(
            ModelBadge.label(model: ModelSelection(providerID: "claude", modelID: "best-sonnet"), effort: "high")
                == "Sonnet · high")
    }

    @Test func borrowedClaudeWordsAreNotClaude() {
        #expect(!ModelNeedles.isClaude(distill))
        #expect(ModelBadge.shortName(distill) == "Qwen3.5-27B-Claude-Opus-Reasoning-Distilled")
        #expect(ModelTint.family(distill) == .qwen)
        #expect(ModelTint.family(distill, providerID: "ollama") == .qwen)
        #expect(ModelFamily.of(name: distill, id: distill).title == "Qwen")
        #expect(ModelBadge.chip(model: distill, effort: nil)?.name != "Opus")
        #expect(
            ModelBadge.label(model: ModelSelection(providerID: "ollama", modelID: distill), effort: nil)
                != "Opus")

        #expect(!ModelNeedles.isClaude("some-vendor/haiku-mt"))
        #expect(ModelBadge.shortName("some-vendor/haiku-mt") == "haiku-mt")
        #expect(ModelTint.family("some-vendor/haiku-mt") == nil)
        #expect(!ModelNeedles.isClaude("vendor/opus"))
        #expect(!ModelNeedles.isClaude("opus-mt-en-de"))

        #expect(!ModelNeedles.isClaude("openrouter/stealth/union-alpha"))
        #expect(ModelBadge.shortName("openrouter/stealth/union-alpha") == "union-alpha")
        #expect(ModelTint.family("openrouter/stealth/union-alpha") == nil)
        #expect(ModelFamily.of(name: "Union Alpha", id: "openrouter/stealth/union-alpha") == ModelFamily.other)
    }

    @Test func everyHouseHasItsHueAndItsSection() {
        let cases: [(String, ModelTint.Family, String)] = [
            ("glm-5.3-flash", .glm, "GLM"),
            ("kimi-k2", .kimi, "Kimi"),
            ("devstral-small", .mistral, "Mistral"),
            ("codestral-latest", .mistral, "Mistral"),
            ("o3-mini", .gpt, "GPT"),
            ("o4-mini-high", .gpt, "GPT"),
            ("codex-mini-latest", .gpt, "GPT"),
            ("gpt-5.1-codex-max", .gpt, "GPT"),
            ("gemini-3-pro", .gemini, "Gemini"),
            ("grok-4", .grok, "Grok"),
            ("deepseek-reasoner", .deepseek, "DeepSeek"),
            ("qwen3-14b", .qwen, "Qwen"),
            ("qwen3.8-27b", .qwen, "Qwen"),
            ("ollama/qwen3:14b", .qwen, "Qwen"),
            ("minimax-m2", .minimax, "MiniMax"),
            ("phi-4", .phi, "Phi"),
            ("command-r-plus", .command, "Command"),
            ("gemma3:4b", .gemma, "Gemma"),
            ("meta-llama/llama-4-maverick", .llama, "Llama"),
        ]
        for (id, family, title) in cases {
            #expect(ModelTint.family(id) == family, "\(id)")
            #expect(ModelFamily.of(name: id, id: id).title == title, "\(id)")
        }
        #expect(ModelTint.family("o3xx-preview") == nil)
        #expect(ModelTint.family("ollama/glm-4.7-air") == .glm)
        #expect(ModelTint.family("dolphin-mixtral") == .mistral)
    }

    @Test func sectionsAndHuesComeFromTheSameTable() {
        for (index, house) in ModelNeedles.houses.enumerated() where index != ModelNeedles.claudeIndex {
            for needle in house.needles {
                let id = "\(needle)-7b"
                #expect(ModelFamily.of(name: id, id: id).title == house.title, "\(id)")
                #expect(ModelTint.family(id) == house.tint, "\(id)")
            }
        }
    }

    @Test func shortNamesKeepTheTailThatTellsSiblingsApart() {
        let max = ModelBadge.shortName("gpt-5.1-codex-max")
        let mini = ModelBadge.shortName("gpt-5.1-codex-mini")
        #expect(max == "gpt-5.1-codex-max")
        #expect(mini == "gpt-5.1-codex-mini")
        #expect(max != mini)
        #expect(
            ModelBadge.shortName("gpt-5.1-codex-max", catalogName: "GPT-5.1 Codex Max")
                != ModelBadge.shortName("gpt-5.1-codex-mini", catalogName: "GPT-5.1 Codex Mini"))
        #expect(ModelBadge.shortName("glm-5.3-flash") == "glm-5.3-flash")
        #expect(ModelBadge.shortName("gemini-3-pro") == "gemini-3-pro")
        #expect(ModelBadge.shortName("qwen3-thinking") == "qwen3-thinking")
    }

    @Test func shortNamesDropPackaging() {
        #expect(ModelBadge.shortName("hf.co/unsloth/Qwen3-30B-A3B-GGUF:Q8_0") == "Qwen3-30B-A3B")
        #expect(ModelBadge.shortName("hf.co/unsloth/Qwen3-30B-A3B-GGUF:UD-Q4_K_XL") == "Qwen3-30B-A3B")
        #expect(ModelBadge.shortName("hf.co/org/Qwen3.6-9B:IQ2_M") == "Qwen3.6-9B")
        #expect(ModelBadge.shortName("ollama/qwen3:14b") == "qwen3-14b")
        #expect(ModelBadge.shortName("qwen3:14b-instruct-q8_0") == "qwen3-14b-instruct")
        #expect(ModelBadge.shortName("ollama/llama3:latest") == "llama3")
        #expect(ModelBadge.shortName("ollama-cloud/gpt-oss:120b") == "gpt-oss-120b")
        #expect(ModelBadge.shortName("Llama-3.3-70B-Instruct-AWQ-INT4") == "Llama-3.3-70B-Instruct")
        #expect(ModelBadge.shortName("vllm/Qwen3-32B-nvfp4") == "Qwen3-32B")
        #expect(ModelBadge.shortName("mistral-small-fp8") == "mistral-small")
        #expect(ModelBadge.shortName("codex-mini-latest") == "codex-mini")
        #expect(ModelBadge.shortName("gguf") == "gguf")
        #expect(ModelBadge.shortName("org/gguf:Q8_0") == "gguf")
    }

    @Test func aShortCatalogNameIsPreferred() {
        #expect(ModelBadge.shortName("gpt-5.1-codex-max", catalogName: "GPT-5.1 Codex Max") == "GPT-5.1 Codex Max")
        #expect(ModelBadge.shortName("kimi-k2", catalogName: "Kimi K2") == "Kimi K2")
        #expect(ModelBadge.shortName("qwen3:14b", catalogName: "qwen3:14b") == "qwen3-14b")
        #expect(ModelBadge.shortName("ollama/qwen3:14b", catalogName: "qwen3-14b") == "qwen3-14b")
        #expect(
            ModelBadge.shortName(distill, catalogName: "Qwen3.5 27B Claude Opus Reasoning Distilled")
                == "Qwen3.5-27B-Claude-Opus-Reasoning-Distilled")
        #expect(ModelBadge.shortName("claude-opus-4-8", catalogName: "Claude Opus 4.8") == "Opus")
        #expect(ModelBadge.shortName("claude-mythos-5", catalogName: "Claude Mythos 5") == "Claude Mythos 5")
        #expect(ModelBadge.shortName("union-alpha", catalogName: "  ") == "union-alpha")
        #expect(ModelBadge.shortName("", catalogName: "Mystery") == "Mystery")
        #expect(!ModelBadge.shortName("", catalogName: nil).isEmpty)
        #expect(!ModelBadge.shortName("  ", catalogName: "").isEmpty)
    }

    @Test func theLocalDoorIsTold() {
        #expect(ModelBadge.runsLocally("qwen3:14b", providerID: "ollama"))
        #expect(!ModelBadge.runsLocally("qwen3:14b", providerID: "ollama-cloud"))
        #expect(ModelBadge.runsLocally("ollama/qwen3:14b", providerID: nil))
        #expect(!ModelBadge.runsLocally("ollama-cloud/qwen3:14b", providerID: nil))
        #expect(ModelBadge.runsLocally("ollama/qwen3:14b", providerID: ""))
        #expect(!ModelBadge.runsLocally("qwen3-14b", providerID: nil))
        #expect(!ModelBadge.runsLocally("claude-opus-4-8", providerID: "anthropic"))
        #expect(ModelBadge.localMark("qwen3:14b", providerID: "ollama") == Localized.text("local"))
        #expect(ModelBadge.localMark("qwen3:14b", providerID: "ollama-cloud") == nil)
        #expect(
            ModelBadge.shortName("ollama/qwen3:14b") == ModelBadge.shortName("ollama-cloud/qwen3:14b"))
    }

    /// The houses that gained a hue must be told apart from every hue already on the board at
    /// least as well as the closest pair that was there before (DeepSeek and Llama).
    @Test func newHuesAreDistinct() {
        let added: [ModelTint.Family] = [.glm, .kimi, .minimax, .gemma, .phi, .command]
        for isDark in [true, false] {
            for family in added {
                for other in ModelTint.Family.allCases where other != family {
                    let distance = Self.distance(
                        ModelTint.authoredHex(family, isDark: isDark),
                        ModelTint.authoredHex(other, isDark: isDark))
                    #expect(distance >= 0.08, "\(family) vs \(other): \(distance)")
                }
            }
        }
    }

    private static func distance(_ one: String, _ other: String) -> Double {
        let a = lab(one), b = lab(other)
        return ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2))
            .squareRoot()
    }

    private static func lab(_ hex: String) -> (Double, Double, Double) {
        guard let channels = Contrast.channels(hex) else { return (0, 0, 0) }
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(channels.red), g = linear(channels.green), b = linear(channels.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }
}
