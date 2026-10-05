import Foundation
import Testing

@testable import TailscodeCore

@Suite("Claude aliases")
struct ModelAliasTests {
    @Test("Every alias the Claude CLI resolves on its own is Claude, wherever the rule is asked")
    func aliases() {
        for alias in ["opus", "sonnet", "haiku", "fable", "opusplan", "opus[1m]", "sonnet-5"] {
            #expect(ModelNeedles.isClaude(alias), "\(alias)")
            #expect(ModelPresetCycle.isClaudeID(alias), "\(alias)")
        }
        for lookalike in ["haiku-mt", "opus-mt-en-de", "vendor/opus"] {
            #expect(!ModelNeedles.isClaude(lookalike), "\(lookalike)")
        }
    }

    @Test("A long catalog name never beats a shorter id on the pill")
    func shorterWins() {
        let name = "Qwen3 Coder 480B A35B Instruct Preview"
        let word = ModelBadge.shortName("qwen3-coder-480b", catalogName: name, providerID: "ollama")
        #expect(word.count <= 18)
    }
}
