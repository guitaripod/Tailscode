import CodingAgentKit
import Foundation

/// One row of the dial's model column.
public struct ModelDialRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case serverDefault
        case candidate(ModelCandidate)
        case preset(ModelPreset, ModelCandidate)
        case allModels
        case noResults
    }

    /// The level a pinned pair carries, drawn on its row as the same meter the pill wears. Nil on a
    /// row that is a model alone.
    public struct Level: Sendable, Hashable {
        public let word: String
        public let heat: Int
        public let isPower: Bool
        public let isServer: Bool
        public let isEmber: Bool
    }

    public let kind: Kind
    /// The heading this row sits under, on the first row of its section only.
    public let section: String?
    public let title: String
    public let detail: String
    public let isStarred: Bool
    public let isCurrent: Bool
    public let wall: QuotaExhaustion?
    public let facts: [ModelFact]
    public let level: Level?

    public var id: String {
        switch kind {
        case .serverDefault: return "·server"
        case .candidate(let candidate): return candidate.id
        case .preset(let preset, let candidate): return "·preset·" + candidate.id + "·" + preset.effort.raw
        case .allModels: return "·all"
        case .noResults: return "·none"
        }
    }

    public var candidate: ModelCandidate? {
        switch kind {
        case .candidate(let candidate), .preset(_, let candidate): return candidate
        default: return nil
        }
    }

    public var preset: ModelPreset? {
        if case .preset(let preset, _) = kind { return preset }
        return nil
    }

    /// What picking this row hands the composer. Nil for the row that opens the catalog.
    public var pick: ModelPick? {
        switch kind {
        case .serverDefault:
            return ModelPick(profileID: "", selection: nil, isElsewhere: false, serverName: "")
        case .candidate(let candidate), .preset(_, let candidate):
            return ModelPick(
                profileID: candidate.profileID, selection: candidate.selection,
                isElsewhere: candidate.isElsewhere, serverName: candidate.serverName,
                modelName: candidate.name)
        case .allModels, .noResults:
            return nil
        }
    }

    public var opensCatalog: Bool { kind == .allModels }
    public var isMessage: Bool { kind == .noResults }
}

public enum ModelDialCommand: Sendable, Equatable {
    case up, down, top, bottom
    case hotter, colder
    case digit(Int)
    case activate
    case dismiss
    case pin
    case openAll
    case switchColumn
}

/// What a pick does to the level, so a client applies the pair the person saw rather than the
/// model alone. `unchanged` is the cursor on the model this chat already runs, where the level is
/// live and already applied; `set` is a pair — a preset, a model with its carried level, or a level
/// stepped on the ladder before the row was taken — and nil in it is the server deciding.
public enum EffortAsk: Sendable, Equatable {
    case unchanged
    case set(String?)
}

/// What a command did, for the client to draw. Effort changes on the model this chat runs are live
/// — the composer carries the new level the moment it is stepped — while a model is committed by
/// Enter or a click together with the level the ladder showed for it, so walking the list with the
/// arrows changes nothing until a row is taken.
public enum ModelDialOutcome: Sendable, Equatable {
    case unhandled
    case moved
    case effort(String?)
    case previewed(String?)
    case pick(ModelPick, effort: EffortAsk)
    case openCatalog
    case pinned(ModelPreset)
    case dismiss
}
