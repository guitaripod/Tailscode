import CodingAgentKit
import Foundation

public enum ModelMatch: Int, Sendable, Comparable {
    case exact = 0
    case prefix = 1
    case word = 2
    case inner = 3
    case scattered = 4
    /// The name says nothing; the provider, the family or the raw id is what matched.
    case elsewhere = 5

    public static func < (lhs: ModelMatch, rhs: ModelMatch) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ModelChooserRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Let the server decide — the row that has no model in it.
        case auto
        case candidate(ModelCandidate)
        /// One of a collapsed candidate's other doors, revealed under it.
        case alternate(ModelCandidate, ModelOffer)
        /// A model id typed rather than found: a server whose CLI takes any name will take this one.
        case literal(ModelSelection)
    }

    public let kind: Kind
    /// The server that would run this row.
    public let profileID: String
    public let serverName: String
    /// True when that server is not the one the chooser was opened from.
    public let isElsewhere: Bool
    /// Which section drew this row. A model you reached for recently is listed twice — once under
    /// Recent and once in its own family — so the section is part of a row's identity; a list keyed
    /// by identity has to be able to tell the two apart.
    public let sectionID: String
    public let title: String
    public let detail: String
    /// Offsets into `title` the query landed on, for the client to weight.
    public let highlight: [Int]
    public let facts: [ModelFact]
    public let isSelected: Bool
    /// True while this candidate's other providers are showing under it.
    public let isExpanded: Bool
    public let canExpand: Bool
    /// An alternate is drawn inset under the row it belongs to.
    public let isNested: Bool
    /// The used-up window standing between this row and a send, when one is. A walled row is drawn
    /// spent — dimmed, wearing what ran out and when it comes back — and stays pickable, because a
    /// window resets and a wall is not a reason to refuse someone the model they came for.
    public let wall: QuotaExhaustion?

    /// Unique across the whole list, which is what a diffable list demands of an identifier.
    public var id: String { "\(sectionID)/\(anchor)" }

    /// What this row is about, the same wherever it is listed — two rows sharing an anchor are one
    /// model in two places, and expanding either opens both.
    public var anchor: String {
        if let pair, case .candidate(let candidate) = kind {
            return "·pair/\(candidate.id)/\(pair.id)"
        }
        switch kind {
        case .auto: return "·default/\(profileID)"
        case .candidate(let candidate): return candidate.id
        case .alternate(let candidate, let offer): return "\(candidate.id)|\(offer.selection.rawValue)"
        case .literal(let selection): return "·literal/\(profileID)/\(selection.rawValue)"
        }
    }

    /// What picking this row means. `nil` is the server's own choice, which is a real answer.
    public var selection: ModelSelection? {
        switch kind {
        case .auto: return nil
        case .candidate(let candidate): return candidate.selection
        case .alternate(_, let offer): return offer.selection
        case .literal(let selection): return selection
        }
    }

    /// The whole answer: the model, and the machine that would run it.
    public var pick: ModelPick {
        ModelPick(
            profileID: profileID, selection: selection, isElsewhere: isElsewhere,
            serverName: serverName, modelName: title, preset: pair)
    }

    /// Whether you pinned this model, wherever it is listed — a star follows the model
    /// through every section it appears in, and a pair at any level lights it as well.
    public var isPinned: Bool = false

    /// The level a pick of this row would run at, when the chooser was told the aim. Nil without
    /// an aim, and on a model that takes no level.
    public var reading: ModelRowLevel? = nil

    /// The model's name and family hue, for a row drawn as the pill draws it. Nil on the auto row.
    public var chip: ModelChip? = nil

    /// Where the row stands among the pins, and the pin its star toggles.
    public var pinning: RowPinning = .none

    /// The one word for where this model runs: *local* on the machine's own hardware, *on* a
    /// machine that is not the one the chooser opened from, nothing otherwise.
    public var place: String? = nil

    /// The pinned pair a row of the Pinned section stands for, resolved to this machine's door.
    var pair: ModelPreset? = nil

    public var isAuto: Bool {
        if case .auto = kind { return true }
        return false
    }

    public var isLiteral: Bool {
        if case .literal = kind { return true }
        return false
    }
}

/// A heading and what it holds — which, past a certain size, is a thing you open rather than a
/// thing you scroll. A hundred models is twenty screens of names nobody reads on the way to the one
/// they came for; the same hundred under headings that answer to a press is one screen you look at
/// and then aim into.
public struct ModelChooserSection: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let rows: [ModelChooserRow]
    /// Whether this heading is a control. Current, Recent and the typed-id offer are never closed:
    /// they are short by construction and they are what the list is for.
    public let canCollapse: Bool
    /// True when the rows are held back. `rows` is then empty, so nothing downstream has to know.
    public let isCollapsed: Bool
    /// How many models are under the heading whether or not they are showing.
    public let count: Int

    public init(
        id: String, title: String, detail: String, rows: [ModelChooserRow],
        canCollapse: Bool = false, isCollapsed: Bool = false, count: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.rows = rows
        self.canCollapse = canCollapse
        self.isCollapsed = isCollapsed
        self.count = count ?? rows.count
    }
}

public enum ModelChooserCommand: Sendable, Equatable {
    case up
    case down
    case top
    case bottom
    case activate
    case expand
    case collapse
    /// The nth machine's tab, counted from zero — ⌃1 is the server the chooser opened from.
    case machine(Int)
    /// The nth door, counted from zero; `nil` is every door — ⌥0.
    case door(Int?)
    /// Open every heading, or shut every one that answers to a press.
    case expandAll
    case collapseAll
    case dismiss
}
