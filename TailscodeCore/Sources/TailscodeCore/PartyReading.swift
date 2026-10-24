import CodingAgentKit
import Foundation

/// One of the six balls as a client draws it: everything a card says, decided here so the phone's
/// sheet and the desktops' popover can never disagree about one slot.
public struct PartyCard: Sendable, Hashable, Identifiable {
    public let slot: Int
    public let preset: ModelPreset?
    public let name: String?
    public let modelWord: String
    public let title: String
    public let subtitle: String
    public let chip: ModelChip?
    public let bars: Int
    public let takesLevels: Bool
    public let machine: String?
    public let profileID: String?
    public let resolved: ModelPreset?
    public let isInUse: Bool
    public let isAway: Bool
    public let spoken: String

    public var id: Int { slot }
    public var isHollow: Bool { preset == nil }
    public var chord: Int { slot + 1 }

    public static func hollow(_ slot: Int) -> PartyCard {
        PartyCard(
            slot: slot, preset: nil, name: nil, modelWord: "", title: "", subtitle: "", chip: nil,
            bars: 0, takesLevels: false, machine: nil, profileID: nil, resolved: nil,
            isInUse: false, isAway: false,
            spoken: Localized.text("Slot %d, empty", slot + 1))
    }
}

/// A model used lately that is not in the party, for the chips under the grid.
public struct PartyRecent: Sendable, Hashable, Identifiable {
    public let selection: ModelSelection
    public let word: String
    public let chip: ModelChip?
    public let profileID: String
    public let machine: String?

    public var id: String { profileID + "·" + selection.rawValue }
}

public enum PartyReading {
    /// The six cards for a surface aimed at the current machine. A slot is read on the machine
    /// that runs it: this one first, then the others in the order they are known, and a slot no
    /// machine can run is away without a place to go.
    public static func cards(
        slots: [PartySlot?], sources: [ModelSource], model: ModelSelection?, effort: String?,
        agentOptions: [String]
    ) -> [PartyCard] {
        (0..<ModelParty.size).map { index in
            guard index < slots.count, let slot = slots[index] else { return .hollow(index) }
            return card(
                index, slot, sources: sources, model: model, effort: effort,
                agentOptions: agentOptions)
        }
    }

    private static func card(
        _ index: Int, _ slot: PartySlot, sources: [ModelSource], model: ModelSelection?,
        effort: String?, agentOptions: [String]
    ) -> PartyCard {
        let located = sources.lazy.compactMap { source in
            ModelPresetCycle.resolve(slot.preset, on: source).map { (source, $0) }
        }.first
        guard let (source, resolved) = located else {
            let word = ModelBadge.shortName(
                slot.preset.selection.modelID, catalogName: nil,
                providerID: slot.preset.selection.providerID)
            return PartyCard(
                slot: index, preset: slot.preset, name: slot.name, modelWord: word,
                title: slot.name ?? word, subtitle: Localized.text("Not on any machine you have"),
                chip: ModelBadge.chip(
                    selection: slot.preset.selection, effort: nil, catalog: []),
                bars: 0, takesLevels: false, machine: nil, profileID: nil, resolved: nil,
                isInUse: false, isAway: true,
                spoken: spoken(index, slot.name ?? word, word, nil, away: true))
        }
        let word = ModelBadge.word(for: resolved.selection, in: source.models)
        let options = ModelEffort.options(
            models: source.models, selection: resolved.selection, agentOptions: agentOptions)
        let asked = resolved.asks(current: effort)
        let face = ModelDial.face(modelWord: word, effort: asked, options: options)
        let takesLevels = ModelEffort.isOffered(options: options)
        let levelWord: String?
        switch resolved.effort {
        case .keep: levelWord = takesLevels ? Localized.text("your level") : nil
        case .server: levelWord = takesLevels ? Localized.text("server") : nil
        case .level: levelWord = face.effortWord
        }
        let subtitle = levelWord.map { word + " · " + $0 } ?? word
        let title = slot.name ?? word
        let away = source.isReachable == false
        let machine = source.isCurrent ? nil : source.title
        return PartyCard(
            slot: index, preset: slot.preset, name: slot.name, modelWord: word, title: title,
            subtitle: subtitle,
            chip: ModelBadge.chip(
                selection: resolved.selection, effort: nil, catalog: source.models),
            bars: takesLevels && resolved.effort != .keep ? face.heat : 0,
            takesLevels: takesLevels, machine: machine,
            profileID: source.profileID, resolved: resolved,
            isInUse: source.isCurrent && resolved.matches(model: model, effort: effort),
            isAway: away,
            spoken: spoken(index, title, subtitle, machine, away: away))
    }

    private static func spoken(
        _ index: Int, _ title: String, _ subtitle: String, _ machine: String?, away: Bool
    ) -> String {
        var parts = [Localized.text("Slot %d", index + 1), title]
        if title != subtitle { parts.append(subtitle) }
        if let machine { parts.append(Localized.text("on %@", machine)) }
        if away { parts.append(Localized.text("not answering")) }
        return parts.joined(separator: ", ")
    }

    /// The models used lately that no slot already holds, as chips: the ones a machine here runs.
    public static func recents(
        slots: [PartySlot?], sources: [ModelSource],
        recent: [ModelSelection] = RecentModelsStore.all(), limit: Int = 2
    ) -> [PartyRecent] {
        let held = Set(slots.compactMap { $0?.preset.selection })
        var found: [PartyRecent] = []
        for selection in recent where !held.contains(selection) {
            guard
                let source = sources.first(where: { $0.models.contains { $0.selection == selection } })
            else { continue }
            found.append(
                PartyRecent(
                    selection: selection,
                    word: ModelBadge.word(for: selection, in: source.models),
                    chip: ModelBadge.chip(selection: selection, effort: nil, catalog: source.models),
                    profileID: source.profileID, machine: source.isCurrent ? nil : source.title))
            if found.count == limit { break }
        }
        return found
    }
}
