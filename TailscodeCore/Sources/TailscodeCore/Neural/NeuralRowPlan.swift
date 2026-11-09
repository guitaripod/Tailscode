import Foundation

/// Where a conversation's brains go among its rows, decided once for every client. A row builder
/// walks the parts of its messages; at a part id found in `anchors` it emits that turn's brain row,
/// and for a part id in `skip` it builds no row of its own, because the brain consumes it.
public struct NeuralRowPlan: Sendable, Equatable {
    /// The part id (`"messageID:partID"`) a turn's brain row goes before, to the turn's id: the
    /// turn's own `anchor`, its first member part, else its first step the chat does not already
    /// show, so a turn's opening words stand above its brain.
    public let anchors: [String: NeuralTurn.ID]
    /// Every part the brains consume. A client builds no row for these.
    public let skip: Set<String>
    /// Each consumed part, to the turn that consumed it.
    public let turnForPart: [String: NeuralTurn.ID]
    /// The turns that are brains, by id.
    public let turns: [NeuralTurn.ID: NeuralTurn]
    /// Their ids, oldest first.
    public let order: [NeuralTurn.ID]

    public static let empty = NeuralRowPlan(
        anchors: [:], skip: [], turnForPart: [:], turns: [:], order: [])

    public init(
        anchors: [String: NeuralTurn.ID], skip: Set<String>, turnForPart: [String: NeuralTurn.ID],
        turns: [NeuralTurn.ID: NeuralTurn], order: [NeuralTurn.ID]
    ) {
        self.anchors = anchors
        self.skip = skip
        self.turnForPart = turnForPart
        self.turns = turns
        self.order = order
    }

    /// The plan for `turns`. A turn with no steps is not a brain and contributes nothing, and the
    /// Lines style yields the empty plan, so a client's builder needs no second code path.
    public init(turns all: [NeuralTurn], style: ActivityStyle = .brain) {
        guard Self.isEnabled(style: style) else {
            self = .empty
            return
        }
        var anchors: [String: NeuralTurn.ID] = [:]
        var skip = Set<String>()
        var owner: [String: NeuralTurn.ID] = [:]
        var turns: [NeuralTurn.ID: NeuralTurn] = [:]
        var order: [NeuralTurn.ID] = []
        for turn in all where NeuralOpenPolicy.isBrain(turn: turn) {
            guard turns[turn.id] == nil else { continue }
            turns[turn.id] = turn
            order.append(turn.id)
            for id in turn.memberPartIDs {
                skip.insert(id)
                owner[id] = turn.id
            }
            if let anchor = turn.anchor { anchors[anchor] = turn.id }
        }
        self.init(anchors: anchors, skip: skip, turnForPart: owner, turns: turns, order: order)
    }

    /// Whether the brain is drawn at all in this style.
    public static func isEnabled(style: ActivityStyle) -> Bool { style == .brain }

    /// The turn whose brain goes before the part `partID`, nil for every other part.
    public func turnID(anchoredAt partID: String) -> NeuralTurn.ID? { anchors[partID] }

    public func turn(anchoredAt partID: String) -> NeuralTurn? {
        anchors[partID].flatMap { turns[$0] }
    }

    /// Whether a client builds no row of its own for `partID`.
    public func skips(_ partID: String) -> Bool { skip.contains(partID) }

    public var isEmpty: Bool { order.isEmpty }
}
