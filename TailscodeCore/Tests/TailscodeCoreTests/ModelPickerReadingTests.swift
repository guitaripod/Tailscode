import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Model picker readings")
struct ModelPickerReadingTests {
    private static let ladder = ["low", "medium", "high", "xhigh", "max"]

    private let opus = ModelInfo(id: "opus", name: "Opus", providerID: "anthropic", variants: ladder)
    private let duo = ModelInfo(id: "gemini-pro", name: "Gemini Pro", providerID: "google", variants: ["low", "high"])
    private let local = ModelInfo(id: "qwen3:14b", name: "qwen3:14b", providerID: "ollama", variants: ["nothink", "think"])
    private let plain = ModelInfo(id: "plain-1", name: "Plain One", providerID: "openai", variants: [])

    private func source(
        _ models: [ModelInfo], id: String = "arch", name: String = "arch", current: Bool = true
    ) -> ModelSource {
        ModelSource(
            profileID: id, name: name, backend: .openCode, models: models, isCurrent: current,
            allowsServerDefault: true, acceptsAnyModelID: false, isReachable: true)
    }

    private func chooser(
        _ sources: [ModelSource], selected: ModelSelection? = nil, aim: ChooserAim? = nil,
        pins: [ModelPreset] = [], showsPairs: Bool = false, favorites: [ModelSelection] = []
    ) -> ModelChooser {
        ModelChooser(
            sources: sources, selected: selected, recents: [], favorites: favorites, quotas: [],
            showsPairs: showsPairs, pins: pins, aim: aim)
    }

    private func row(_ chooser: ModelChooser, _ title: String, section: String? = nil) -> ModelChooserRow? {
        chooser.rows.first { $0.title == title && (section == nil || $0.sectionID == section) }
    }

    @Test("Without an aim no row reads a level")
    func noAim() {
        let chooser = chooser([source([opus, duo, local, plain])])
        #expect(chooser.rows.allSatisfy { $0.reading == nil })
        #expect(chooser.aim == nil)
    }

    @Test("A Claude ladder keeps the level it is aimed at")
    func claudeLadder() throws {
        let chooser = chooser([source([opus])], aim: ChooserAim(effort: "xhigh", agentOptions: []))
        let reading = try #require(row(chooser, "Opus")?.reading)
        #expect(reading.level == "xhigh" && reading.word == "xhigh" && reading.heat == 4)
        #expect(!reading.moved && reading.hint == nil && reading.takesLevels)
    }

    @Test("A level a model lacks moves to the nearest cooler one, and says so in two words")
    func moved() throws {
        let chooser = chooser([source([duo])], aim: ChooserAim(effort: "xhigh", agentOptions: []))
        let reading = try #require(row(chooser, "Gemini Pro")?.reading)
        #expect(reading.level == "high" && reading.asked == "xhigh" && reading.moved)
        #expect(reading.hint == "xhigh → high")
        #expect(reading.heat == 3)
    }

    @Test("A level with nothing cooler is handed back to the server")
    func handedBack() throws {
        let chooser = chooser([source([duo])], aim: ChooserAim(effort: "minimal", agentOptions: []))
        let reading = try #require(row(chooser, "Gemini Pro")?.reading)
        #expect(reading.level == nil && reading.isServer && reading.word == "server")
        #expect(reading.hint == "minimal → server")
    }

    @Test("A local thinking switch reads on the same scale")
    func thinkSwitch() throws {
        let chooser = chooser([source([local])], aim: ChooserAim(effort: "high", agentOptions: []))
        let reading = try #require(row(chooser, "qwen3:14b")?.reading)
        #expect(reading.level == "think" && reading.moved && reading.hint == "high → think")
        let off = self.chooser([source([local])], aim: ChooserAim(effort: "none", agentOptions: []))
        let cold = try #require(row(off, "qwen3:14b")?.reading)
        #expect(cold.level == "nothink" && cold.isEmber && cold.moved)
    }

    @Test("A model with no levels reads nothing, and its pin keeps the level")
    func noLevels() throws {
        let chooser = chooser([source([plain])], aim: ChooserAim(effort: "high", agentOptions: []))
        let plainRow = try #require(row(chooser, "Plain One"))
        #expect(plainRow.reading == nil)
        #expect(plainRow.pinning.preset == ModelPreset(selection: plain.selection, effort: .keep))
    }

    @Test("The server deciding reads hollow, and the agent's levels stand in for a silent catalog")
    func serverAndAgentOptions() throws {
        let bare = ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic")
        let chooser = chooser(
            [source([bare])], aim: ChooserAim(effort: nil, agentOptions: Self.ladder))
        let sonnet = try #require(row(chooser, "Sonnet"))
        #expect(sonnet.reading?.isServer == true && sonnet.reading?.moved == false)
        #expect(sonnet.pinning.level == .server)
    }

    @Test("Ultracode is spelled lowercase and lights every bar")
    func ultracode() throws {
        let power = ModelInfo(
            id: "fable", name: "Fable", providerID: "anthropic",
            variants: Self.ladder + [Ultracode.effortLevel])
        let chooser = chooser(
            [source([power, duo])], aim: ChooserAim(effort: Ultracode.effortLevel, agentOptions: []))
        let fable = try #require(row(chooser, "Fable")?.reading)
        #expect(fable.isPower && fable.heat == EffortMeter.bars && fable.word == "ultracode")
        let gemini = try #require(row(chooser, "Gemini Pro")?.reading)
        #expect(gemini.hint == "ultracode → high")
    }

    @Test("The row this chat runs reads its own level and never a move")
    func selectedRow() throws {
        let chooser = chooser(
            [source([opus, duo])], selected: opus.selection,
            aim: ChooserAim(effort: "max", agentOptions: []))
        let current = try #require(chooser.rows.first { $0.isSelected && $0.title == "Opus" })
        #expect(current.reading?.level == "max" && current.reading?.moved == false)
    }

    @Test("Setting the aim later redraws the readings, and clearing it takes them away")
    func setAim() {
        var chooser = chooser([source([opus])])
        chooser.setAim(ChooserAim(effort: "high", agentOptions: []))
        #expect(row(chooser, "Opus")?.reading?.level == "high")
        chooser.setAim(nil)
        #expect(row(chooser, "Opus")?.reading == nil)
    }

    @Test("Every row wears a chip but the server's own")
    func chips() {
        let chooser = chooser([source([opus, plain])])
        #expect(row(chooser, "Opus")?.chip?.name == "Opus")
        #expect(chooser.rows.first(where: \.isAuto)?.chip == nil)
    }

    @Test("A pin on a row is the carried pair, and a star or a pair both light it")
    func pinning() throws {
        let aim = ChooserAim(effort: "xhigh", agentOptions: [])
        let starred = chooser([source([opus, duo])], aim: aim, favorites: [opus.selection])
        let opusRow = try #require(row(starred, "Opus"))
        #expect(opusRow.pinning.isPinned && opusRow.isPinned)
        #expect(opusRow.pinning.preset == ModelPreset(selection: opus.selection, effort: .level("xhigh")))
        let duoRow = try #require(row(starred, "Gemini Pro"))
        #expect(!duoRow.pinning.isPinned)
        #expect(duoRow.pinning.preset == ModelPreset(selection: duo.selection, effort: .level("high")))

        let paired = chooser(
            [source([opus, duo])], aim: aim,
            pins: [ModelPreset(selection: duo.selection, effort: .level("low"))])
        let pairedRow = try #require(row(paired, "Gemini Pro"))
        #expect(pairedRow.pinning.isPinned && pairedRow.isPinned)
        #expect(row(paired, "Opus")?.pinning.isPinned == false)
        #expect(chooser([source([opus])]).rows.first { !$0.isAuto }?.pinning.preset?.effort == .keep)
    }

    @Test("Pairs are rows only when asked for, ahead of Yours, at their own level")
    func pairRows() throws {
        let pins = [
            ModelPreset(selection: opus.selection, effort: .level("high")),
            ModelPreset(selection: opus.selection, effort: .server),
            ModelPreset(selection: ModelSelection(providerID: "openai", modelID: "elsewhere-9"), effort: .level("low")),
        ]
        let aim = ChooserAim(effort: "max", agentOptions: [])
        let hidden = chooser([source([opus, duo])], aim: aim, pins: pins)
        #expect(!hidden.sections.contains { $0.id == "·pinned" })

        let shown = chooser([source([opus, duo])], aim: aim, pins: pins, showsPairs: true)
        #expect(shown.sections.first?.id == "·pinned")
        #expect(shown.sections.first?.title == "Pinned")
        let pairs = try #require(shown.sections.first?.rows)
        #expect(pairs.count == 2)
        #expect(Set(pairs.map(\.id)).count == 2)
        #expect(pairs[0].reading?.level == "high" && pairs[0].reading?.moved == false)
        #expect(pairs[1].reading?.isServer == true)
        #expect(pairs.allSatisfy { $0.pinning.isPinned && !$0.canExpand })
        #expect(pairs[0].pick.preset == pins[0])
        #expect(pairs[0].pinning.preset == pins[0])
        #expect(Set(shown.rows.map(\.id)).count == shown.rows.count)

        var searching = shown
        searching.search("opus")
        #expect(!searching.sections.contains { $0.id == "·pinned" })
    }

    @Test("A pair the chat is running is the selected row, and Yours does not list it again")
    func runningPair() {
        let pins = [ModelPreset(selection: opus.selection, effort: .level("high"))]
        let chooser = chooser(
            [source([opus, duo])], selected: opus.selection,
            aim: ChooserAim(effort: "high", agentOptions: []), pins: pins, showsPairs: true)
        #expect(chooser.focused?.sectionID == "·pinned")
        #expect(!chooser.rows.contains { $0.sectionID == "·yours" && $0.title == "Opus" })
    }

    @Test("A pair on another machine is not listed on this one")
    func unreachablePair() {
        let away = ModelInfo(id: "far", name: "Far Model", providerID: "openai", variants: ["low"])
        let pins = [ModelPreset(selection: away.selection, effort: .level("low"))]
        let chooser = chooser(
            [source([opus]), source([away], id: "mini", name: "mini", current: false)],
            pins: pins, showsPairs: true)
        #expect(!chooser.sections.contains { $0.id == "·pinned" })
    }

    @Test("A pair row cannot open onto its doors")
    func pairDoesNotExpand() {
        let routed = ModelInfo(id: "anthropic/opus", name: "Opus", providerID: "openrouter", variants: Self.ladder)
        var chooser = chooser(
            [source([opus, routed])], pins: [ModelPreset(selection: opus.selection, effort: .level("high"))],
            showsPairs: true)
        let opened = chooser.setExpanded(true, at: 0)
        #expect(!opened)
        #expect(chooser.canExpandAny)
    }

    @Test("The place word is local on the machine's own hardware and on another machine's name")
    func places() {
        var chooser = chooser([
            source([opus, local]), source([duo], id: "mini", name: "mini", current: false),
        ])
        #expect(row(chooser, "qwen3:14b")?.place == "local")
        #expect(row(chooser, "Opus")?.place == nil)
        #expect(chooser.rows.first(where: \.isAuto)?.place == nil)
        chooser.search("gemini")
        #expect(chooser.rows.first { $0.sectionID == "·elsewhere" }?.place == "on mini")
    }

    @Test("What a pick elsewhere does depends on where the chooser was opened")
    func consequence() {
        let away = ModelMachine(
            profileID: "mini", title: "mini", backend: .openCode, count: 1, localCount: 0,
            isCurrent: false, isReachable: true)
        #expect(away.consequence == "A pick here starts a new chat on mini")
        #expect(away.consequence(for: .chat) == away.consequence)
        #expect(away.consequence(for: .composer) == "A pick here aims this message at mini")
        #expect(away.consequence(for: .serverDefault) == nil)
        let here = ModelMachine(
            profileID: "arch", title: "arch", backend: .openCode, count: 1, localCount: 0,
            isCurrent: true, isReachable: true)
        #expect(here.consequence(for: .composer) == nil)
    }

    @Test("The chevron hint is owed only when a row can open")
    func canExpandAny() {
        #expect(!chooser([source([opus, duo])]).canExpandAny)
        let routed = ModelInfo(id: "anthropic/opus", name: "Opus", providerID: "openrouter")
        #expect(chooser([source([opus, routed])]).canExpandAny)
    }

    @Test("Doors spell their brands the way their owners do")
    func brands() {
        let expected = [
            "openai": "OpenAI", "openrouter": "OpenRouter", "xai": "xAI", "deepseek": "DeepSeek",
            "github-copilot": "GitHub Copilot", "ollama-cloud": "Ollama Cloud",
            "opencode-go": "OpenCode Go", "google": "Google", "anthropic": "Anthropic",
            "mistral": "Mistral AI", "groq": "Groq", "togetherai": "Together AI",
            "some-new-door": "Some New Door",
        ]
        for (key, name) in expected { #expect(ProviderIdentity.displayName(key) == name) }
        let door = ModelChooser(
            models: [plain, ModelInfo(id: "g", name: "G", providerID: "github-copilot")],
            selected: nil, recents: [], quotas: []
        ).doors.map(\.title)
        #expect(Set(door) == ["OpenAI", "GitHub Copilot"])
    }

    @Test("A local model's card says it runs on the server")
    func peekLocal() {
        let candidate = ModelChooser.fold([local])[0]
        let reading = ModelPeekReading.of(
            candidate, selected: nil, effort: nil, agentOptions: [], contextTokens: nil)
        #expect(reading.facts.contains(.init(value: "Local", label: "Runs on the server's own hardware")))
    }
}

extension DeviceStores {
    @Suite("Model picker pins")
    struct ModelPickerPinTests {
        private let alpha = ModelInfo(
            id: "picker-test-alpha", name: "Picker Alpha", providerID: "picker-test",
            variants: ["low", "medium", "high"])
        private let beta = ModelInfo(
            id: "picker-test-beta", name: "Picker Beta", providerID: "picker-test",
            variants: ["low", "high"])

        private var sources: [ModelSource] {
            [
                ModelSource(
                    profileID: "picker-test", name: "picker-test", backend: .openCode,
                    models: [alpha, beta], isCurrent: true, allowsServerDefault: true,
                    acceptsAnyModelID: false, isReachable: true)
            ]
        }

        /// Runs a test against an empty pin store and puts back whatever was there before.
        private func isolated(_ body: () throws -> Void) rethrows {
            let defaults = UserDefaults.standard
            let saved = (
                defaults.stringArray(forKey: ModelPresetStore.storageKey),
                defaults.stringArray(forKey: ModelFavoritesStore.storageKey)
            )
            defaults.removeObject(forKey: ModelPresetStore.storageKey)
            defaults.removeObject(forKey: ModelFavoritesStore.storageKey)
            defer {
                defaults.set(saved.0, forKey: ModelPresetStore.storageKey)
                defaults.set(saved.1, forKey: ModelFavoritesStore.storageKey)
            }
            try body()
        }

        private func chooser(effort: String? = "high") -> ModelChooser {
            ModelChooser(
                sources: sources, selected: nil, recents: [], favorites: ModelFavoritesStore.all(),
                showsPairs: true, pins: ModelPresetStore.explicit(),
                aim: ChooserAim(effort: effort, agentOptions: []))
        }

        private func row(_ chooser: ModelChooser, _ title: String, section: String) -> ModelChooserRow? {
            chooser.rows.first { $0.title == title && $0.sectionID == section }
        }

        @Test("A pin made elsewhere shows once the chooser refreshes")
        func refresh() throws {
            try isolated {
                var chooser = chooser()
                #expect(!chooser.sections.contains { $0.id == "·pinned" })
                ModelPresetStore.pin(ModelPreset(selection: alpha.selection, effort: .level("low")))
                chooser.refreshPins()
                let pair = try #require(row(chooser, "Picker Alpha", section: "·pinned"))
                #expect(pair.reading?.level == "low")
                let alphas = chooser.rows.filter { $0.title == "Picker Alpha" }
                #expect(alphas.allSatisfy { $0.pinning.isPinned })
            }
        }

        @Test("A starred row's press pins its pair over the star, and a second press takes it off")
        func toggleRow() throws {
            try isolated {
                let high = ModelPreset(selection: alpha.selection, effort: .level("high"))
                ModelFavoritesStore.replace([alpha.selection])
                var chooser = chooser()
                let starred = try #require(chooser.rows.first { $0.title == "Picker Alpha" })
                #expect(starred.pinning.isPinned && starred.pinning.preset == high)
                let pinnedNow = chooser.togglePin(row: starred)
                #expect(pinnedNow)
                #expect(ModelPresetStore.explicit() == [high])
                #expect(ModelFavoritesStore.all().isEmpty)
                #expect(row(chooser, "Picker Alpha", section: "·pinned") != nil)

                let paired = try #require(
                    chooser.rows.first { $0.title == "Picker Alpha" && $0.sectionID != "·pinned" })
                let stillPinned = chooser.togglePin(row: paired)
                #expect(!stillPinned)
                #expect(!ModelPresetStore.isPinned(alpha.selection))
            }
        }

        @Test("A row lit only by a pair at another level is put out whole")
        func litByOtherPair() throws {
            try isolated {
                ModelPresetStore.pin(ModelPreset(selection: alpha.selection, effort: .level("low")))
                var chooser = chooser()
                let lit = try #require(
                    chooser.rows.first { $0.title == "Picker Alpha" && $0.sectionID != "·pinned" })
                #expect(lit.pinning.isPinned)
                let stillLit = chooser.togglePin(row: lit)
                #expect(!stillLit)
                #expect(ModelPresetStore.explicit().isEmpty)
                #expect(!chooser.sections.contains { $0.id == "·pinned" })
            }
        }

        @Test("Unpinning a pair row removes exactly that pair")
        func unpinPair() throws {
            try isolated {
                let low = ModelPreset(selection: alpha.selection, effort: .level("low"))
                let high = ModelPreset(selection: alpha.selection, effort: .level("high"))
                ModelPresetStore.pin(high)
                ModelPresetStore.pin(low)
                var chooser = chooser()
                let pairs = chooser.rows.filter { $0.sectionID == "·pinned" }
                #expect(pairs.count == 2)
                let lowRow = try #require(pairs.first { $0.pinning.preset == low })
                let lowStays = chooser.togglePin(row: lowRow)
                #expect(!lowStays)
                #expect(ModelPresetStore.explicit() == [high])
                #expect(chooser.rows.filter { $0.sectionID == "·pinned" }.count == 1)
            }
        }

        @Test("The desktop star puts out a star lit only by a pair")
        func desktopStar() {
            isolated {
                ModelPresetStore.pin(ModelPreset(selection: beta.selection, effort: .level("low")))
                var chooser = ModelChooser(
                    sources: sources, selected: nil, recents: [], favorites: ModelFavoritesStore.all())
                #expect(chooser.rows.first { $0.title == "Picker Beta" }?.isPinned == true)
                chooser.togglePin(beta.selection)
                #expect(ModelPresetStore.explicit().isEmpty)
                #expect(chooser.rows.first { $0.title == "Picker Beta" }?.isPinned == false)
                chooser.togglePin(beta.selection)
                #expect(ModelFavoritesStore.all() == [beta.selection])
                #expect(chooser.rows.first { $0.title == "Picker Beta" }?.isPinned == true)
            }
        }
    }
}
