import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Effort vocabulary")
struct EffortVocabularyTests {
    private let claude = ["low", "medium", "high", "xhigh", "max", "ultracode"]
    private let omp = ["minimal", "low", "medium", "high", "xhigh", "max"]
    private let openAI = ["none", "minimal", "low", "medium", "high", "xhigh"]
    private let llamaServer = ["think", "nothink"]
    private let sglang = ["think", "fast"]
    private let gemini = ["low", "high"]
    private let geminiAuto = ["high", "auto", "low"]
    private let reasoningOnly = ["thinking"]
    private let budgets = ["16000", "1024", "4096"]
    private let shouting = ["Low", "MEDIUM", "High"]

    private var every: [[String]] {
        [claude, omp, openAI, llamaServer, sglang, gemini, geminiAuto, reasoningOnly, budgets, shouting,
         ["turbo"], ["low", "turbo", "high"], ["100000", "20000"], ["standard", "deep", "deeper"], ["auto"]]
    }

    @Test("Each real vocabulary runs cold to hot in the model's own spelling")
    func ascending() {
        #expect(ModelDial.ascending(options: claude) == claude)
        #expect(ModelDial.ascending(options: openAI) == openAI)
        #expect(ModelDial.ascending(options: llamaServer) == ["nothink", "think"])
        #expect(ModelDial.ascending(options: sglang) == ["fast", "think"])
        #expect(ModelDial.ascending(options: geminiAuto) == ["auto", "low", "high"])
        #expect(ModelDial.ascending(options: budgets) == ["1024", "4096", "16000"])
        #expect(ModelDial.ascending(options: ["100000", "20000"]) == ["20000", "100000"], "numbers, not an alphabet")
        #expect(ModelDial.ascending(options: ["zeta", "alpha"]) == ["zeta", "alpha"], "a private name keeps the server's order")
        #expect(ModelDial.ascending(options: ["low", "turbo", "high"]) == ["low", "high", "turbo"])
        #expect(ModelDial.ascending(options: shouting) == shouting)
        #expect(ModelDial.ascending(options: ["high", "High", "low"]) == ["low", "high"], "one level, spelled twice, is one rung")
        #expect(ModelDial.ascending(options: ["ultracode", "low"]) == ["low", "ultracode"])
    }

    @Test("Bars never fall along the ladder, never pass the power, and the model deciding lights none")
    func monotonic() {
        for options in every {
            let heats = ModelDial.ascending(options: options).map { ModelDial.heat($0, options: options) }
            #expect(zip(heats, heats.dropFirst()).allSatisfy { $0 <= $1 }, "\(options) → \(heats)")
            #expect(heats.allSatisfy { $0 >= 0 && $0 <= EffortMeter.bars }, "\(options) → \(heats)")
        }
        #expect(ModelDial.heat("auto", options: geminiAuto) == 0)
        #expect(ModelDial.heat("default", options: ["default", "high"]) == 0)
    }

    @Test("A known word lights its tier on every model; an unknown one is placed by where it sits")
    func heat() {
        #expect(ModelDial.heat("high", options: gemini) == 3)
        #expect(ModelDial.heat("High", options: shouting) == 3)
        #expect(ModelDial.heat("xhigh", options: openAI) == 4)
        #expect(ModelDial.heat("think", options: llamaServer) == 2)
        #expect(ModelDial.heat("nothink", options: llamaServer) == 1)
        #expect(ModelDial.heat("fast", options: sglang) == 1)
        #expect(ModelDial.heat("thinking", options: reasoningOnly) == 2)
        #expect(budgets.sorted { Int($0)! < Int($1)! }.map { ModelDial.heat($0, options: budgets) } == [1, 3, 5])
        #expect(ModelDial.heat("turbo", options: ["turbo"]) == 3, "one word alone claims the middle, not the top")
        #expect(ModelDial.heat("turbo", options: ["low", "turbo", "high"]) == 5)
        #expect(ModelDial.isEmber("nothink") && ModelDial.isEmber("off") && ModelDial.isEmber("NONE"))
        #expect(!ModelDial.isEmber("fast") && !ModelDial.isEmber("1024"))
    }

    @Test("Rungs read top down in every vocabulary, the model deciding drawn as the server's stop")
    func rungs() {
        let local = ModelDial.rungs(options: llamaServer)
        #expect(local.map(\.level) == ["think", "nothink", nil])
        #expect(local.map(\.key) == [2, 1, 0])
        #expect(local[1].isEmber && !local[0].isEmber)
        #expect(local.map(\.heat) == [2, 1, 0])
        let auto = ModelDial.rungs(options: geminiAuto)
        #expect(auto.map(\.level) == ["high", "low", "auto", nil])
        #expect(auto[2].isServer && auto[2].heat == 0 && !auto[1].isServer)
        let numbers = ModelDial.rungs(options: budgets)
        #expect(numbers.map(\.level) == ["16000", "4096", "1024", nil])
        #expect(ModelDial.rungs(options: openAI).map(\.heat) == [4, 3, 2, 1, 1, 1, 0])
    }

    @Test("A synonym says what its tier says; a word nobody placed says nothing")
    func captions() {
        #expect(ModelDial.caption("think") == ModelDial.caption("medium"))
        #expect(ModelDial.caption("Thinking") == ModelDial.caption("medium"))
        #expect(ModelDial.caption("fast") == ModelDial.caption("low"))
        #expect(ModelDial.caption("nothink") == ModelDial.caption("none"))
        #expect(ModelDial.caption("deep") == ModelDial.caption("high"))
        #expect(ModelDial.caption("extra-high") == ModelDial.caption("xhigh"))
        #expect(ModelDial.caption("maximum") == ModelDial.caption("max"))
        #expect(ModelDial.caption("minimal") != ModelDial.caption("none"))
        #expect(ModelDial.caption("auto") == "the machine decides")
        #expect(ModelDial.caption("1024").isEmpty && ModelDial.caption("turbo").isEmpty)
        #expect(ModelDial.caption("Ultracode") == Ultracode.menuSubtitle)
        for options in [claude, omp, openAI, llamaServer, sglang, gemini, geminiAuto, reasoningOnly] {
            #expect(ModelDial.rungs(options: options).allSatisfy { !$0.caption.isEmpty }, "\(options)")
        }
    }

    @Test("A step walks the model's own words and never falls onto the model deciding")
    func step() {
        #expect(ModelDial.step(nil, by: 1, options: geminiAuto) == "low")
        #expect(ModelDial.step("low", by: -1, options: geminiAuto) == "low")
        #expect(ModelDial.step("auto", by: 1, options: geminiAuto) == "low")
        #expect(ModelDial.step("auto", by: -1, options: geminiAuto) == "auto")
        #expect(ModelDial.step("nothink", by: 1, options: llamaServer) == "think")
        #expect(ModelDial.step("1024", by: 1, options: budgets) == "4096")
        #expect(ModelDial.step("high", by: -1, options: shouting) == "MEDIUM")
        #expect(ModelDial.step(nil, by: 1, options: ["auto"]) == "auto")
        #expect(ModelDial.step("auto", by: 1, options: ["auto"]) == "auto")
    }

    @Test("Carry compares tiers across vocabularies, both ways, and is never hotter")
    func carry() {
        func to(_ level: String?, _ options: [String]) -> String? { ModelEffort.carry(level, options: options).level }
        #expect(to("think", claude) == "medium")
        #expect(to("thinking", claude) == "medium")
        #expect(to("fast", claude) == "low")
        #expect(to("nothink", claude) == nil)
        #expect(to("none", claude) == nil)
        #expect(to("high", llamaServer) == "think")
        #expect(to("medium", llamaServer) == "think")
        #expect(to("low", llamaServer) == "nothink")
        #expect(to("ultracode", llamaServer) == "think")
        #expect(to("none", llamaServer) == "nothink")
        #expect(to("minimal", llamaServer) == "nothink")
        #expect(to("nothink", openAI) == "none")
        #expect(to("max", openAI) == "xhigh")
        #expect(to("think", openAI) == "medium")
        #expect(to("minimal", claude) == nil, "the floor never lands on low")
        #expect(to("low", ["none", "minimal", "high"]) == "minimal")
        #expect(to("xhigh", gemini) == "high")
        #expect(to("nothink", gemini) == nil)
        #expect(to("think", gemini) == "low")
        #expect(to("high", geminiAuto) == "high")
        #expect(to("medium", geminiAuto) == "low")
        #expect(to("auto", claude) == nil)
        #expect(to("high", sglang) == "think")
        #expect(to("low", sglang) == "fast")
        #expect(to("high", reasoningOnly) == "thinking")
        #expect(to("low", reasoningOnly) == nil)
        #expect(to("high", ["think"]) == "think")
        #expect(to("nothink", ["think"]) == nil)
        #expect(to("high", budgets) == "4096")
        #expect(to("low", budgets) == "1024")
        #expect(to("max", budgets) == "16000")
        #expect(to("minimal", budgets) == nil)
        #expect(to("4096", claude) == nil, "a budget nobody can place goes back to the server")
        #expect(to("4096", ["1024", "4096"]) == "4096")
        #expect(to("HIGH", claude) == "high")
        #expect(to("high", shouting) == "High")
        #expect(to("xhigh", shouting) == "High")
        #expect(ModelEffort.carry("high", options: []).level == nil)
    }

    @Test("The carry's account of itself is true: no move for a case, no claim about a word nobody placed")
    func accounts() {
        #expect(!ModelEffort.carry("HIGH", options: claude).moved)
        #expect(ModelEffort.carry("think", options: claude).notice(modelName: "Opus") == "think moved to medium. Opus has no think.")
        #expect(ModelEffort.carry("high", options: llamaServer).forecast(modelName: "Qwen") == "high will carry over as think.")
        #expect(ModelEffort.carry("auto", options: claude).notice(modelName: "Opus") == "auto handed back to the server. Opus has no auto.")
        #expect(ModelEffort.carry("none", options: gemini).notice(modelName: "Gemini") == "none handed back to the server. Gemini has no cooler level.")
    }

    @Test("Colour follows the tier, so a local model's words wear the colours their tiers have")
    func colour() {
        #expect(ModelTint.authoredEffortHex("think") == ModelTint.authoredEffortHex("medium"))
        #expect(ModelTint.authoredEffortHex("fast") == ModelTint.authoredEffortHex("low"))
        #expect(ModelTint.authoredEffortHex("nothink") == ModelTint.authoredEffortHex("low"))
        #expect(ModelTint.authoredEffortHex("Deep") == ModelTint.authoredEffortHex("high"))
        #expect(ModelTint.authoredEffortHex("maximum") == ModelTint.authoredEffortHex("max"))
        #expect(ModelTint.authoredEffortHex("1024") == nil && ModelTint.authoredEffortHex("auto") == nil)
        #expect(ModelTint.effortClass("think") == "effort-medium")
        #expect(ModelTint.effortClass("nothink") == "effort-low")
        #expect(ModelTint.effortClass("extra-high") == "effort-xhigh")
        #expect(ModelTint.effortClass("auto") == nil && ModelTint.effortClass("4096") == nil)
    }

    @Test("The key ignores case and spaces, and answers come back in the model's spelling")
    func keys() {
        #expect(EffortVocabulary.key("  High ") == "high")
        #expect(EffortVocabulary.same("High", "high") && !EffortVocabulary.same("high", nil))
        #expect(EffortVocabulary.spelling(of: "high", in: shouting) == "High")
        #expect(EffortVocabulary.spelling(of: "", in: [""]) == nil)
        #expect(ModelDial.rank("THINK") == 2 && ModelDial.rank("auto") == nil && ModelDial.rank("ultracode") == nil)
        #expect(ModelDial.isPower("UltraCode"))
    }

    @Test("The demo's machine offers the vocabularies a real fleet sends")
    func demo() async throws {
        let models = try await DemoWorld.openCode.availableModels()
        #expect(ModelEffort.options(models: models, modelID: "ollama/qwen3:14b", agentOptions: []) == ["nothink", "think"])
        #expect(ModelEffort.options(models: models, modelID: "gpt-5.1-codex", agentOptions: []) == openAI)
        #expect(ModelEffort.options(models: models, modelID: "glm-5.3-flash", agentOptions: []) == gemini)
    }
}
