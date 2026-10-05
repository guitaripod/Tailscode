import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Model presets")
struct ModelPresetTests {
    private let opus = ModelSelection(providerID: "anthropic", modelID: "opus")
    private let sonnet = ModelSelection(providerID: "anthropic", modelID: "sonnet")
    private let haiku = ModelSelection(providerID: "anthropic", modelID: "haiku")

    @Test("A preset asks for its own level, and a kept one leaves the level alone")
    func asks() {
        #expect(ModelPreset(selection: opus, effort: .level("max")).asks(current: "low") == "max")
        #expect(ModelPreset(selection: opus, effort: .server).asks(current: "low") == nil)
        #expect(ModelPreset(selection: opus, effort: .keep).asks(current: "low") == "low")
    }

    @Test("A preset is current only when both halves match")
    func matches() {
        let pair = ModelPreset(selection: opus, effort: .level("high"))
        #expect(pair.matches(model: opus, effort: "high"))
        #expect(!pair.matches(model: opus, effort: "max"))
        #expect(!pair.matches(model: sonnet, effort: "high"))
        #expect(ModelPreset(selection: opus, effort: .server).matches(model: opus, effort: nil))
        #expect(ModelPreset(selection: opus, effort: .keep).matches(model: opus, effort: "max"))
        #expect(!pair.matches(model: nil, effort: "high"))
    }

    @Test("Pinning a pair covers the model's bare star, and unpinning takes it too")
    func toggling() {
        let star = ModelPreset(selection: opus, effort: .keep)
        let pair = ModelPreset(selection: opus, effort: .level("xhigh"))
        let pinned = ModelPresetStore.toggled([star], pair)
        #expect(pinned == [pair])
        let off = ModelPresetStore.toggled(pinned, pair)
        #expect(off.isEmpty)
        let both = ModelPresetStore.toggled([pair], ModelPreset(selection: opus, effort: .level("low")))
        #expect(both.count == 2 && both.first?.effort == .level("low"))
        #expect(ModelPresetStore.toggled([], star) == [star])
    }

    @Test("Stepping walks the ring and starts at the end it is walking toward")
    func cycle() {
        let presets = [
            ModelPreset(selection: opus, effort: .level("xhigh")),
            ModelPreset(selection: sonnet, effort: .level("medium")),
            ModelPreset(selection: haiku, effort: .server),
        ]
        #expect(ModelPresetCycle.step(presets, model: opus, effort: "xhigh", by: 1) == presets[1])
        #expect(ModelPresetCycle.step(presets, model: haiku, effort: nil, by: 1) == presets[0])
        #expect(ModelPresetCycle.step(presets, model: opus, effort: "xhigh", by: -1) == presets[2])
        #expect(ModelPresetCycle.step(presets, model: nil, effort: nil, by: 1) == presets[0])
        #expect(ModelPresetCycle.step(presets, model: nil, effort: nil, by: -1) == presets[2])
        #expect(ModelPresetCycle.step([], model: opus, effort: nil, by: 1) == nil)
    }

    @Test("What a step says names the model and the level")
    func said() {
        #expect(ModelPresetCycle.said(ModelPreset(selection: opus, effort: .level("xhigh")), modelName: "Opus") == "Opus · xhigh")
        #expect(ModelPresetCycle.said(ModelPreset(selection: opus, effort: .level("ultracode")), modelName: "Opus") == "Opus · ultracode")
        #expect(ModelPresetCycle.said(ModelPreset(selection: opus, effort: .server), modelName: "Opus") == "Opus · server decides")
        #expect(ModelPresetCycle.said(ModelPreset(selection: opus, effort: .keep), modelName: "Opus") == "Opus")
    }

    @Test("The switch cost is a count of tokens, said only when it is worth saying")
    func switchCost() {
        #expect(SwitchCost.line(contextTokens: nil) == nil)
        #expect(SwitchCost.line(contextTokens: 4_000) == nil)
        #expect(SwitchCost.line(contextTokens: 84_000) == "Switching reads this chat again, uncached: about 84.0k tokens, once.")
    }

    @Test("A level's history is this chat's own settled turns at it")
    func history() {
        func answer(_ effort: String?, _ seconds: TimeInterval?, streaming: Bool = false) -> ChatMessage {
            var message = ChatMessage(
                id: UUID().uuidString, role: .assistant, agentType: .claudeCode, parts: [],
                createdAt: Date(), isStreaming: streaming, reasoningEffort: effort)
            message.duration = seconds
            return message
        }
        let messages = [answer("high", 30), answer("low", 5), answer("high", 50), answer("high", 99, streaming: true)]
        let found = EffortHistory.seconds(level: "high", messages: messages)
        #expect(found?.turns == 2 && found?.average == 40)
        #expect(EffortHistory.seconds(level: "max", messages: messages) == nil)
        #expect(EffortHistory.seconds(level: nil, messages: messages) == nil)
        #expect(EffortHistory.line(level: "high", messages: messages) == "your last 2 turns at this level averaged 40s")
    }
}

@Suite("Model dial presets")
struct ModelDialPresetTests {
    private let claude = ["low", "medium", "high", "xhigh", "max", "ultracode"]
    private let opusInfo = ModelInfo(id: "opus", name: "Opus", providerID: "anthropic", variants: ["low", "medium", "high", "xhigh", "max", "ultracode"])
    private let sonnetInfo = ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic", variants: ["low", "medium", "high"])
    private let qwenInfo = ModelInfo(id: "qwen", name: "Qwen", providerID: "ollama", variants: [])

    private func sources(offline: Bool = false) -> [ModelSource] {
        [
            ModelSource(
                profileID: "arch", name: "arch", backend: .claudeCode,
                models: [opusInfo, sonnetInfo, qwenInfo], isCurrent: true,
                allowsServerDefault: true, acceptsAnyModelID: false, isReachable: true),
            ModelSource(
                profileID: "mini", name: "mini", backend: .claudeCode, models: [],
                isCurrent: false, allowsServerDefault: true, acceptsAnyModelID: false,
                isReachable: offline ? false : true),
        ]
    }

    private func dial(
        effort: String? = "xhigh", presets: [ModelPreset] = [], recents: [ModelSelection] = []
    ) -> ModelDialState {
        ModelDialState(
            sources: sources(), selected: opusInfo.selection, effort: effort, options: claude,
            modelWord: "Opus", recents: recents, presets: presets)
    }

    @Test("Pinned pairs lead the column with their level, and the one that matches is current")
    func pinnedRows() {
        let presets = [
            ModelPreset(selection: sonnetInfo.selection, effort: .level("medium")),
            ModelPreset(selection: opusInfo.selection, effort: .level("xhigh")),
        ]
        let state = dial(presets: presets)
        let rows = state.rows
        #expect(rows[0].section == "Pinned")
        #expect(rows[0].preset == presets[0])
        #expect(rows[0].level?.word == "medium" && rows[0].level?.heat == 2)
        #expect(rows[1].isCurrent && rows[1].level?.word == "xhigh")
        #expect(state.focused?.preset == presets[1], "the cursor opens on what the chat runs")
        #expect(!rows.contains { $0.section == "This chat" }, "a pair that says it already names it")
    }

    @Test("This chat's model is named under its own heading when no pair says it")
    func currentWithoutPair() {
        let state = dial(effort: "high", presets: [
            ModelPreset(selection: opusInfo.selection, effort: .level("xhigh"))])
        #expect(state.rows.contains { $0.section == "This chat" && $0.isCurrent })
    }

    @Test("A star from before presets is a pair that keeps the level")
    func legacyStar() {
        let state = dial(presets: [ModelPreset(selection: sonnetInfo.selection, effort: .keep)])
        let row = state.rows.first { $0.preset != nil }
        #expect(row?.level == nil && row?.isStarred == true)
    }

    @Test("The ladder follows the cursor: a preview of another model's own levels")
    func preview() {
        var state = dial(presets: [ModelPreset(selection: sonnetInfo.selection, effort: .level("medium"))])
        #expect(state.effortIsLive)
        #expect(state.rungs.count == 7)
        _ = state.handle(.up)
        #expect(state.focused?.preset?.selection == sonnetInfo.selection)
        #expect(!state.effortIsLive)
        #expect(state.rungs.map(\.level) == ["high", "medium", "low", nil])
        #expect(state.ladderEffort == "medium")
        #expect(state.headline == "Sonnet takes three levels")
    }

    @Test("A pair that leaves the level to the server lights the server rung, and the pair the chat runs is no preview")
    func serverPairAndCurrentPair() {
        let server = ModelPreset(selection: sonnetInfo.selection, effort: .server)
        let current = ModelPreset(selection: opusInfo.selection, effort: .level("xhigh"))
        var state = dial(effort: "xhigh", presets: [server, current])
        #expect(state.focused?.preset == current)
        #expect(!state.ladderIsPreview, "the pair the chat is at is the chat")
        _ = state.handle(.up)
        #expect(state.focused?.preset == server)
        #expect(state.ladderEffort == nil && state.currentRung?.isServer == true)
        #expect(state.ladderIsPreview)
        guard case .pick(_, let effort) = state.handle(.activate) else { return }
        #expect(effort == .set(nil))
        state.move(to: state.rows.firstIndex { $0.preset == current }!)
        #expect(state.handle(.colder) == .previewed("high"))
        #expect(state.ladderIsPreview, "a step off the pair is a preview of the pick")
    }

    @Test("A model with fewer levels says where the level will go before it is taken")
    func carryNotice() {
        var state = dial(effort: "max", recents: [sonnetInfo.selection])
        guard let recent = state.rows.firstIndex(where: { $0.candidate?.selection == sonnetInfo.selection }) else {
            Issue.record("no recent row"); return
        }
        state.move(to: recent)
        #expect(state.carryNotice == "max will carry over as high.")
        #expect(state.ladderEffort == "high")
        guard case .pick(let pick, let effort) = state.handle(.activate) else {
            Issue.record("enter did not pick"); return
        }
        #expect(pick.selection == sonnetInfo.selection)
        #expect(effort == .set("high"))
    }

    @Test("Stepping a preview rides with the pick and changes nothing in the chat")
    func steppedPreview() {
        var state = dial(effort: "max", recents: [sonnetInfo.selection])
        state.move(to: state.rows.firstIndex { $0.candidate?.selection == sonnetInfo.selection }!)
        #expect(state.handle(.colder) == .previewed("medium"))
        #expect(state.effort == "max", "the composer's own level is untouched")
        #expect(state.carryNotice == nil)
        guard case .pick(_, let effort) = state.handle(.activate) else { return }
        #expect(effort == .set("medium"))
        state.move(to: state.rows.firstIndex { $0.isCurrent }!)
        #expect(state.ladderEffort == "max", "leaving the row drops the preview")
    }

    @Test("On the model this chat runs the level is live and a pick leaves it alone")
    func liveOnCurrent() {
        var state = dial()
        #expect(state.handle(.hotter) == .effort("max"))
        #expect(state.effort == "max")
        guard case .pick(_, let effort) = state.handle(.activate) else { return }
        #expect(effort == .unchanged)
    }

    @Test("Tab moves the arrows to the ladder, and a model with no levels keeps them on the list")
    func columns() {
        var state = dial(effort: "high")
        #expect(state.handle(.switchColumn) == .moved && state.column == .ladder)
        #expect(state.handle(.up) == .effort("xhigh"), "up on the ladder is hotter")
        #expect(state.handle(.down) == .effort("high"))
        #expect(state.handle(.switchColumn) == .moved && state.column == .models)
        var bare = dial(effort: nil, recents: [qwenInfo.selection])
        bare.move(to: bare.rows.firstIndex { $0.candidate?.selection == qwenInfo.selection }!)
        #expect(bare.handle(.switchColumn) == .moved && bare.column == .models)
    }

    @Test("Pinning takes the pair the ladder shows, and a model with no levels pins as a star")
    func pin() {
        var state = dial(effort: "high")
        guard case .pinned(let preset) = state.handle(.pin) else { Issue.record("no pin"); return }
        #expect(preset == ModelPreset(selection: opusInfo.selection, effort: .level("high")))
        #expect(state.rows.first?.preset == preset)
        guard case .pinned(let off) = state.handle(.pin) else { return }
        #expect(off == preset)
        #expect(!state.rows.contains { $0.preset != nil })
        var bare = dial(effort: nil, recents: [qwenInfo.selection])
        bare.move(to: bare.rows.firstIndex { $0.candidate?.selection == qwenInfo.selection }!)
        guard case .pinned(let star) = bare.handle(.pin) else { return }
        #expect(star.effort == .keep)
    }

    @Test("A query with no answer says where it looked, and the cursor skips the message")
    func noResults() {
        var state = dial()
        state.search("zzz-nothing")
        #expect(state.rows.first?.isMessage == true)
        #expect(state.rows.first?.title == "No model matches “zzz-nothing”")
        let names = sources().map(\.title)
        #expect(state.rows.first?.detail == "Searched \(names[0]), \(names[1]).")
        #expect(state.focused?.isMessage == false)
        #expect(state.handle(.up) == .moved)
        #expect(state.focused?.isMessage == false)
        let off = ModelDialState(
            sources: sources(offline: true), selected: opusInfo.selection, effort: nil, options: claude,
            modelWord: "Opus", recents: [], presets: [])
        var offline = off
        offline.search("zzz-nothing")
        #expect(offline.rows.first?.detail == "Searched \(names[0]). \(names[1]) is offline, so it was not searched.")
    }
}

@Suite("Model preset application")
struct ModelPresetApplicationTests {
    private let sonnet = ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic", variants: ["low", "medium", "high"])
    private let opus = ModelInfo(id: "opus", name: "Opus", providerID: "anthropic", variants: ["low", "high", "max"])

    @Test("A pair is applied through the same carry as a pick")
    func applied() {
        let pair = ModelPreset(selection: sonnet.selection, effort: .level("max"))
        let carry = pair.applied(currentEffort: "low", models: [sonnet, opus], agentOptions: [])
        #expect(carry.level == "high" && carry.moved)
        let keep = ModelPreset(selection: opus.selection, effort: .keep)
        #expect(keep.applied(currentEffort: "medium", models: [sonnet, opus], agentOptions: []).level == "low")
        #expect(ModelPreset(selection: sonnet.selection, effort: .server)
            .applied(currentEffort: "high", models: [sonnet], agentOptions: []).level == nil)
    }

    @Test("A pair the next model spells differently resolves through the tiers, with no false notice")
    func spelledDifferently() {
        let qwen = ModelInfo(id: "qwen3:14b", name: "Qwen", providerID: "ollama", variants: ["nothink", "think"])
        let models = [sonnet, opus, qwen]
        let cased = ModelPreset(selection: qwen.selection, effort: .level("THINK"))
            .applied(currentEffort: nil, models: models, agentOptions: [])
        #expect(cased.level == "think" && !cased.moved && cased.notice(modelName: "Qwen") == nil)
        let high = ModelPreset(selection: qwen.selection, effort: .level("high"))
            .applied(currentEffort: nil, models: models, agentOptions: [])
        #expect(high.level == "think")
        #expect(high.notice(modelName: "Qwen") == "high moved to think. Qwen has no high.")
        let think = ModelPreset(selection: sonnet.selection, effort: .level("think"))
            .applied(currentEffort: nil, models: models, agentOptions: [])
        #expect(think.level == "medium")
        let off = ModelPreset(selection: opus.selection, effort: .level("nothink"))
            .applied(currentEffort: nil, models: models, agentOptions: [])
        #expect(off.level == nil, "a level that turns thinking off never lands on one that thinks")
        let kept = ModelPreset(selection: qwen.selection, effort: .keep)
            .applied(currentEffort: "Medium", models: models, agentOptions: [])
        #expect(kept.level == "think")
        let pair = ModelPreset(selection: qwen.selection, effort: .level("Think"))
        #expect(pair.matches(model: qwen.selection, effort: "think"))
        #expect(ModelPresetCycle.step([pair], model: qwen.selection, effort: "think", by: 1) == pair)
    }

    @Test("A step only walks the pairs this machine can run")
    func reachable() {
        let here = ModelPreset(selection: sonnet.selection, effort: .level("high"))
        let there = ModelPreset(selection: ModelSelection(providerID: "ollama", modelID: "qwen"), effort: .keep)
        #expect(ModelPresetCycle.reachable([here, there], models: [sonnet]) == [here])
        #expect(ModelPresetCycle.reachable([here, there], models: [sonnet], acceptsAnyModelID: true) == [here])
    }
}

@Suite("Model peek")
struct ModelPeekTests {
    private func candidate(_ model: ModelInfo, elsewhere: Bool = false) -> ModelCandidate {
        ModelCandidate(
            id: model.id, name: model.name, family: ModelFamily.of(name: model.name, id: model.id),
            offers: [ModelOffer(model: model)],
            profileID: "arch", serverName: "arch", isElsewhere: elsewhere)
    }

    private let sonnet = ModelInfo(
        id: "sonnet", name: "Sonnet", providerID: "anthropic", variants: ["low", "medium", "high"],
        contextWindow: 1_000_000)

    @Test("A card says what the catalog said, and what taking the model would do")
    func reading() {
        let reading = ModelPeekReading.of(
            candidate(sonnet), selected: ModelSelection(providerID: "anthropic", modelID: "opus"),
            effort: "max", agentOptions: [], contextTokens: 84_000)
        #expect(reading.facts.first == .init(value: "1.0M", label: "context"))
        #expect(reading.facts.contains(.init(value: "3", label: "effort levels")))
        #expect(reading.levels == ["low", "medium", "high"])
        #expect(reading.carry == "max will carry over as high.")
        #expect(reading.switchCost == "Switching reads this chat again, uncached: about 84.0k tokens, once.")
        #expect(reading.detail == ProviderIdentity.displayName("anthropic"))
    }

    @Test("The model already running says nothing about switching")
    func current() {
        let reading = ModelPeekReading.of(
            candidate(sonnet), selected: sonnet.selection, effort: "high", agentOptions: [],
            contextTokens: 84_000)
        #expect(reading.carry == nil && reading.switchCost == nil)
    }

    @Test("A model on another machine is a new chat, so there is nothing to switch")
    func elsewhere() {
        let reading = ModelPeekReading.of(
            candidate(sonnet, elsewhere: true), selected: nil, effort: "max", agentOptions: [],
            contextTokens: 84_000)
        #expect(reading.carry == nil && reading.switchCost == nil)
        #expect(reading.detail == "arch · " + ProviderIdentity.displayName("anthropic"))
    }
}
