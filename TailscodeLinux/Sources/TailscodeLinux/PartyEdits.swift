import CodingAgentKit
import Foundation
import TailscodeCore

/// The one door through which this client changes the party. Core owns the six slots and tells
/// every surface when they move; the settings file is this client's own, so each change is handed
/// to it here and nowhere else, off the frame it was made in.
enum PartyEdits {
    static func rename(_ slot: Int, _ name: String?) {
        ModelParty.rename(slot: slot, to: name)
        SettingsFile.capture()
    }

    static func setEffort(_ slot: Int, _ effort: PresetEffort) {
        ModelParty.setEffort(slot: slot, effort)
        SettingsFile.capture()
    }

    static func swap(_ first: Int, _ second: Int) {
        ModelParty.swap(first, second)
        SettingsFile.capture()
    }

    static func release(_ slot: Int) {
        ModelParty.release(slot: slot)
        SettingsFile.capture()
    }

    static func replace(_ slot: Int, with preset: ModelPreset) {
        ModelParty.replace(slot: slot, with: preset)
        SettingsFile.capture()
    }

    @discardableResult
    static func place(_ preset: ModelPreset) -> PartyPlacement {
        let placement = ModelParty.place(preset)
        SettingsFile.capture()
        return placement
    }

    /// The level a press on a ball in edit mode asks for: the next of the model's own levels,
    /// coldest to hottest, then the server's own choice, then round to the coldest again. A card
    /// that keeps the level it is taken at starts the walk from the coldest.
    static func nextLevel(after current: PresetEffort, options: [String]) -> PresetEffort? {
        let levels = ModelDial.ascending(options: options)
            .filter { !EffortVocabulary.isAutomatic($0) }
        guard !levels.isEmpty else { return nil }
        let ring: [PresetEffort] = levels.map { .level($0) } + [.server]
        let here: Int?
        switch current {
        case .keep: here = nil
        case .server: here = ring.count - 1
        case .level(let level):
            here = levels.firstIndex { EffortVocabulary.same($0, level) }
        }
        return ring[((here ?? -1) + 1) % ring.count]
    }

    /// The preset a pick would be kept as: the pair it came from when it came from one, else the
    /// model at the level this chat holds, carried onto the model's own levels like any pick, or
    /// the server's choice where the model has none to carry onto.
    static func preset(for pick: ModelPick, inputs: PartyInputs) -> ModelPreset? {
        if let preset = pick.preset { return preset }
        guard let selection = pick.selection else { return nil }
        return preset(for: selection, profileID: pick.profileID, inputs: inputs)
    }

    static func preset(
        for selection: ModelSelection, profileID: String, inputs: PartyInputs
    ) -> ModelPreset {
        let models = inputs.sources.first { $0.profileID == profileID }?.models ?? []
        let options = ModelEffort.options(
            models: models, selection: selection, agentOptions: inputs.agentOptions)
        let carried = ModelEffort.carry(inputs.effort, options: options)
        return ModelPreset(selection: selection, effort: carried.level.map { .level($0) } ?? .server)
    }
}

/// What a party surface reads about the chat it is opened from.
struct PartyInputs: Sendable {
    let sources: [ModelSource]
    let model: ModelSelection?
    let effort: String?
    let agentOptions: [String]
    var recent: [ModelSelection]? = nil

    var cards: [PartyCard] {
        PartyReading.cards(
            slots: ModelParty.slots(), sources: sources, model: model, effort: effort,
            agentOptions: agentOptions)
    }

    var recents: [PartyRecent] {
        PartyReading.recents(
            slots: ModelParty.slots(), sources: sources, recent: recent ?? RecentModelsStore.all())
    }
}
