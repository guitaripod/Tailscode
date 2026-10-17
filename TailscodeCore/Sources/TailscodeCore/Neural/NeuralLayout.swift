import Foundation

/// Where a turn's steps sit in the head and how they are wired, built one step at a time.
///
/// A step takes the next free slot of its zone, in the order it happened; past a zone's capacity the
/// tail gathers in one counted ganglion at the zone's last slot. Wires run between consecutive
/// groups (the messages of the turn), through a via point where both sides hold several steps, as
/// 45-degree polylines with identical ones drawn once. Steps that name the same file or command are
/// tied. Nothing here is invented: every wire is sequence, a message's own parallel calls, or a
/// literal shared path or command.
///
/// `append` costs the same for every step. The transition between the last two groups is rebuilt
/// only when it is read, and sealed once a later group begins, so a long turn pays for each wire
/// once.
public struct NeuralLayout: Sendable, Equatable {
    /// One end of a wire: a step, or the via point of the transition into a group.
    public enum Endpoint: Sendable, Hashable {
        case step(String)
        case via(Int)
    }

    /// A connection between consecutive groups. `group` is the later of the two; `part` is 0 for the
    /// step-to-step or step-to-via half and 1 for the via-to-step half; `zone` is the zone the wire
    /// takes its colour from, the one it arrives in.
    public struct Edge: Sendable, Hashable {
        public let from: Endpoint
        public let to: Endpoint
        public let group: Int
        public let part: Int
        public let zone: NeuralZone
    }

    /// The meeting point of a transition between two groups that both hold several steps.
    public struct Via: Sendable, Hashable {
        public let group: Int
        public let point: NeuralPoint
        public let members: [String]
        public let zone: NeuralZone
    }

    /// An edge drawn as a polyline of two or three points: a diagonal, then straight.
    public struct Route: Sendable, Hashable {
        public let edge: Edge
        public let points: [NeuralPoint]

        public var isDegenerate: Bool {
            guard let first = points.first, let last = points.last else { return true }
            return abs(first.x - last.x) < 0.05 && abs(first.y - last.y) < 0.05
        }
    }

    /// The tail of a zone past its capacity, gathered in one node at the zone's last slot. `members`
    /// holds every step it stands for, the leader first.
    public struct Ganglion: Sendable, Hashable {
        public let zone: NeuralZone
        public let leader: String
        public let members: [String]
    }

    /// A dashed arc between two steps that share a tie, as the quadratic curve it is drawn with.
    public struct TieArc: Sendable, Hashable {
        public let from: NeuralPoint
        public let control: NeuralPoint
        public let to: NeuralPoint
    }

    /// Two or more steps on the same file, or running the same command.
    public struct Tie: Sendable, Hashable {
        public let key: String
        public let isCommand: Bool
        public let members: [String]
        public let arcs: [TieArc]
    }

    public private(set) var placements: [String: NeuralPoint] = [:]
    public private(set) var zoneCounts: [NeuralZone: Int]

    private var ids: [String] = []
    private var zones: [NeuralZone] = []
    private var groupOf: [Int] = []
    private var tieKeys: [String?] = []
    private var points: [NeuralPoint] = []
    private var indexByID: [String: Int] = [:]
    private var groupIndex: [Int] = []
    private var groupStarts: [Int] = []
    private var lastGroup: Int?
    private var overflow: [[Int]]
    private var tieBuilders: [TieBuilder] = []
    private var tieByKey: [String: Int] = [:]
    private var tieSlot: [Int?] = []
    private var sealedEdges: [Edge] = []
    private var sealedVias: [Via] = []
    private var sealedRoutes: [Route] = []
    private var sealedPaths: Set<RouteKey> = []

    private struct TieBuilder: Sendable, Hashable {
        var key: String
        var isCommand: Bool
        var members: [Int] = []
        var arcs: [TieArc] = []
    }

    private struct RouteKey: Sendable, Hashable {
        var values: [Int]

        init(_ points: [NeuralPoint]) {
            values = points.flatMap { [Int(($0.x * 10).rounded()), Int(($0.y * 10).rounded())] }
        }
    }

    public init() {
        zoneCounts = Dictionary(uniqueKeysWithValues: NeuralZone.allCases.map { ($0, 0) })
        overflow = Array(repeating: [], count: NeuralZone.allCases.count)
    }

    public static func make(steps: [NeuralStep]) -> NeuralLayout {
        var layout = NeuralLayout()
        layout.ids.reserveCapacity(steps.count)
        layout.points.reserveCapacity(steps.count)
        for step in steps { layout.append(step) }
        return layout
    }

    public var stepCount: Int { ids.count }

    public var groupCount: Int { groupStarts.count }

    /// Brings the layout to `steps`: appends what is new when the steps it holds are unchanged, and
    /// rebuilds from scratch when any of them changed what a layout reads (identity, zone, group
    /// or tie key). A streaming call's input can arrive after its part does, so a tie key can
    /// appear late.
    public mutating func sync(_ steps: [NeuralStep]) {
        var reusable = steps.count >= ids.count
        if reusable {
            for index in ids.indices {
                let step = steps[index]
                if step.id != ids[index] || step.zone != zones[index] || step.group != groupOf[index]
                    || step.tieKey != tieKeys[index]
                {
                    reusable = false
                    break
                }
            }
        }
        if !reusable { self = NeuralLayout() }
        for index in ids.count..<steps.count { append(steps[index]) }
    }

    public mutating func append(_ step: NeuralStep) {
        let index = ids.count
        if lastGroup != step.group {
            if groupStarts.count >= 2 { seal(group: groupStarts.count - 1) }
            groupStarts.append(index)
            lastGroup = step.group
        }
        let zone = step.zone
        let taken = zoneCounts[zone, default: 0]
        zoneCounts[zone] = taken + 1
        let capacity = zone.capacity
        let slot = capacity > 0 ? min(taken, capacity - 1) : 0
        let point = capacity > 0 ? zone.slots[slot] : zone.center
        if capacity == 0 || taken >= capacity - 1 { overflow[zone.rawValue].append(index) }

        ids.append(step.id)
        zones.append(zone)
        groupOf.append(step.group)
        tieKeys.append(step.tieKey)
        points.append(point)
        groupIndex.append(groupStarts.count - 1)
        indexByID[step.id] = index
        placements[step.id] = point
        addTie(step, index: index, point: point)
    }

    private mutating func addTie(_ step: NeuralStep, index: Int, point: NeuralPoint) {
        guard let key = step.tieKey else {
            tieSlot.append(nil)
            return
        }
        let slot: Int
        if let existing = tieByKey[key] {
            slot = existing
        } else {
            slot = tieBuilders.count
            tieByKey[key] = slot
            tieBuilders.append(TieBuilder(key: key, isCommand: step.tieIsCommand))
        }
        if let previous = tieBuilders[slot].members.last {
            tieBuilders[slot].arcs.append(Self.arc(from: points[previous], to: point))
        }
        tieBuilders[slot].members.append(index)
        tieSlot.append(slot)
    }

    private static func arc(from a: NeuralPoint, to b: NeuralPoint) -> TieArc {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let control = NeuralPoint((a.x + b.x) / 2 - dy * 0.28, (a.y + b.y) / 2 + dx * 0.28)
        return TieArc(from: a, control: control, to: b)
    }

    public var ganglia: [Ganglion] {
        NeuralZone.allCases.compactMap { zone in
            let members = overflow[zone.rawValue]
            guard members.count >= 2 else { return nil }
            return Ganglion(zone: zone, leader: ids[members[0]], members: members.map { ids[$0] })
        }
    }

    /// The step a node stands for: the leader of its ganglion for a member of one, itself otherwise.
    public func representative(of stepID: String) -> String {
        guard let index = indexByID[stepID] else { return stepID }
        return ids[representativeIndex(of: index)]
    }

    public var ties: [Tie] {
        tieBuilders.compactMap { builder in
            guard builder.members.count >= 2 else { return nil }
            return Tie(
                key: builder.key, isCommand: builder.isCommand,
                members: builder.members.map { ids[$0] }, arcs: builder.arcs)
        }
    }

    /// Every connection, in the order the turn made them.
    public var edges: [Edge] {
        guard groupStarts.count >= 2 else { return sealedEdges }
        return sealedEdges + transition(into: groupStarts.count - 1).edges
    }

    public var vias: [Via] {
        guard groupStarts.count >= 2, let via = transition(into: groupStarts.count - 1).via else {
            return sealedVias
        }
        return sealedVias + [via]
    }

    /// The wires to draw: one polyline per distinct path, the first edge to take it keeping it.
    public var routes: [Route] {
        guard groupStarts.count >= 2 else { return sealedRoutes }
        let open = transition(into: groupStarts.count - 1)
        var seen = Set<RouteKey>()
        var out = sealedRoutes
        for edge in open.edges {
            let polyline = polyline(for: edge, via: open.via)
            let key = RouteKey(polyline)
            if sealedPaths.contains(key) || !seen.insert(key).inserted { continue }
            out.append(Route(edge: edge, points: polyline))
        }
        return out
    }

    /// The steps whose wires light when `stepID` is hovered: the step, its ganglion's members, the
    /// steps its wires reach (through a via, everything either side of it) and every step tied to it.
    public func hotSet(for stepID: String) -> [String] {
        guard let index = indexByID[stepID] else { return [] }
        var hot = Set<Int>()
        for member in classIndices(of: index) {
            hot.insert(member)
            let group = groupIndex[member]
            if group > 0 { collectNeighbours(of: member, in: group, into: &hot) }
            if group + 1 < groupStarts.count {
                collectNeighbours(of: member, in: group + 1, into: &hot)
            }
            if let slot = tieSlot[member], tieBuilders[slot].members.count >= 2 {
                hot.formUnion(tieBuilders[slot].members)
            }
        }
        return hot.sorted().map { ids[$0] }
    }

    /// The wires that light with `stepID`: those that touch it or its ganglion, and both halves of
    /// a via it feeds or leaves.
    public func hotRoutes(for stepID: String) -> [Route] {
        guard let index = indexByID[stepID] else { return [] }
        let members = Set(classIndices(of: index))
        let memberIDs = Set(members.map { ids[$0] })
        let groups = Set(members.map { groupIndex[$0] })
        return routes.filter { route in
            [route.edge.from, route.edge.to].contains { end in
                switch end {
                case .step(let id): return memberIDs.contains(id)
                case .via(let group): return groups.contains(group - 1) || groups.contains(group)
                }
            }
        }
    }

    private func representativeIndex(of index: Int) -> Int {
        let list = overflow[zones[index].rawValue]
        if list.count >= 2, let first = list.first, index >= first, list.contains(index) {
            return first
        }
        return index
    }

    private func classIndices(of index: Int) -> [Int] {
        let list = overflow[zones[index].rawValue]
        if list.count >= 2, list.contains(index) { return list }
        return [index]
    }

    private func groupRange(_ group: Int) -> Range<Int> {
        let start = groupStarts[group]
        let end = group + 1 < groupStarts.count ? groupStarts[group + 1] : ids.count
        return start..<end
    }

    private func collectNeighbours(of member: Int, in group: Int, into hot: inout Set<Int>) {
        let previous = groupRange(group - 1)
        let next = groupRange(group)
        if previous.count > 1, next.count > 1 {
            hot.formUnion(previous)
            hot.formUnion(next)
        } else if next.contains(member) {
            hot.formUnion(previous)
        } else {
            hot.formUnion(next)
        }
    }

    private mutating func seal(group: Int) {
        let built = transition(into: group)
        sealedEdges.append(contentsOf: built.edges)
        if let via = built.via { sealedVias.append(via) }
        for edge in built.edges {
            let line = polyline(for: edge, via: built.via)
            if sealedPaths.insert(RouteKey(line)).inserted {
                sealedRoutes.append(Route(edge: edge, points: line))
            }
        }
    }

    /// The wires from group `group - 1` into `group`.
    private func transition(into group: Int) -> (edges: [Edge], via: Via?) {
        let previous = groupRange(group - 1)
        let next = groupRange(group)
        var edges: [Edge] = []
        if previous.count > 1, next.count > 1 {
            let all = Array(previous) + Array(next)
            let sum = all.reduce((x: 0.0, y: 0.0)) { ($0.x + points[$1].x, $0.y + points[$1].y) }
            let center = NeuralPoint(sum.x / Double(all.count), sum.y / Double(all.count))
            let via = Via(
                group: group, point: center, members: all.map { ids[$0] },
                zone: zones[all[all.count - 1]])
            edges.reserveCapacity(all.count)
            for p in previous {
                edges.append(
                    Edge(from: .step(ids[p]), to: .via(group), group: group, part: 0, zone: zones[p]))
            }
            for n in next {
                edges.append(
                    Edge(from: .via(group), to: .step(ids[n]), group: group, part: 1, zone: zones[n]))
            }
            return (edges, via)
        }
        edges.reserveCapacity(previous.count * next.count)
        for p in previous {
            for n in next {
                edges.append(
                    Edge(
                        from: .step(ids[p]), to: .step(ids[n]), group: group, part: 0,
                        zone: zones[n]))
            }
        }
        return (edges, nil)
    }

    private func point(of end: Endpoint, via: Via?) -> NeuralPoint {
        switch end {
        case .step(let id): return indexByID[id].map { points[$0] } ?? NeuralPoint(0, 0)
        case .via: return via?.point ?? NeuralPoint(0, 0)
        }
    }

    private func polyline(for edge: Edge, via: Via?) -> [NeuralPoint] {
        Self.route(from: point(of: edge.from, via: via), to: point(of: edge.to, via: via))
    }

    /// The PCB road between two points: straight when they share a row or column, otherwise a
    /// diagonal at 45 degrees followed by a straight run.
    static func route(from a: NeuralPoint, to b: NeuralPoint) -> [NeuralPoint] {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let ax = abs(dx)
        let ay = abs(dy)
        if ax < 1 || ay < 1 { return [a, b] }
        let sx: Double = dx < 0 ? -1 : 1
        let sy: Double = dy < 0 ? -1 : 1
        if ax >= ay { return [a, NeuralPoint(a.x + sx * ay, b.y), b] }
        return [a, NeuralPoint(b.x, a.y + sy * ax), b]
    }
}
