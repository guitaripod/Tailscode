import CodingAgentKit
import Foundation

/// Where the pins stand from the machine a surface is aimed at.
public struct PinPlacement: Sendable, Equatable {
    /// A pin this machine cannot run, and the machine that can when one is known.
    public struct Away: Sendable, Hashable {
        public let preset: ModelPreset
        public let profileID: String?
        public let serverName: String?

        public init(preset: ModelPreset, profileID: String?, serverName: String?) {
            self.preset = preset
            self.profileID = profileID
            self.serverName = serverName
        }
    }

    /// The pins this machine runs, each resolved to the door it will take, in pinned order.
    public let reachable: [ModelPreset]
    public let away: [Away]

    public init(reachable: [ModelPreset], away: [Away]) {
        self.reachable = reachable
        self.away = away
    }

    /// What a step along the pins says when it has nowhere to go here but pins do exist: where they
    /// live, rather than an invitation to pin something already pinned. Nil when there is nothing
    /// pinned at all, or no machine known to run any of it — the surface's own invitation then.
    public var awayNotice: String? {
        guard reachable.isEmpty, let machine = away.lazy.compactMap(\.serverName).first else {
            return nil
        }
        return Localized.text("Your pins live on %@", machine)
    }
}

/// One row of the quick menu: the model, and the exact door a tap takes.
public struct ModelMenuEntry: Sendable, Hashable {
    public let candidate: ModelCandidate
    /// The selection the person reached for — a recent's or a star's own door, not the folded
    /// candidate's preferred one.
    public let selection: ModelSelection

    public init(candidate: ModelCandidate, selection: ModelSelection) {
        self.candidate = candidate
        self.selection = selection
    }

    public var pick: ModelPick {
        ModelPick(
            profileID: candidate.profileID, selection: selection,
            isElsewhere: candidate.isElsewhere, serverName: candidate.serverName,
            modelName: candidate.name)
    }
}

/// Another machine's rows in the quick menu, gathered under that machine so the consequence of a
/// tap — the work moves there — is on screen before the tap rather than discovered after it.
public struct ModelMenuGroup: Sendable, Hashable, Identifiable {
    public let profileID: String
    public let machine: String
    public let state: ModelMachineState
    public let entries: [ModelMenuEntry]

    public init(
        profileID: String, machine: String, state: ModelMachineState, entries: [ModelMenuEntry]
    ) {
        self.profileID = profileID
        self.machine = machine
        self.state = state
        self.entries = entries
    }

    public var id: String { profileID }
    public var title: String { Localized.text("On %@", machine) }
    public var detail: String { state.word }
}

/// The quick model menu, decided once for every client that draws one: the pins this machine
/// runs, then the pins it does not with where they live, then the person's own reaching on this
/// machine, then each other machine's under its name, then the road to the whole catalog whenever
/// the menu is showing less than the catalog holds.
public struct ModelMenuLayout: Sendable, Equatable {
    public let pins: PinPlacement
    public let here: [ModelMenuEntry]
    public let elsewhere: [ModelMenuGroup]
    public let offersBrowse: Bool

    public init(pins: PinPlacement, here: [ModelMenuEntry], elsewhere: [ModelMenuGroup], offersBrowse: Bool) {
        self.pins = pins
        self.here = here
        self.elsewhere = elsewhere
        self.offersBrowse = offersBrowse
    }

    /// - Parameters:
    ///   - presets: the pins to place, empty for a surface that offers none.
    ///   - showsElsewhere: false for a surface that can only ever change the machine it belongs to
    ///     (a server's own default), which then lists that machine alone.
    public static func build(
        sources: [ModelSource], selected: ModelSelection?, presets: [ModelPreset],
        showsElsewhere: Bool = true, limit: Int = 8,
        recents: [ModelSelection] = RecentModelsStore.all()
    ) -> ModelMenuLayout {
        let scope = showsElsewhere ? sources : sources.filter(\.isCurrent)
        let current = scope.first(where: \.isCurrent)
        let pins = ModelPresetCycle.placement(
            presets, models: current?.models ?? [],
            acceptsAnyModelID: current?.acceptsAnyModelID ?? false,
            elsewhere: scope.filter { !$0.isCurrent })
        let pinned = pins.reachable.map(\.selection)
        let entries = ModelChooser.shortlistEntries(
            sources: scope, selected: selected, limit: limit, recents: recents, favorites: [],
            excluding: { candidate in
                !candidate.isElsewhere && pinned.contains { candidate.carries($0) }
            })
        let here = entries.filter { !$0.candidate.isElsewhere }
        let groups: [ModelMenuGroup] = scope.filter { !$0.isCurrent }.compactMap { source in
            let rows = entries.filter { $0.candidate.profileID == source.profileID }
            guard !rows.isEmpty else { return nil }
            return ModelMenuGroup(
                profileID: source.profileID, machine: source.title,
                state: machineState(source), entries: rows)
        }
        let candidates = scope.flatMap { ModelChooser.fold(source: $0, preferred: selected) }
        var shown = Set(entries.map(\.candidate.id))
        for candidate in candidates
        where !candidate.isElsewhere && pinned.contains(where: { candidate.carries($0) }) {
            shown.insert(candidate.id)
        }
        return ModelMenuLayout(
            pins: pins, here: here, elsewhere: groups,
            offersBrowse: Set(candidates.map(\.id)).subtracting(shown).count > 0)
    }

    private static func machineState(_ source: ModelSource) -> ModelMachineState {
        switch source.isReachable {
        case .some(false): return source.models.isEmpty ? .notAnswering : .remembered
        case .some(true), .none: return .answering
        }
    }
}

/// What a machine will run, said the way the pill says it, for every place a machine is offered
/// before it is chosen.
public enum AimReading {
    /// "Opus high", "Auto": the model word and the level word, or the server deciding.
    public static func choice(modelWord: String?, effort: String?) -> String {
        let model = modelWord ?? Localized.text("Auto")
        guard let effort, !effort.isEmpty else { return model }
        return model + " " + (ModelDial.isPower(effort) ? Ultracode.menuTitle.lowercased() : effort)
    }

    /// A machine row's subtitle: what it will run, led by the fact that it is not answering when
    /// that is the case — a pick aimed at a machine that is down fails at the send, so it is said
    /// at the aim.
    public static func machineLine(modelWord: String?, effort: String?, isReachable: Bool?) -> String {
        let runs = choice(modelWord: modelWord, effort: effort)
        guard isReachable == false else { return runs }
        return ModelMachineState.notAnswering.word + " · " + runs
    }
}

/// What a pick of another machine's model does to a composer that is not yet a chat: the
/// composer goes to that machine — machine, model and level are one aimed decision — and says so
/// once. Toolkit-free so every client moves the same way.
public struct ComposerRetarget: Sendable, Equatable {
    public let profileID: String
    public let model: ModelSelection?
    /// The folder the composer keeps: the old one only when the new machine knows it.
    public let directory: String?
    /// True when a folder was aimed at and the new machine does not know it.
    public let dropsDirectory: Bool
    /// The level, carried onto the new model's own levels on the new machine's catalog.
    public let carry: EffortCarry

    public var effort: String? { carry.level }

    public static func decide(
        pick: ModelPick, directory: String?, knownDirectories: [String], effort: String?,
        models: [ModelInfo], agentOptions: [String]
    ) -> ComposerRetarget {
        let keeps = directory.map { knownDirectories.contains($0) } ?? false
        return ComposerRetarget(
            profileID: pick.profileID, model: pick.selection,
            directory: keeps ? directory : nil, dropsDirectory: directory != nil && !keeps,
            carry: ModelEffort.adoption(
                effort, for: pick.selection, models: models, agentOptions: agentOptions))
    }

    /// The one sentence a move earns: where, on what, and the folder left behind when one was.
    public func sentence(machine: String, modelWord: String?) -> String {
        var parts = [
            Localized.text("Aimed at %@", machine),
            AimReading.choice(modelWord: modelWord, effort: effort),
        ]
        if dropsDirectory { parts.append(Localized.text("No project")) }
        return parts.joined(separator: " · ")
    }

    /// The same sentence for a machine chosen by hand, where nothing moved but the machine.
    public static func sentence(machine: String, modelWord: String?, effort: String?) -> String {
        Localized.text("Aimed at %@", machine) + " · "
            + AimReading.choice(modelWord: modelWord, effort: effort)
    }
}
