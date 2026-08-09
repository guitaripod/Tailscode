import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// The model colour catalog, proved the way the themes are: every family hue and every effort's
/// heat must be readable on every canvas the app can wear, because a tint that fails on one
/// palette is a label somebody cannot read, not a taste difference.
@Suite struct ModelTintTests {
    private static var canvases: [Palette] {
        AppTheme.all.flatMap { [$0.dark.corrected(), $0.light.corrected()] }
    }

    @Test func everyFamilyReadsOnEveryCanvas() {
        for palette in Self.canvases {
            for family in ModelTint.Family.allCases {
                let hex = ModelTint.hex(family, in: palette)
                let ratio = Contrast.ratio(hex, on: palette.canvas) ?? 0
                #expect(
                    ratio >= Contrast.readable - 0.05,
                    "\(family.rawValue) reads at \(ratio):1 on \(palette.name)")
            }
        }
    }

    @Test func everyEffortTierReadsOnEveryCanvas() {
        for palette in Self.canvases {
            for tier in ModelTint.effortTiers {
                let hex = ModelTint.effortHex(tier, in: palette)
                #expect(hex != nil, "\(tier) has no heat")
                let ratio = hex.flatMap { Contrast.ratio($0, on: palette.canvas) } ?? 0
                #expect(
                    ratio >= Contrast.readable - 0.05,
                    "\(tier) reads at \(ratio):1 on \(palette.name)")
            }
        }
    }

    @Test func ultracodeRainbowReadsOnEveryCanvas() {
        for palette in Self.canvases {
            let letters = ModelTint.rainbow(letters: 9, onCanvas: palette.canvas)
            #expect(letters.count == 9)
            for letter in letters {
                let ratio = Contrast.ratio(letter, on: palette.canvas) ?? 0
                #expect(
                    ratio >= Contrast.readable - 0.05,
                    "a rainbow letter reads at \(ratio):1 on \(palette.name)")
            }
        }
    }

    @Test func familiesAreRecognisedFromAliasAndFullID() {
        #expect(ModelTint.family("claude-fable-5") == .fable)
        #expect(ModelTint.family("fable") == .fable)
        #expect(ModelTint.family("claude-mythos-5") == .fable)
        #expect(ModelTint.family("claude-opus-5[1m]") == .opus)
        #expect(ModelTint.family("sonnet") == .sonnet)
        #expect(ModelTint.family("claude-haiku-4-5-20251001") == .haiku)
        #expect(ModelTint.family("grok-code-fast-1") == .grok)
        #expect(ModelTint.family("gpt-5.2") == .gpt)
        #expect(ModelTint.family("gemini-3-pro") == .gemini)
        #expect(ModelTint.family("ollama/qwen3:14b") == nil)
    }

    @Test func effortSynonymsFoldAndUnknownStaysQuiet() {
        #expect(ModelTint.effortClass("minimal") == "effort-low")
        #expect(ModelTint.effortClass("low") == "effort-low")
        #expect(ModelTint.effortClass("MAX") == "effort-max")
        #expect(ModelTint.effortClass("ultracode") == "effort-ultracode")
        #expect(ModelTint.effortClass("galactic") == nil)
        #expect(ModelTint.authoredEffortHex(Ultracode.effortLevel) == nil)
        for family in ModelTint.Family.allCases {
            #expect(ModelTint.cssClass(family) == "model-\(family.rawValue)")
        }
    }

    @Test func rowChipPrefersTheDevicePickOverTheSessionRecord() {
        let entry = SessionEntry(
            profileID: "srv", profileName: "srv", host: "srv", backendType: .claudeCode,
            session: AgentSession(
                id: "s9", agentType: .claudeCode, title: "chat", directory: nil,
                createdAt: Date(), updatedAt: Date(), model: "claude-opus-5",
                reasoningEffort: "xhigh"))
        let key = "srv/s9"
        ModelPreferenceStore.setModel(nil, forKey: key)
        EffortPreferenceStore.setEffort(nil, forKey: key)
        #expect(
            ModelBadge.chip(for: entry)
                == ModelChip(name: "Opus", family: .opus, effort: "xhigh"))
        ModelPreferenceStore.setModel(
            ModelSelection(providerID: "anthropic", modelID: "claude-fable-5"), forKey: key)
        EffortPreferenceStore.setEffort("ultracode", forKey: key)
        #expect(
            ModelBadge.chip(for: entry)
                == ModelChip(name: "Fable", family: .fable, effort: "ultracode"))
        ModelPreferenceStore.setModel(nil, forKey: key)
        EffortPreferenceStore.setEffort(nil, forKey: key)
    }

    @Test func chipCarriesPartsAndDropsEmptyEffort() {
        let chip = ModelBadge.chip(model: "claude-fable-5", effort: "max")
        #expect(chip == ModelChip(name: "Fable", family: .fable, effort: "max"))
        #expect(chip?.isUltracode == false)
        #expect(ModelBadge.chip(model: "claude-opus-5", effort: "  ")?.effort == nil)
        #expect(ModelBadge.chip(model: nil, effort: "high") == nil)
        #expect(
            ModelBadge.chip(model: "ollama/qwen3:14b", effort: nil)
                == ModelChip(name: "Ollama/qwen3 14b", family: nil, effort: nil))
        #expect(ModelBadge.chip(model: "sonnet", effort: "ultracode")?.isUltracode == true)
    }
}
