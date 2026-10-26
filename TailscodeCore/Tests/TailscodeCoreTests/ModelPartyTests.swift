import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// Six slots, filled or hollow, on this device. Nested under `DeviceStores` because the party,
/// the pins and the stars all live in the one shared `UserDefaults`.
extension DeviceStores {
    @Suite struct ModelPartyTests {
        private static let keys = ["tailscode.modelParty", "tailscode.modelParty.seedRetired", "tailscode.modelPresets", "tailscode.favoriteModels"]

        private func fresh(_ body: () throws -> Void) rethrows {
            let saved = Self.keys.map { UserDefaults.standard.object(forKey: $0) }
            Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
            defer {
                for (key, value) in zip(Self.keys, saved) {
                    if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
                }
            }
            try body()
        }

        private func opus(_ effort: PresetEffort = .level("high")) -> ModelPreset {
            ModelPreset(selection: ModelSelection(providerID: "anthropic", modelID: "opus"), effort: effort)
        }

        private func qwen(_ effort: PresetEffort = .level("think")) -> ModelPreset {
            ModelPreset(selection: ModelSelection(providerID: "llama", modelID: "qwen-daily"), effort: effort)
        }

        @Test func anUnreadPartyIsSixHollowSlots() {
            fresh {
                #expect(ModelParty.slots().count == 6)
                #expect(ModelParty.slots().allSatisfy { $0 == nil })
                #expect(ModelParty.presets().isEmpty)
            }
        }

        @Test func pinsAndStarsNeverFillThePartyAndAReadNeverWritesIt() {
            fresh {
                ModelPresetStore.pin(opus())
                ModelPresetStore.pin(qwen())
                ModelFavoritesStore.replace([ModelSelection(providerID: "x", modelID: "star")])
                #expect(ModelParty.slots().allSatisfy { $0 == nil })
                #expect(ModelParty.presets().isEmpty)
                #expect(UserDefaults.standard.string(forKey: "tailscode.modelParty") == nil)
                #expect(ModelParty.ring() == ModelPresetStore.all())
            }
        }

        @Test func aPartyFilledFromThePinsByAnEarlyBuildIsLetGoOnce() {
            fresh {
                ModelPresetStore.pin(opus())
                ModelPresetStore.pin(qwen())
                ModelParty.replace(slot: 0, with: qwen())
                ModelParty.replace(slot: 1, with: opus())
                UserDefaults.standard.removeObject(forKey: "tailscode.modelParty.seedRetired")
                #expect(ModelParty.slots().allSatisfy { $0 == nil })
                ModelParty.replace(slot: 0, with: qwen())
                ModelParty.replace(slot: 1, with: opus())
                #expect(ModelParty.slots()[0]?.preset == qwen())
                #expect(ModelParty.slots()[1]?.preset == opus())
            }
        }

        @Test func aPartyThePersonEditedSurvivesTheRetirement() {
            fresh {
                ModelPresetStore.pin(opus())
                ModelPresetStore.pin(qwen())
                ModelParty.replace(slot: 0, with: qwen(), name: "Daily")
                ModelParty.replace(slot: 1, with: opus())
                UserDefaults.standard.removeObject(forKey: "tailscode.modelParty.seedRetired")
                #expect(ModelParty.slots()[0]?.name == "Daily")
                #expect(ModelParty.slots()[1]?.preset == opus())
            }
        }

        @Test func placingTakesTheFirstHollowSlotAndNeverTwice() {
            fresh {
                #expect(ModelParty.place(opus()) == .placed(0))
                #expect(ModelParty.place(qwen(), name: "  Local   brain ") == .placed(1))
                #expect(ModelParty.place(opus()) == .placed(0))
                #expect(ModelParty.slot(1)?.name == "Local brain")
                #expect(ModelParty.place(opus(.level("max"))) == .placed(2))
            }
        }

        @Test func aFullPartyAsksInsteadOfMoving() {
            fresh {
                for n in 0..<6 {
                    ModelParty.place(ModelPreset(selection: ModelSelection(providerID: "p", modelID: "m\(n)"), effort: .keep))
                }
                let before = ModelParty.slots()
                #expect(ModelParty.place(opus()) == .full)
                #expect(ModelParty.slots() == before)
                ModelParty.replace(slot: 3, with: opus(), name: "Daily")
                #expect(ModelParty.slot(3)?.preset == opus() && ModelParty.slot(3)?.name == "Daily")
            }
        }

        @Test func releaseRenameLevelAndSwap() {
            fresh {
                ModelParty.place(opus())
                ModelParty.place(qwen())
                ModelParty.rename(slot: 0, to: "Daily")
                ModelParty.setEffort(slot: 0, .level("max"))
                #expect(ModelParty.slot(0)?.preset.effort == .level("max"))
                ModelParty.swap(0, 1)
                #expect(ModelParty.slot(1)?.name == "Daily")
                #expect(ModelParty.slot(0)?.preset == qwen())
                ModelParty.swap(0, 5)
                #expect(ModelParty.slot(0) == nil && ModelParty.slot(5)?.preset == qwen())
                ModelParty.release(slot: 5)
                #expect(ModelParty.slot(5) == nil)
                ModelParty.rename(slot: 1, to: "   ")
                #expect(ModelParty.slot(1)?.name == nil)
            }
        }

        @Test func aNameIsTrimmedCollapsedAndCutAtTheLimit() {
            #expect(ModelParty.normalized("  a \n b  ") == "a b")
            #expect(ModelParty.normalized("") == nil)
            #expect(ModelParty.normalized(nil) == nil)
            let long = ModelParty.normalized(String(repeating: "ab ", count: 30))
            #expect((long?.count ?? 99) <= ModelParty.nameLimit)
            #expect(long?.hasSuffix(" ") == false)
        }

        @Test func theRingIsThePartyAndFallsBackToThePinsWhileItIsEmpty() {
            fresh {
                ModelParty.release(slot: 0)
                UserDefaults.standard.set("[null,null,null,null,null,null]", forKey: "tailscode.modelParty")
                ModelPresetStore.pin(opus())
                #expect(ModelParty.ring() == ModelPresetStore.all())
                ModelParty.place(qwen())
                #expect(ModelParty.ring() == [qwen()])
            }
        }

        @Test func aChatInASlotIsFoundByModelAndLevel() {
            fresh {
                ModelParty.place(opus(.level("high")))
                #expect(ModelParty.index(of: opus().selection, effort: "high") == 0)
                #expect(ModelParty.index(of: opus().selection, effort: "low") == nil)
                #expect(ModelParty.index(of: nil, effort: nil) == nil)
            }
        }

        private func source(
            _ id: String, current: Bool, models: [ModelInfo], reachable: Bool? = true
        ) -> ModelSource {
            ModelSource(
                profileID: id, name: id, backend: .openCode, models: models, isCurrent: current,
                allowsServerDefault: true, acceptsAnyModelID: false, isReachable: reachable)
        }

        @Test func cardsReadHollowHeldAwayAndInUse() {
            let here = source("arch", current: true, models: [
                ModelInfo(id: "qwen-daily", name: "Qwen Daily", providerID: "llama", variants: ["think", "nothink"]),
            ])
            let there = source("macbook", current: false, models: [
                ModelInfo(id: "gpt-5.6", name: "GPT-5.6", providerID: "openai", variants: ["low", "medium", "high"]),
            ])
            let slots: [PartySlot?] = [
                PartySlot(preset: qwen(.level("think")), name: "Local"),
                PartySlot(preset: ModelPreset(selection: ModelSelection(providerID: "openai", modelID: "gpt-5.6"), effort: .level("high"))),
                PartySlot(preset: ModelPreset(selection: ModelSelection(providerID: "nobody", modelID: "ghost"), effort: .keep)),
                nil, nil, nil,
            ]
            let cards = PartyReading.cards(
                slots: slots, sources: [here, there], model: qwen().selection, effort: "think",
                agentOptions: [])
            #expect(cards.count == 6)
            #expect(cards[0].title == "Local" && cards[0].isInUse && cards[0].machine == nil)
            #expect(cards[0].subtitle == "Qwen Daily · think")
            #expect(cards[1].machine == there.title && !cards[1].isInUse && cards[1].bars > 0)
            #expect(cards[1].title == ModelBadge.word(for: cards[1].preset!.selection, in: there.models))
            #expect(cards[2].isAway && cards[2].profileID == nil)
            #expect(cards[3].isHollow && cards[5].isHollow && cards[5].chord == 6)
            #expect(cards[0].spoken.hasPrefix("Slot 1, Local"))
        }

        @Test func everyCardNamesTheServerThatRunsItAndSaysWhenItIsHere() {
            let here = source("arch", current: true, models: [
                ModelInfo(id: "qwen-daily", name: "Qwen Daily", providerID: "llama", variants: ["think"]),
            ], reachable: true)
            let there = source("macbook", current: false, models: [
                ModelInfo(id: "gpt-5.6", name: "GPT-5.6", providerID: "openai"),
            ], reachable: nil)
            let slots: [PartySlot?] = [
                PartySlot(preset: qwen(.level("think"))),
                PartySlot(preset: ModelPreset(selection: ModelSelection(providerID: "openai", modelID: "gpt-5.6"), effort: .keep)),
                PartySlot(preset: ModelPreset(selection: ModelSelection(providerID: "nobody", modelID: "ghost"), effort: .keep)),
                nil, nil, nil,
            ]
            let cards = PartyReading.cards(
                slots: slots, sources: [here, there], model: nil, effort: nil, agentOptions: [])
            #expect(cards[0].server == here.title && cards[0].isHere && cards[0].machine == nil)
            #expect(cards[0].serverAnswers == true)
            #expect(cards[0].spoken.contains("on \(here.title), where you are"))
            #expect(cards[1].server == there.title && !cards[1].isHere && cards[1].machine == there.title)
            #expect(cards[1].serverAnswers == nil)
            #expect(cards[1].spoken.hasSuffix("on \(there.title)"))
            #expect(cards[2].server == nil && !cards[2].isHere)
            #expect(cards[3].server == nil && !cards[3].isHere)
        }

        @Test func aSlotWhoseAccountHasUsedUpItsWindowIsSpentAndSaysSo() {
            let here = source("arch", current: true, models: [
                ModelInfo(id: "claude-opus-5", name: "Claude Opus 5", providerID: "anthropic"),
                ModelInfo(id: "claude-haiku-5", name: "Claude Haiku 5", providerID: "anthropic"),
            ])
            let wall = UsageQuota(
                providerName: "Claude", subtitle: "", source: "test", live: true,
                gauges: [
                    UsageQuota.Gauge(
                        key: "weekly", label: "Weekly", fraction: 1, resetsAt: nil, trustedReset: false)
                ], details: [])
            let slots: [PartySlot?] = [
                PartySlot(preset: ModelPreset(selection: ModelSelection(providerID: "anthropic", modelID: "claude-opus-5"), effort: .keep)),
                nil, nil, nil, nil, nil,
            ]
            let spent = PartyReading.cards(
                slots: slots, sources: [here], model: nil, effort: nil, agentOptions: [], quotas: [wall])
            let open = PartyReading.cards(
                slots: slots, sources: [here], model: nil, effort: nil, agentOptions: [])
            #expect(spent[0].isSpent && spent[0].spoken.hasSuffix("limit reached"))
            #expect(!open[0].isSpent)
        }

        @Test func holdingACardReadsTheModelFromTheServerThatRunsIt() {
            let there = source("macbook", current: false, models: [
                ModelInfo(id: "gpt-5.6", name: "GPT-5.6", providerID: "openai", variants: ["low", "high"], contextWindow: 400_000),
            ])
            let slots: [PartySlot?] = [
                PartySlot(preset: ModelPreset(selection: ModelSelection(providerID: "openai", modelID: "gpt-5.6"), effort: .level("high"))),
                nil, nil, nil, nil, nil,
            ]
            let cards = PartyReading.cards(
                slots: slots, sources: [there], model: nil, effort: nil, agentOptions: [])
            let reading = PartyReading.peek(
                cards[0], sources: [there], selected: nil, effort: nil, agentOptions: [],
                contextTokens: nil)
            #expect(reading?.name == "GPT-5.6")
            #expect(reading?.detail.hasPrefix(there.title) == true)
            #expect(reading?.facts.contains { $0.label == Localized.text("context") } == true)
            #expect(PartyReading.peek(
                .hollow(1), sources: [there], selected: nil, effort: nil, agentOptions: [],
                contextTokens: nil) == nil)
        }

        @Test func holdingACardOnAClaudeCodeServerReadsItsPeekToo() {
            let studio = ModelSource(
                profileID: "studio", name: "studio", backend: .claudeCode,
                models: [
                    ModelInfo(id: "claude-sonnet-5", name: "Sonnet 5", providerID: "anthropic", variants: ["low", "high"], contextWindow: 1_000_000)
                ], isCurrent: true, allowsServerDefault: true, acceptsAnyModelID: true, isReachable: true)
            let slots: [PartySlot?] = [
                PartySlot(preset: ModelPreset(selection: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"), effort: .level("high"))),
                nil, nil, nil, nil, nil,
            ]
            let cards = PartyReading.cards(
                slots: slots, sources: [studio], model: nil, effort: nil, agentOptions: [])
            #expect(cards[0].resolved != nil)
            let reading = PartyReading.peek(
                cards[0], sources: [studio], selected: nil, effort: nil, agentOptions: [],
                contextTokens: nil)
            #expect(reading != nil)
        }

        @Test func aMachineThatDoesNotAnswerDimsItsSlotsButKeepsThem() {
            let down = source("macbook", current: false, models: [
                ModelInfo(id: "gpt-5.6", name: "GPT-5.6", providerID: "openai"),
            ], reachable: false)
            let slots: [PartySlot?] = [
                PartySlot(preset: ModelPreset(selection: ModelSelection(providerID: "openai", modelID: "gpt-5.6"), effort: .keep)),
                nil, nil, nil, nil, nil,
            ]
            let cards = PartyReading.cards(
                slots: slots, sources: [down], model: nil, effort: nil, agentOptions: [])
            #expect(cards[0].isAway && cards[0].machine == down.title)
        }

        @Test func recentsSkipWhatTheyHoldAndWhatNoMachineRuns() {
            let here = source("arch", current: true, models: [
                ModelInfo(id: "a", name: "A", providerID: "p"), ModelInfo(id: "b", name: "B", providerID: "p"),
                ModelInfo(id: "c", name: "C", providerID: "p"),
            ])
            let slots: [PartySlot?] = [
                PartySlot(preset: ModelPreset(selection: ModelSelection(providerID: "p", modelID: "a"), effort: .keep)),
                nil, nil, nil, nil, nil,
            ]
            let recent = [
                ModelSelection(providerID: "p", modelID: "a"), ModelSelection(providerID: "q", modelID: "gone"),
                ModelSelection(providerID: "p", modelID: "b"), ModelSelection(providerID: "p", modelID: "c"),
            ]
            let found = PartyReading.recents(slots: slots, sources: [here], recent: recent, limit: 2)
            #expect(found.map(\.selection.modelID) == ["b", "c"])
            #expect(found.allSatisfy { $0.server == here.title && $0.machine == nil })
        }

        @Test func aPartyPickSaysSoOnEveryMachine() {
            let here = ModelMachine(
                profileID: "a", title: "arch", backend: .openCode, count: 3, localCount: 1,
                isCurrent: true, isReachable: true)
            #expect(here.consequence(for: .party) == "A pick here fills a party slot")
        }
    }
}
