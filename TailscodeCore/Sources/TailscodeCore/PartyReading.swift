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
    /// The server that runs this slot, named whether or not it is the one the surface is aimed at:
    /// `machine` is what a take would move the work to and is empty on the server in hand, this is
    /// where the model lives, and it is empty only when no server has the model.
    public let server: String?
    public let profileID: String?
    public let resolved: ModelPreset?
    public let isInUse: Bool
    public let isAway: Bool
    /// Whether the account that pays for the model has used up a window that is in front of it, so a
    /// take would be refused; the peek says which window and when it opens.
    public let isSpent: Bool
    /// Whether the server answered its last ask: empty while nobody asked.
    public let serverAnswers: Bool?
    public let spoken: String

    public var id: Int { slot }
    public var isHollow: Bool { preset == nil }
    public var chord: Int { slot + 1 }
    public var isHere: Bool { server != nil && machine == nil }

    public static func hollow(_ slot: Int) -> PartyCard {
        PartyCard(
            slot: slot, preset: nil, name: nil, modelWord: "", title: "", subtitle: "", chip: nil,
            bars: 0, takesLevels: false, machine: nil, server: nil, profileID: nil, resolved: nil,
            isInUse: false, isAway: false, isSpent: false, serverAnswers: nil,
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
    /// The server that runs it, named whether or not it is the one in hand.
    public let server: String
    public let serverAnswers: Bool?

    public var id: String { profileID + "·" + selection.rawValue }
}

public enum PartyReading {
    /// The six cards for a surface aimed at the current machine. A slot is read on the machine
    /// that runs it: this one first, then the others in the order they are known, and a slot no
    /// machine can run is away without a place to go.
    public static func cards(
        slots: [PartySlot?], sources: [ModelSource], model: ModelSelection?, effort: String?,
        agentOptions: [String], quotas: [UsageQuota] = []
    ) -> [PartyCard] {
        (0..<ModelParty.size).map { index in
            guard index < slots.count, let slot = slots[index] else { return .hollow(index) }
            return card(
                index, slot, sources: sources, model: model, effort: effort,
                agentOptions: agentOptions, quotas: quotas)
        }
    }

    private static func card(
        _ index: Int, _ slot: PartySlot, sources: [ModelSource], model: ModelSelection?,
        effort: String?, agentOptions: [String], quotas: [UsageQuota]
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
                bars: 0, takesLevels: false, machine: nil, server: nil, profileID: nil,
                resolved: nil, isInUse: false, isAway: true, isSpent: false, serverAnswers: nil,
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
        let spent = isSpent(resolved.selection, on: source, quotas: quotas)
        return PartyCard(
            slot: index, preset: slot.preset, name: slot.name, modelWord: word, title: title,
            subtitle: subtitle,
            chip: ModelBadge.chip(
                selection: resolved.selection, effort: nil, catalog: source.models),
            bars: takesLevels && resolved.effort != .keep ? face.heat : 0,
            takesLevels: takesLevels, machine: machine, server: source.title,
            profileID: source.profileID, resolved: resolved,
            isInUse: source.isCurrent && resolved.matches(model: model, effort: effort),
            isAway: away, isSpent: spent, serverAnswers: source.isReachable,
            spoken: spoken(
                index, title, subtitle, source.title, here: source.isCurrent, away: away,
                spent: spent))
    }

    private static func isSpent(
        _ selection: ModelSelection, on source: ModelSource, quotas: [UsageQuota]
    ) -> Bool {
        guard !quotas.isEmpty,
            let candidate = ModelChooser.fold(source: source).first(where: { $0.carries(selection) })
        else { return false }
        return ModelChooser.wall(for: candidate, quotas: quotas) != nil
    }

    private static func spoken(
        _ index: Int, _ title: String, _ subtitle: String, _ server: String?, here: Bool = false,
        away: Bool, spent: Bool = false
    ) -> String {
        var parts = [Localized.text("Slot %d", index + 1), title]
        if title != subtitle { parts.append(subtitle) }
        if let server {
            parts.append(
                here ? Localized.text("on %@, where you are", server) : Localized.text("on %@", server))
        }
        if away { parts.append(Localized.text("not answering")) }
        if spent { parts.append(Localized.text("limit reached")) }
        return parts.joined(separator: ", ")
    }

    /// What holding a card shows: the model's own facts from the server that runs it, and what a
    /// take would do to the conversation in hand. Empty for a hollow slot and for a model no
    /// server has.
    public static func peek(
        _ card: PartyCard, sources: [ModelSource], selected: ModelSelection?, effort: String?,
        agentOptions: [String], contextTokens: Int?, quotas: [UsageQuota] = []
    ) -> ModelPeekReading? {
        guard let resolved = card.resolved,
            let source = sources.first(where: { $0.profileID == card.profileID }),
            let candidate = ModelChooser.fold(source: source, preferred: selected)
                .first(where: { $0.carries(resolved.selection) })
        else { return nil }
        return ModelPeekReading.of(
            candidate, selected: selected, effort: effort, agentOptions: agentOptions,
            contextTokens: contextTokens, quotas: quotas, server: source.title)
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
                    profileID: source.profileID, machine: source.isCurrent ? nil : source.title,
                    server: source.title, serverAnswers: source.isReachable))
            if found.count == limit { break }
        }
        return found
    }
}
