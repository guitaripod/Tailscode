import Foundation

/// The line that ties the node being read to the readout beside the head. It leaves the node, runs
/// on the same 45 degree roads as the wires, and ends on the node's own row at the readout's
/// hairline, where a 3 by 24 tab marks the landing; a node low in the head is not tied to the
/// header by a diagonal through every zone between. The way there is chosen among lanes up to 90
/// units above or below the node, the cheapest by length, node hits and zone-label hits, with an
/// octilinear search as the fallback for a crowded head. A line never passes within a node's radius
/// and 4 units of another node or through a zone's label box. All of it is in the head's design
/// space; the anchor lies to the right of the head, past x = 640, where the readout is.
public enum NeuralLeader {
    /// A leader ready to draw: the route in design space, and the landing in the row's points.
    public struct Line: Sendable, Equatable {
        /// The polyline from the node to the hairline, in the head's design space.
        public let route: [NeuralPoint]
        /// The 3 by 24 tab on the hairline, in the row's points.
        public let tab: NeuralRect
        /// The dot the line ends in, in the row's points: on the hairline, on the tab's centre.
        public let dot: NeuralPoint
        /// The row the line ends on, in the row's points.
        public let row: Double

        /// The leader and its tab sit on the canvas: the corrected palette, never the lifted tones.
        public var toneSet: NeuralToneSet { NeuralToneSet.set(for: .leader) }
        public var length: Double { NeuralLeader.length(route) }
    }

    /// How far a node's own circle is kept clear: its radius and 4 units.
    public static let clearance = NeuralDesign.nodeRadius + 4
    /// The stub's length: out of the node's own circle.
    public static let stub = NeuralDesign.nodeRadius + 4
    /// The horizontal run kept before the anchor, so the line enters the readout level.
    public static let runIn = 12.0
    /// How far above or below the node a lane may lie.
    public static let lanes: [Double] = [0, -16, 16, -32, 32, -48, 48, -64, 64, -90, 90]
    /// A label box is not entered; a node is not touched.
    public static let labelMargin = 0.0

    static let epsilon = 1e-6
    private static let hitWeight = 500.0
    private static let labelWeight = 1000.0
    private static let pointWeight = 5.0
    private static let laneWeight = 2.0

    /// The leader for the node at `design`, tied to the readout of `metrics`: nil in a stacked row,
    /// which has no leader. `nodes` are every node's centre in design space.
    public static func line(
        forNodeAt design: NeuralPoint, in metrics: NeuralStageMetrics, around nodes: [NeuralPoint],
        labels: [NeuralRect] = NeuralZone.labelRects
    ) -> Line? {
        guard let anchor = metrics.leaderAnchor(forNodeAt: design),
            let tab = metrics.leaderTab(forNodeAt: design)
        else { return nil }
        let road = route(from: design, to: anchor, around: nodes, labels: labels)
        let row = metrics.leaderRow(forNodeAt: design)
        return Line(
            route: road, tab: tab, dot: NeuralPoint(metrics.readout.x + 0.5, row), row: row)
    }

    /// The polyline from `node` to `anchor` around `nodes` (every node's centre; the one at
    /// `node` is ignored) and the zone `labels` (the node's own is ignored). The first point is
    /// `node` and the last is `anchor`, every segment is level, upright or at 45 degrees, and no
    /// other node is within `clearance` of it where the head's layout allows; when every road
    /// is crowded the cheapest lane is taken.
    public static func route(
        from node: NeuralPoint, to anchor: NeuralPoint, around nodes: [NeuralPoint],
        labels: [NeuralRect] = NeuralZone.labelRects, clearance: Double = NeuralLeader.clearance
    ) -> [NeuralPoint] {
        let others = nodes.filter { abs($0.x - node.x) > 0.5 || abs($0.y - node.y) > 0.5 }
        let boxes = labels.filter { distance(from: node, toRect: $0) > clearance + 2 }
        var best: (route: [NeuralPoint], cost: Double, hits: Int)?
        for candidate in laneRoutes(from: node, to: anchor) {
            let hits = hitCount(of: candidate.points, others: others, labels: boxes, clearance: clearance)
            let cost =
                length(candidate.points) + Double(hits.nodes) * hitWeight
                + Double(hits.labels) * labelWeight + Double(candidate.points.count) * pointWeight
                + abs(candidate.offset) * laneWeight
            if best == nil || cost < best!.cost {
                best = (candidate.points, cost, hits.nodes + hits.labels)
            }
        }
        if let best, best.hits == 0 { return best.route }
        if let searched = search(
            from: node, to: anchor, others: others, labels: boxes, clearance: clearance)
        {
            return searched
        }
        return best?.route ?? [node, anchor]
    }

    /// The length of the polyline.
    public static func length(_ points: [NeuralPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        return total
    }

    /// The point `fraction` of the way along the polyline, `0` at its start and `1` at its end:
    /// where the head of the line is while it draws itself.
    public static func point(at fraction: Double, along points: [NeuralPoint]) -> NeuralPoint {
        guard let first = points.first else { return NeuralPoint(0, 0) }
        guard points.count > 1 else { return first }
        let target = length(points) * min(max(fraction, 0), 1)
        var walked = 0.0
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let span = hypot(b.x - a.x, b.y - a.y)
            if walked + span >= target - epsilon, span > 0 {
                let amount = min(max((target - walked) / span, 0), 1)
                return NeuralPoint(a.x + (b.x - a.x) * amount, a.y + (b.y - a.y) * amount)
            }
            walked += span
        }
        return points[points.count - 1]
    }

    /// The part of the polyline drawn at `fraction`: the draw-along animation.
    public static func partial(_ fraction: Double, of points: [NeuralPoint]) -> [NeuralPoint] {
        guard points.count > 1 else { return points }
        let target = length(points) * min(max(fraction, 0), 1)
        var out = [points[0]]
        var walked = 0.0
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let span = hypot(b.x - a.x, b.y - a.y)
            if walked + span >= target - epsilon {
                let amount = span > 0 ? min(max((target - walked) / span, 0), 1) : 0
                out.append(NeuralPoint(a.x + (b.x - a.x) * amount, a.y + (b.y - a.y) * amount))
                return out
            }
            out.append(b)
            walked += span
        }
        return out
    }

    /// Whether every segment is level, upright or at 45 degrees.
    public static func isOnRoads(_ points: [NeuralPoint], tolerance: Double = 1e-6) -> Bool {
        guard points.count > 1 else { return true }
        for index in 1..<points.count {
            let dx = abs(points[index].x - points[index - 1].x)
            let dy = abs(points[index].y - points[index - 1].y)
            if dx > tolerance, dy > tolerance, abs(dx - dy) > tolerance { return false }
        }
        return true
    }

    /// The least distance from the polyline to any of `nodes`; infinite for none.
    public static func gap(of points: [NeuralPoint], others nodes: [NeuralPoint]) -> Double {
        guard points.count > 1 else { return .infinity }
        var least = Double.infinity
        for index in 1..<points.count {
            for node in nodes {
                least = min(least, distance(from: node, toSegment: points[index - 1], points[index]))
            }
        }
        return least
    }

    static func distance(
        from point: NeuralPoint, toSegment a: NeuralPoint, _ b: NeuralPoint
    ) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let along = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + dx * along), point.y - (a.y + dy * along))
    }

    /// Every road worth trying: a stub, a horizontal run on the node's row, a diagonal to a lane
    /// above or below, the lane, a diagonal back to the anchor's row, and a run into the anchor.
    private static func laneRoutes(
        from node: NeuralPoint, to anchor: NeuralPoint
    ) -> [(points: [NeuralPoint], offset: Double)] {
        var out: [(points: [NeuralPoint], offset: Double)] = []
        let entry = anchor.x - runIn > node.x + stub ? NeuralPoint(anchor.x - runIn, anchor.y) : anchor
        let first = node.x + stub
        for offset in lanes {
            let laneY = min(max(node.y + offset, 6), NeuralDesign.height - 6)
            let climb = abs(laneY - node.y)
            let fall = abs(entry.y - laneY)
            let latest = entry.x - climb - fall
            guard latest >= first - 0.5 else { continue }
            for leave in [first, (first + latest) / 2, latest] {
                for back in [leave + climb, entry.x - fall] {
                    guard back >= leave + climb - 0.5, back <= entry.x - fall + 0.5 else { continue }
                    var points = [node, NeuralPoint(first, node.y)]
                    if leave > first + 0.5 { points.append(NeuralPoint(leave, node.y)) }
                    if climb > 0.5 { points.append(NeuralPoint(leave + climb, laneY)) }
                    if back > points[points.count - 1].x + 0.5 || climb <= 0.5 {
                        points.append(NeuralPoint(back, laneY))
                    }
                    if fall > 0.5 { points.append(NeuralPoint(back + fall, entry.y)) }
                    points.append(entry)
                    if entry != anchor { points.append(anchor) }
                    out.append((simplified(points), offset))
                }
            }
        }
        return out
    }

    private static func hitCount(
        of points: [NeuralPoint], others: [NeuralPoint], labels: [NeuralRect], clearance: Double
    ) -> (nodes: Int, labels: Int) {
        var nodes = 0
        var boxes = 0
        guard points.count > 1 else { return (0, 0) }
        for index in 1..<points.count {
            for other in others
            where distance(from: other, toSegment: points[index - 1], points[index]) < clearance - epsilon {
                nodes += 1
            }
            for box in labels where segmentCrosses(points[index - 1], points[index], box) { boxes += 1 }
        }
        return (nodes, boxes)
    }

    /// Whether the segment passes through the inside of the rectangle.
    static func segmentCrosses(_ a: NeuralPoint, _ b: NeuralPoint, _ rect: NeuralRect) -> Bool {
        var low = 0.0
        var high = 1.0
        let dx = b.x - a.x
        let dy = b.y - a.y
        let edges: [(Double, Double)] = [
            (-dx, a.x - rect.x), (dx, rect.maxX - a.x), (-dy, a.y - rect.y), (dy, rect.maxY - a.y),
        ]
        for (direction, room) in edges {
            if abs(direction) < 1e-12 {
                if room <= 0 { return false }
            } else {
                let ratio = room / direction
                if direction < 0 { low = max(low, ratio) } else { high = min(high, ratio) }
            }
        }
        return high - low > 1e-9
    }

    /// The least distance from a point to a rectangle; zero inside it.
    static func distance(from point: NeuralPoint, toRect rect: NeuralRect) -> Double {
        let dx = max(rect.x - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.y - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// The points without repeats and without a point that lies on the line between its
    /// neighbours.
    static func simplified(_ points: [NeuralPoint]) -> [NeuralPoint] {
        var out: [NeuralPoint] = []
        for point in points {
            if let last = out.last, abs(last.x - point.x) < epsilon, abs(last.y - point.y) < epsilon {
                continue
            }
            while out.count >= 2, isStraight(out[out.count - 2], out[out.count - 1], point) {
                out.removeLast()
            }
            out.append(point)
        }
        return out
    }

    private static func isStraight(_ a: NeuralPoint, _ b: NeuralPoint, _ c: NeuralPoint) -> Bool {
        let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        let dot = (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y)
        return abs(cross) < epsilon && dot > 0
    }
}
