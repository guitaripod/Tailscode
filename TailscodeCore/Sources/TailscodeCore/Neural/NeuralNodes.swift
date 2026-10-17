import Foundation

/// Which colour a node wears. `zone` is the family's own, the colour of work that went well.
public enum NeuralNodeTone: Sendable, Hashable {
    case zone
    case live
    case attention
    case danger
    case quiet
}

/// One node, ready to draw: where it is, what shape and tone it wears, how it moves, and how lit
/// it is. A ganglion is one node, drawn at the leader's slot, and its members have none of their
/// own.
public struct NeuralNodeDraw: Sendable, Equatable, Identifiable {
    /// The step's id; the leader's for a ganglion.
    public let id: String
    /// One-based place in the turn.
    public let number: Int
    public let point: NeuralPoint
    /// The node's radius in design space: a ganglion is larger.
    public let radius: Double
    public let zone: NeuralZone
    public let shape: NeuralShape
    public let status: NeuralStatus
    public let tone: NeuralNodeTone
    /// Breath for a running node, heartbeat for one waiting on the person, still for the rest and
    /// for every node while motion is reduced or the turn is being replayed.
    public let motion: NeuralMotion
    /// How lit the node is, `0...1`: fully, for a turn at rest; during a replay nothing before the
    /// step fires and a fast ramp at it.
    public let lit: Float
    /// A glow just after the node fired, `1` falling to `0`; nil for a client that draws none.
    public let flash: Float
    /// An answer word is pointing at other steps and not this one.
    public let dimmed: Bool
    /// The selection lights it, or an answer word points at it.
    public let hot: Bool
    public let pinned: Bool
    /// How many steps a ganglion stands for; nil for every other node.
    public let ganglionCount: Int?
    public let isRecovered: Bool
    /// The glyph a waiting node wears in place of its number, a pause or a question mark.
    public let mark: Character?
    /// What the node says inside it: the mark where it has one, the number, or "+N" for a ganglion.
    public let label: String

    public var isGanglion: Bool { ganglionCount != nil }
}

/// One wire of the head, ready to draw.
public struct NeuralWireDraw: Sendable, Equatable, Identifiable {
    /// Its place among the layout's routes.
    public let id: Int
    public let points: [NeuralPoint]
    /// The zone the wire takes its colour from.
    public let zone: NeuralZone
    /// How far the pulse has travelled, `0...1`; `1` is a wire at rest, lit end to end, and a
    /// value between is a pulse on its way.
    public let lit: Float
    public let hot: Bool
    public let dimmed: Bool

    public var isPulsing: Bool { lit > 0 && lit < 1 }
}

/// The meeting point of two groups that both hold several steps.
public struct NeuralViaDraw: Sendable, Equatable {
    public let point: NeuralPoint
    public let zone: NeuralZone
    public let lit: Float
    public let hot: Bool
    public let dimmed: Bool
}

/// Steps that share a file or a command, as the dashed arcs between them.
public struct NeuralTieDraw: Sendable, Equatable {
    public let key: String
    /// The file's name or the command's first words: what a client may print beside the arcs.
    public let label: String
    public let isCommand: Bool
    public let arcs: [NeuralLayout.TieArc]
    public let lit: Float
    public let hot: Bool
    public let dimmed: Bool
}

public struct NeuralWires: Sendable, Equatable {
    public let routes: [NeuralWireDraw]
    public let vias: [NeuralViaDraw]
    public let ties: [NeuralTieDraw]
}

/// Turns a brain model into what a painter draws: nodes, wires, vias and ties, with the replay's
/// lighting, the selection's emphasis and the answer word's dimming already decided. A painter
/// decides only how a shape is stroked.
public enum NeuralNodes {
    /// Past this many nodes the Apple clients draw them as instanced shapes in one pass.
    public static let instancingThreshold = 60

    /// A ganglion is drawn this much larger than a step.
    public static let ganglionScale = 1.45

    /// How long a node takes to come up to full once it has fired, in replay seconds.
    public static let rampTime: TimeInterval = 0.12

    /// How long the glow after a node fires takes to fade.
    public static let flashTime: TimeInterval = 0.6

    /// How long a pulse takes to cross a wire.
    public static let wireTravel: TimeInterval = 0.35

    /// How long a tie takes to come up once its last step has fired.
    public static let tieRamp: TimeInterval = 0.3

    public static func useInstancedNodes(model: NeuralBrainModel) -> Bool {
        model.useInstancedNodes
    }

    /// How a step's status is worn: a running step is live, a step waiting on the person or stalled
    /// is attention, a failed one is danger, a stopped one is quiet and a finished one is the
    /// zone's own.
    public static func tone(of status: NeuralStatus) -> NeuralNodeTone {
        switch status {
        case .ok: return .zone
        case .running: return .live
        case .waitingApproval, .waitingAnswer, .stalled: return .attention
        case .failed: return .danger
        case .stopped: return .quiet
        }
    }

    /// Breath for work, a heartbeat for a step stopped to ask, still for everything else.
    public static func motion(of status: NeuralStatus) -> NeuralMotion {
        switch status {
        case .running: return .breath
        case .waitingApproval, .waitingAnswer: return .heartbeat
        case .ok, .failed, .stopped, .stalled: return .still
        }
    }

    /// The nodes to draw at `time`, a step each in turn order, a ganglion as one.
    public static func draws(
        model: NeuralBrainModel, time: Double, reduceMotion: Bool
    ) -> [NeuralNodeDraw] {
        let steps = model.turn.steps
        let replayTime = model.replayTime(now: time)
        let fire = replayTime == nil ? nil : model.replay?.fire
        var out: [NeuralNodeDraw] = []
        out.reserveCapacity(model.visibleNodeCount)
        for (index, step) in steps.enumerated() {
            let role = model.roles[index]
            if case .member = role { continue }
            let count: Int?
            if case .leader(let members) = role { count = members } else { count = nil }
            let gathered = count == nil ? nil : model.ganglionMembers[step.id]
            let status = gathered.map { aggregate($0, model: model, fallback: step.status) } ?? step.status
            let ramp = lighting(index: index, replayTime: replayTime, fire: fire, reduceMotion: reduceMotion)
            let carried = gathered ?? [step.id]
            let inProvenance = model.isProvenanceActive
                && carried.contains { model.provenanceSteps.contains($0) }
            let selected = model.hasSelection && model.hotSet.contains(step.id)
            let moves = model.mode == .live && !reduceMotion
            out.append(
                NeuralNodeDraw(
                    id: step.id, number: step.index + 1,
                    point: model.layout.placements[step.id] ?? step.zone.center,
                    radius: NeuralDesign.nodeRadius * (count == nil ? 1 : ganglionScale),
                    zone: step.zone, shape: step.zone.shape, status: status, tone: tone(of: status),
                    motion: moves ? motion(of: status) : .still, lit: ramp.lit, flash: ramp.flash,
                    dimmed: model.isProvenanceActive && !inProvenance, hot: selected || inProvenance,
                    pinned: model.pinned == step.id, ganglionCount: count,
                    isRecovered: carried.contains { id in
                        model.indexByID[id].map { steps[$0].recovered } ?? false
                    },
                    mark: step.mark,
                    label: count.map { "+\($0)" } ?? step.mark.map { String($0) }
                        ?? String(step.index + 1)))
        }
        return out
    }

    /// The wires, vias and ties to draw at `time`.
    public static func wires(model: NeuralBrainModel, time: Double) -> NeuralWires {
        wires(model: model, time: time, reduceMotion: false)
    }

    public static func wires(model: NeuralBrainModel, time: Double, reduceMotion: Bool) -> NeuralWires {
        let replayTime = model.replayTime(now: time)
        let fire = replayTime == nil ? nil : model.replay?.fire
        let vias = model.layout.vias
        var viaMembers: [Int: Set<String>] = [:]
        for via in vias { viaMembers[via.group] = Set(via.members) }

        func touchesProvenance(_ end: NeuralLayout.Endpoint) -> Bool {
            switch end {
            case .step(let id): return model.provenanceSteps.contains(id)
            case .via(let group):
                return !(viaMembers[group] ?? []).isDisjoint(with: model.provenanceSteps)
            }
        }

        var routes: [NeuralWireDraw] = []
        for (position, route) in model.layout.routes.enumerated() {
            let edge = route.edge
            let touches = model.isProvenanceActive
                && (touchesProvenance(edge.from) || touchesProvenance(edge.to))
            routes.append(
                NeuralWireDraw(
                    id: position, points: route.points, zone: edge.zone,
                    lit: wireLit(edge, model: model, replayTime: replayTime, fire: fire, reduceMotion: reduceMotion),
                    hot: model.hotEdges.contains(edge) || touches,
                    dimmed: model.isProvenanceActive && !touches))
        }

        let viaDraws = vias.map { via in
            let members = viaMembers[via.group] ?? []
            let touches = model.isProvenanceActive && !members.isDisjoint(with: model.provenanceSteps)
            let selected = model.hasSelection && !members.isDisjoint(with: model.selectionClass)
            return NeuralViaDraw(
                point: via.point, zone: via.zone,
                lit: viaLit(group: via.group, model: model, replayTime: replayTime, fire: fire),
                hot: selected || touches, dimmed: model.isProvenanceActive && !touches)
        }

        let tieDraws = model.layout.ties.map { tie in
            let selected = model.hasSelection
                && tie.members.contains { model.selectionClass.contains($0) }
            return NeuralTieDraw(
                key: tie.key, label: label(forTie: tie), isCommand: tie.isCommand, arcs: tie.arcs,
                lit: tieLit(tie, model: model, replayTime: replayTime, fire: fire, reduceMotion: reduceMotion),
                hot: selected, dimmed: model.isProvenanceActive)
        }
        return NeuralWires(routes: routes, vias: viaDraws, ties: tieDraws)
    }

    /// The text a client may set beside a tie's arcs: a file's own name, or a command's first
    /// words.
    public static func label(forTie tie: NeuralLayout.Tie) -> String {
        if tie.isCommand {
            let words = tie.key.split(separator: " ", omittingEmptySubsequences: true).prefix(3)
            let joined = words.joined(separator: " ")
            return joined.count > 28 ? String(joined.prefix(27)) + "\u{2026}" : joined
        }
        return tie.key.split(separator: "/").last.map(String.init) ?? tie.key
    }

    private static func aggregate(
        _ members: [String], model: NeuralBrainModel, fallback: NeuralStatus
    ) -> NeuralStatus {
        var rank = -1
        var chosen = fallback
        for id in members {
            guard let index = model.indexByID[id] else { continue }
            let step = model.turn.steps[index]
            let weight: Int
            switch step.status {
            case .waitingApproval, .waitingAnswer: weight = 5
            case .running: weight = 4
            case .stalled: weight = 3
            case .failed: weight = step.recovered ? 0 : 2
            case .stopped: weight = 1
            case .ok: weight = 0
            }
            if weight > rank {
                rank = weight
                chosen = step.status
            }
        }
        return chosen
    }

    private static func lighting(
        index: Int, replayTime: TimeInterval?, fire: [TimeInterval]?, reduceMotion: Bool
    ) -> (lit: Float, flash: Float) {
        guard let replayTime, let fire, index < fire.count else { return (1, 0) }
        let since = replayTime - fire[index]
        guard since >= 0 else { return (0, 0) }
        if reduceMotion { return (1, 0) }
        let lit = Float(min(1, since / rampTime))
        let flash = Float(max(0, min(1, 1 - since / flashTime)))
        return (lit, flash)
    }

    private static func wireLit(
        _ edge: NeuralLayout.Edge, model: NeuralBrainModel, replayTime: TimeInterval?,
        fire: [TimeInterval]?, reduceMotion: Bool
    ) -> Float {
        guard let replayTime, let fire else { return 1 }
        guard let group = groupFire(edge.group, model: model, fire: fire) else { return 1 }
        let arrival: TimeInterval
        let length: TimeInterval
        switch (edge.from, edge.to) {
        case (_, .via):
            arrival = group - 0.57 * wireTravel
            length = 0.8 * wireTravel
        case (.via, _):
            arrival = group
            length = 0.57 * wireTravel
        default:
            arrival = group
            length = wireTravel
        }
        if reduceMotion { return replayTime >= arrival ? 1 : 0 }
        return Float(min(1, max(0, (replayTime - (arrival - length)) / length)))
    }

    private static func viaLit(
        group: Int, model: NeuralBrainModel, replayTime: TimeInterval?, fire: [TimeInterval]?
    ) -> Float {
        guard let replayTime, let fire, let at = groupFire(group, model: model, fire: fire) else {
            return 1
        }
        return replayTime >= at - 0.57 * wireTravel ? 1 : 0
    }

    private static func tieLit(
        _ tie: NeuralLayout.Tie, model: NeuralBrainModel, replayTime: TimeInterval?,
        fire: [TimeInterval]?, reduceMotion: Bool
    ) -> Float {
        guard let replayTime, let fire else { return 1 }
        let last = tie.members.compactMap { model.indexByID[$0] }.compactMap { index in
            index < fire.count ? fire[index] : nil
        }.max()
        guard let last else { return 1 }
        let since = replayTime - last
        guard since >= 0 else { return 0 }
        return reduceMotion ? 1 : Float(min(1, since / tieRamp))
    }

    private static func groupFire(
        _ group: Int, model: NeuralBrainModel, fire: [TimeInterval]
    ) -> TimeInterval? {
        guard group >= 0, group < model.groupStarts.count else { return nil }
        let first = model.groupStarts[group]
        return first < fire.count ? fire[first] : nil
    }
}
