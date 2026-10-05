import CodingAgentKit
import Foundation

/// What a preset does to the level when it is taken.
///
/// A star on a model has always meant "this one, however I was working", and a person who starred
/// a model before presets existed must keep meaning that: so a preset either names its level —
/// including the server's own choice, which is a real answer — or leaves the level where it is,
/// subject to the same carry as any model pick.
public enum PresetEffort: Sendable, Hashable {
    case keep
    case server
    case level(String)

    var raw: String {
        switch self {
        case .keep: return "keep"
        case .server: return "server"
        case .level(let level): return "level:" + level
        }
    }

    init?(raw: String) {
        switch raw {
        case "keep": self = .keep
        case "server": self = .server
        default:
            guard raw.hasPrefix("level:"), raw.count > 6 else { return nil }
            self = .level(String(raw.dropFirst(6)))
        }
    }
}

/// A model and a level pinned together, because on a desk the two are one decision. One tap on a
/// preset sets both, the way a lens and an aperture are one setting for a photographer.
public struct ModelPreset: Sendable, Hashable, Identifiable {
    public let selection: ModelSelection
    public let effort: PresetEffort

    public init(selection: ModelSelection, effort: PresetEffort) {
        self.selection = selection
        self.effort = effort
    }

    public var id: String { selection.rawValue + "·" + effort.raw }

    /// The level a pick of this preset asks for, before the model has its say: nil is the server
    /// deciding, and `current` is what a `.keep` preset leaves untouched.
    public func asks(current: String?) -> String? {
        switch effort {
        case .keep: return current
        case .server: return nil
        case .level(let level): return level
        }
    }

    /// What taking this preset does to a chat on a machine whose catalog is `models`: the level the
    /// pair asks for, carried onto the model's own levels like any pick, with the account of it. A
    /// level the model spells differently resolves through the same tiers, in the model's spelling,
    /// and a difference of case alone is no move and says nothing.
    public func applied(
        currentEffort: String?, models: [ModelInfo], agentOptions: [String]
    ) -> EffortCarry {
        ModelEffort.adoption(
            asks(current: currentEffort), for: selection, models: models,
            agentOptions: agentOptions)
    }

    /// Whether this preset is what a chat is running right now.
    public func matches(model: ModelSelection?, effort level: String?) -> Bool {
        guard let model, model == selection else { return false }
        switch effort {
        case .keep: return true
        case .server: return level == nil
        case .level(let wanted): return level.map { EffortVocabulary.same($0, wanted) } ?? false
        }
    }
}

/// The pairs a person has pinned, on this device. Models starred before presets existed stay in
/// the list as presets that keep the level, below the explicit pairs and only while the same
/// model has no explicit pair — so the migration is a reading, not a rewrite, and un-starring a
/// model in the catalog still removes it from here.
public enum ModelPresetStore {
    static let storageKey = "tailscode.modelPresets"
    public static let limit = 12

    public static func explicit() -> [ModelPreset] {
        (UserDefaults.standard.stringArray(forKey: storageKey) ?? []).compactMap(decode)
    }

    public static func all(favorites: [ModelSelection] = ModelFavoritesStore.all()) -> [ModelPreset] {
        let pairs = explicit()
        let covered = Set(pairs.map(\.selection))
        let kept = favorites.filter { !covered.contains($0) }
            .map { ModelPreset(selection: $0, effort: .keep) }
        return pairs + kept
    }

    /// The list after a pair is pinned or unpinned. Unpinning takes the model's older star with
    /// it, so a pair removed does not leave the bare model standing where it was; pinning a pair
    /// covers the model's bare star, which is the same model said more precisely.
    public static func toggled(_ list: [ModelPreset], _ preset: ModelPreset) -> [ModelPreset] {
        var result = list
        if let index = result.firstIndex(of: preset) {
            result.remove(at: index)
            result.removeAll { $0.selection == preset.selection && $0.effort == .keep }
            return result
        }
        if preset.effort != .keep {
            result.removeAll { $0.selection == preset.selection && $0.effort == .keep }
        }
        result.insert(preset, at: 0)
        return result
    }

    /// Pins or unpins a pair and keeps the whole list. A preset that keeps the level is a star and
    /// lives where stars always did, so the catalog's star and this list never disagree.
    @discardableResult
    public static func pin(_ preset: ModelPreset) -> Bool {
        let after = toggled(all(), preset)
        persist(after)
        return after.contains(preset)
    }

    /// Takes every pin of one model through one door off the list — its star and each pair — for
    /// a star that reads lit because of any of them: pressing a lit star has to put it out.
    public static func unpinAll(_ selection: ModelSelection) {
        persist(all().filter { $0.selection != selection })
    }

    /// Whether any pin — a star or a pair — stands on this model through this door.
    public static func isPinned(_ selection: ModelSelection) -> Bool {
        all().contains { $0.selection == selection }
    }

    private static func persist(_ presets: [ModelPreset]) {
        store(Array(presets.filter { $0.effort != .keep }.prefix(limit)))
        ModelFavoritesStore.replace(presets.filter { $0.effort == .keep }.map(\.selection))
    }

    /// Moves a pair to a new place among the explicit pairs, for a surface that lets the order be
    /// edited.
    public static func move(_ preset: ModelPreset, to index: Int) {
        var presets = explicit()
        guard let from = presets.firstIndex(of: preset) else { return }
        presets.remove(at: from)
        presets.insert(preset, at: max(0, min(presets.count, index)))
        store(presets)
    }

    private static func store(_ presets: [ModelPreset]) {
        UserDefaults.standard.set(presets.map(encode), forKey: storageKey)
    }

    private static func encode(_ preset: ModelPreset) -> String {
        preset.effort.raw + "|" + preset.selection.rawValue
    }

    private static func decode(_ raw: String) -> ModelPreset? {
        guard let bar = raw.firstIndex(of: "|"),
            let effort = PresetEffort(raw: String(raw[..<bar])),
            let selection = ModelSelection(string: String(raw[raw.index(after: bar)...]))
        else { return nil }
        return ModelPreset(selection: selection, effort: effort)
    }
}

/// Stepping through the pinned presets without opening anything: a swipe on the pill, a chord on a
/// desk. Wraps — unlike the effort wheel, where wrapping from max back to low is a mistake at
/// speed, a short list of favourites is a ring and the next of the last is the first.
public enum ModelPresetCycle {
    /// The pinned pairs this machine can run, each through the door it will actually take: a pair
    /// whose model is not in its catalog is a model on another machine, which a step cannot honour
    /// without starting a new chat.
    public static func reachable(
        _ presets: [ModelPreset], models: [ModelInfo], acceptsAnyModelID: Bool = false
    ) -> [ModelPreset] {
        presets.compactMap { resolve($0, models: models, acceptsAnyModelID: acceptsAnyModelID) }
    }

    /// One pin on one machine, or nil when that machine cannot run it.
    ///
    /// The door is part of the pin: the same model through OpenRouter and through its own key are
    /// two bills, so a pin matches on provider and id. Only when the catalog offers that id exactly
    /// once is the provider allowed to differ, and then the pin is taken through that one offer —
    /// never through a door the catalog does not list. A server that takes ids it never listed
    /// (the Claude CLI, omp) takes them only for its own house: a Claude bridge runs any Claude id
    /// and no other, and a pin for somebody else's model is a pin for another machine.
    public static func resolve(
        _ preset: ModelPreset, models: [ModelInfo], acceptsAnyModelID: Bool
    ) -> ModelPreset? {
        if models.contains(where: { $0.selection == preset.selection }) { return preset }
        if acceptsAnyModelID {
            return speaksForHouse(preset.selection, models: models) ? preset : nil
        }
        let offers = models.filter { $0.id == preset.selection.modelID }
        guard offers.count == 1, let only = offers.first else { return nil }
        return ModelPreset(selection: only.selection, effort: preset.effort)
    }

    public static func resolve(_ preset: ModelPreset, on source: ModelSource) -> ModelPreset? {
        resolve(preset, models: source.models, acceptsAnyModelID: source.acceptsAnyModelID)
    }

    /// Where every pin stands from the machine a surface is aimed at: the ones it can run, resolved
    /// to their doors, then the ones it cannot, each naming the machine that can — so a pin that
    /// lives elsewhere is said rather than silently missing from the list.
    public static func placement(
        _ presets: [ModelPreset], models: [ModelInfo], acceptsAnyModelID: Bool,
        elsewhere: [ModelSource]
    ) -> PinPlacement {
        var reachable: [ModelPreset] = []
        var away: [PinPlacement.Away] = []
        for preset in presets {
            if let here = resolve(preset, models: models, acceptsAnyModelID: acceptsAnyModelID) {
                reachable.append(here)
                continue
            }
            let home = elsewhere.first { !$0.isCurrent && resolve(preset, on: $0) != nil }
            away.append(
                PinPlacement.Away(
                    preset: preset, profileID: home?.profileID, serverName: home?.title))
        }
        return PinPlacement(reachable: reachable, away: away)
    }

    private static func house(_ providerID: String) -> String {
        let id = providerID.lowercased()
        return id == "claude" ? "anthropic" : id
    }

    /// Whether a pin belongs to the house a take-any-id server answers to: one of the providers its
    /// own catalog names (Anthropic for a Claude bridge that has not reported yet), and for
    /// Anthropic only an id the CLI would read as Claude's.
    static func speaksForHouse(_ selection: ModelSelection, models: [ModelInfo]) -> Bool {
        let houses = Set(models.map { house($0.providerID) })
        let provider = house(selection.providerID)
        guard (houses.isEmpty ? ["anthropic"] : houses).contains(provider) else { return false }
        return provider != "anthropic" || isClaudeID(selection.modelID)
    }

    private static let claudeAliases: Set<String> = [
        "fable", "opus", "sonnet", "haiku", "opusplan", "default", "best",
    ]

    static func isClaudeID(_ raw: String) -> Bool {
        let id = raw.lowercased()
        if id.hasPrefix("claude") || ModelNeedles.isClaude(raw) { return true }
        let base = id.split(separator: "[").first.map(String.init) ?? id
        return claudeAliases.contains(base)
    }

    public static func step(
        _ presets: [ModelPreset], model: ModelSelection?, effort: String?, by delta: Int
    ) -> ModelPreset? {
        guard !presets.isEmpty else { return nil }
        guard let here = presets.firstIndex(where: { $0.matches(model: model, effort: effort) })
        else { return delta >= 0 ? presets.first : presets.last }
        let count = presets.count
        return presets[((here + delta) % count + count) % count]
    }

    /// What a step says it did, for a toast: the model and the level the preset asks for.
    public static func said(_ preset: ModelPreset, modelName: String) -> String {
        switch preset.effort {
        case .keep: return modelName
        case .server: return Localized.text("%@ · server decides", modelName)
        case .level(let level):
            return modelName + " · " + (ModelDial.isPower(level) ? Ultracode.menuTitle.lowercased() : level)
        }
    }
}

/// The one cost of changing model in the middle of a conversation that a person cannot see: the
/// new model has never read this chat, so the first turn reads all of it again at the uncached
/// rate. It is said as a count of tokens, which is what the transcript knows — the catalog carries
/// no price, and a figure made up here would be a bill nobody can check.
public enum SwitchCost {
    /// Below this the re-read is cheaper than the sentence about it.
    public static let worthSaying = 10_000

    public static func line(contextTokens: Int?) -> String? {
        guard let contextTokens, contextTokens >= worthSaying else { return nil }
        return Localized.text(
            "Switching reads this chat again, uncached: about %@ tokens, once.",
            StatusFacts.tokens(contextTokens))
    }
}

/// What this chat's own turns at a level took, so the rail can answer "what will high cost me in
/// time" with the person's own evidence rather than a promise. Nothing is guessed: a level with no
/// settled turn in this conversation says nothing.
public enum EffortHistory {
    public static let sample = 5

    public static func seconds(
        level: String?, messages: [ChatMessage]
    ) -> (average: TimeInterval, turns: Int)? {
        guard let level else { return nil }
        let times = messages.reversed()
            .filter { $0.role == .assistant && !$0.isStreaming && $0.error == nil
                && $0.reasoningEffort == level }
            .compactMap(\.duration)
            .filter { $0 > 0 }
            .prefix(sample)
        guard !times.isEmpty else { return nil }
        return (times.reduce(0, +) / Double(times.count), times.count)
    }

    public static func line(level: String?, messages: [ChatMessage]) -> String? {
        guard let level, let found = seconds(level: level, messages: messages) else { return nil }
        let clock = ResponseStats.clock(found.average)
        return found.turns == 1
            ? Localized.text("your last turn at this level took %@", clock)
            : Localized.text("your last %d turns at this level averaged %@", found.turns, clock)
    }
}
