import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Aimed model decisions")
struct ModelAimTests {
    private let opus = ModelInfo(
        id: "opus", name: "Opus", providerID: "anthropic",
        variants: ["low", "medium", "high", "xhigh", "max"])
    private let sonnet = ModelInfo(
        id: "sonnet", name: "Sonnet", providerID: "anthropic", variants: ["low", "medium", "high"])
    private let qwen = ModelInfo(id: "qwen3:14b", name: "Qwen3 14B", providerID: "ollama", variants: [])
    private let gptDirect = ModelInfo(id: "gpt-5.1", name: "GPT-5.1", providerID: "openai")
    private let gptRouter = ModelInfo(id: "gpt-5.1", name: "GPT-5.1", providerID: "openrouter")
    private let gptZen = ModelInfo(id: "gpt-5.1", name: "GPT-5.1", providerID: "opencode")

    private func source(
        _ id: String, _ models: [ModelInfo], current: Bool, backend: AgentType = .openCode,
        reachable: Bool? = nil
    ) -> ModelSource {
        ModelSource(
            profileID: id, name: id, backend: backend, models: models, isCurrent: current,
            allowsServerDefault: true, acceptsAnyModelID: ModelFleet.acceptsAnyModelID(backend),
            isReachable: reachable)
    }

    private func pin(_ provider: String, _ model: String, _ level: String? = nil) -> ModelPreset {
        ModelPreset(
            selection: ModelSelection(providerID: provider, modelID: model),
            effort: level.map(PresetEffort.level) ?? .keep)
    }

    @Test("Only the Claude CLI runs an id it never listed")
    func takesAnyID() {
        #expect(!ModelFleet.acceptsAnyModelID(.openCode))
        #expect(ModelFleet.acceptsAnyModelID(.claudeCode))
        #expect(!ModelFleet.acceptsAnyModelID(.omp))
    }

    @Test("A Claude bridge runs Claude pins and nobody else's")
    func claudeHouse() {
        let pins = [
            pin("anthropic", "opus", "max"), pin("ollama", "qwen3:14b", "low"),
            pin("openai", "gpt-5.1-codex", "high"), pin("anthropic", "claude-opus-4-5-20251101"),
            pin("anthropic", "gpt-5"), pin("claude", "sonnet[1m]"),
        ]
        let reachable = ModelPresetCycle.reachable(pins, models: [opus, sonnet], acceptsAnyModelID: true)
        #expect(reachable.map(\.selection.modelID) == ["opus", "claude-opus-4-5-20251101", "sonnet[1m]"])
        let unreported = ModelPresetCycle.reachable(pins, models: [], acceptsAnyModelID: true)
        #expect(unreported.map(\.selection.modelID) == ["opus", "claude-opus-4-5-20251101", "sonnet[1m]"])
    }

    @Test("omp runs what its catalog lists and nothing it does not, menu and cycle alike")
    func ompHouse() {
        let omp = source("pi", [gptDirect, qwen], current: true, backend: .omp)
        let pins = [pin("openai", "gpt-5.1-mini"), pin("anthropic", "opus"), pin("ollama", "qwen3:14b")]
        let viaSource = pins.compactMap { ModelPresetCycle.resolve($0, on: omp) }
        let viaCycle = ModelPresetCycle.reachable(
            pins, models: omp.models, acceptsAnyModelID: ModelFleet.acceptsAnyModelID(.omp))
        #expect(viaSource == viaCycle)
        #expect(viaCycle.map(\.selection.rawValue) == ["ollama/qwen3:14b"])
    }

    @Test("A pin matches its door; the id alone only when the catalog offers it once")
    func doors() {
        let routed = pin("openrouter", "gpt-5.1", "high")
        #expect(
            ModelPresetCycle.resolve(routed, models: [gptZen], acceptsAnyModelID: false)?.selection
                == gptZen.selection)
        #expect(
            ModelPresetCycle.resolve(routed, models: [gptZen, gptDirect], acceptsAnyModelID: false)
                == nil)
        #expect(
            ModelPresetCycle.resolve(routed, models: [gptRouter, gptDirect], acceptsAnyModelID: false)
                == routed)
        #expect(
            ModelPresetCycle.resolve(routed, models: [gptZen], acceptsAnyModelID: false)?.effort
                == .level("high"))
    }

    @Test("Pins another machine runs are placed there, and the cycle says where")
    func away() {
        let mac = source("mac", [opus, sonnet], current: true, backend: .claudeCode)
        let arch = source("arch", [qwen, gptDirect], current: false)
        let placed = ModelPresetCycle.placement(
            [pin("ollama", "qwen3:14b", "low"), pin("perplexity", "sonar")],
            models: mac.models, acceptsAnyModelID: mac.acceptsAnyModelID, elsewhere: [mac, arch])
        #expect(placed.reachable.isEmpty)
        #expect(placed.away.map(\.serverName) == [arch.title, nil])
        #expect(placed.away.first?.profileID == "arch")
        #expect(placed.awayNotice == "Your pins live on \(arch.title)")
        let mixed = ModelPresetCycle.placement(
            [pin("anthropic", "opus", "max"), pin("ollama", "qwen3:14b")],
            models: mac.models, acceptsAnyModelID: true, elsewhere: [arch])
        #expect(mixed.reachable.count == 1 && mixed.away.count == 1)
        #expect(mixed.awayNotice == nil)
        #expect(
            ModelPresetCycle.placement([], models: [], acceptsAnyModelID: true, elsewhere: [arch])
                .awayNotice == nil)
    }

    @Test("Another machine's rows sit under that machine, saying whether it answers")
    func grouping() {
        let layout = ModelMenuLayout.build(
            sources: [
                source("mac", [opus, sonnet], current: true, backend: .claudeCode),
                source("arch", [qwen, gptDirect], current: false, reachable: false),
            ],
            selected: opus.selection, presets: [],
            recents: [qwen.selection, sonnet.selection])
        #expect(layout.here.map(\.candidate.name) == ["Opus", "Sonnet"])
        #expect(layout.here.allSatisfy { !$0.pick.isElsewhere })
        #expect(layout.elsewhere.count == 1)
        let arch = layout.elsewhere[0]
        #expect(arch.entries.map(\.candidate.name) == ["Qwen3 14B"])
        #expect(arch.entries[0].pick.isElsewhere && arch.entries[0].pick.profileID == "arch")
        #expect(arch.state == .remembered)
        #expect(arch.title == "On \(arch.machine)")
        #expect(layout.offersBrowse)
    }

    @Test("One machine draws no groups, and a surface bound to its machine lists only it")
    func single() {
        let mac = source("mac", [opus, sonnet], current: true, backend: .claudeCode)
        let alone = ModelMenuLayout.build(
            sources: [mac], selected: nil, presets: [], recents: [sonnet.selection])
        #expect(alone.elsewhere.isEmpty)
        let bound = ModelMenuLayout.build(
            sources: [mac, source("arch", [qwen], current: false)], selected: nil, presets: [],
            showsElsewhere: false, recents: [qwen.selection, sonnet.selection])
        #expect(bound.elsewhere.isEmpty)
        #expect(bound.here.map(\.candidate.name) == ["Sonnet"])
    }

    @Test("A recent is taken through the door it was used through")
    func recentDoor() {
        let routed = gptRouter.selection
        let layout = ModelMenuLayout.build(
            sources: [source("arch", [gptDirect, gptRouter], current: true)],
            selected: nil, presets: [], recents: [routed])
        #expect(layout.here.count == 1)
        #expect(layout.here[0].selection == routed)
        #expect(layout.here[0].candidate.selection != routed)
    }

    @Test("All models stays offered while pins fill the menu")
    func browse() {
        let haiku = ModelInfo(id: "haiku", name: "Haiku", providerID: "anthropic")
        let mac = source("mac", [opus, sonnet, haiku], current: true, backend: .claudeCode)
        let pins = ["max", "high", "medium", "low"].map { pin("anthropic", "opus", $0) }
        let layout = ModelMenuLayout.build(
            sources: [mac], selected: opus.selection, presets: pins, recents: [sonnet.selection])
        #expect(layout.pins.reachable.count == 4)
        #expect(layout.here.map(\.candidate.name) == ["Sonnet"])
        #expect(layout.offersBrowse)
        let seeded = ModelMenuLayout.build(
            sources: [mac], selected: opus.selection, presets: pins, recents: [])
        #expect(seeded.here.map(\.candidate.name) == ["Sonnet", "Haiku"])
        #expect(!seeded.offersBrowse)
        let everything = ModelMenuLayout.build(
            sources: [mac], selected: opus.selection, presets: [],
            recents: [sonnet.selection, haiku.selection])
        #expect(!everything.offersBrowse)
    }

    @Test("A move keeps the folder only where the new machine knows it, and carries the level")
    func retarget() {
        let pick = ModelPick(
            profileID: "mac", selection: sonnet.selection, isElsewhere: true, serverName: "mac",
            modelName: "Sonnet")
        let move = ComposerRetarget.decide(
            pick: pick, directory: "/srv/app", knownDirectories: ["/home/me"], effort: "max",
            models: [opus, sonnet], agentOptions: [])
        #expect(move.profileID == "mac" && move.model == sonnet.selection)
        #expect(move.directory == nil && move.dropsDirectory)
        #expect(move.effort == "high" && move.carry.moved)
        #expect(move.sentence(machine: "mac", modelWord: "Sonnet") == "Aimed at mac · Sonnet high · No project")
        let stays = ComposerRetarget.decide(
            pick: pick, directory: "/srv/app", knownDirectories: ["/srv/app"], effort: "low",
            models: [opus, sonnet], agentOptions: [])
        #expect(stays.directory == "/srv/app" && !stays.dropsDirectory && stays.effort == "low")
        #expect(stays.sentence(machine: "mac", modelWord: "Sonnet") == "Aimed at mac · Sonnet low")
        let ask = ComposerRetarget.decide(
            pick: pick, directory: nil, knownDirectories: [], effort: nil, models: [], agentOptions: [])
        #expect(!ask.dropsDirectory && ask.directory == nil)
    }

    @Test("A machine row says what it will run, and leads with a machine that is down")
    func machineLine() {
        #expect(AimReading.machineLine(modelWord: "Opus", effort: "high", isReachable: true) == "Opus high")
        #expect(AimReading.machineLine(modelWord: nil, effort: nil, isReachable: nil) == "Auto")
        #expect(
            AimReading.machineLine(modelWord: "Qwen", effort: nil, isReachable: false)
                == "Not answering · Qwen")
        #expect(
            AimReading.choice(modelWord: "Opus", effort: Ultracode.effortLevel)
                == "Opus " + Ultracode.menuTitle.lowercased())
        #expect(
            ComposerRetarget.sentence(machine: "arch", modelWord: nil, effort: nil)
                == "Aimed at arch · Auto")
    }
}
