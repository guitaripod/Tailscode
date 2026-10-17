import Foundation

/// The line that ties the node being read to the readout beside the head, routed on the same 45
/// degree roads as the wires: a short stub, a diagonal, then horizontal into the readout's anchor.
/// It goes up or down around the cluster, whichever way leaves fewer nodes near the path, and
/// never passes within a node's radius and 4 units of another node. All of it is in the head's
/// design space; the anchor may lie to the right of the head, past x = 640, where the readout is.
public enum NeuralLeader {
    /// How far a node's own circle is kept clear: its radius and 4 units.
    public static let clearance = NeuralDesign.nodeRadius + 4
    /// The stub's shortest length: out of the node's own circle.
    public static let stub = NeuralDesign.nodeRadius + 4
    /// The horizontal run kept before the anchor, so the line enters the readout level.
    public static let runIn = 12.0

    private static let stubs: [Double] = [stub, 22, 30, 40, 52, 66]
    static let epsilon = 1e-6

    /// The polyline from `node` to `anchor` around `nodes` (every node's centre; the one at
    /// `node` is ignored). The first point is `node` and the last is `anchor`, every segment is
    /// level, upright or at 45 degrees, and no other node is within `clearance` of it where the
    /// head's layout allows: when every road is crowded the one that clears most is taken.
    public static func route(
        from node: NeuralPoint, to anchor: NeuralPoint, around nodes: [NeuralPoint],
        clearance: Double = NeuralLeader.clearance
    ) -> [NeuralPoint] {
        let others = nodes.filter { abs($0.x - node.x) > 0.5 || abs($0.y - node.y) > 0.5 }
        var best: (route: [NeuralPoint], near: Int, length: Double)?
        var crowded: (route: [NeuralPoint], gap: Double)?
        for candidate in candidates(from: node, to: anchor, others: others, clearance: clearance) {
            let room = gap(of: candidate, others: others)
            if room >= clearance - epsilon {
                let near = nearCount(of: candidate, others: others, within: clearance * 2)
                let run = length(candidate)
                if best == nil || near < best!.near || (near == best!.near && run < best!.length - epsilon) {
                    best = (candidate, near, run)
                }
            } else if crowded == nil || room > crowded!.gap {
                crowded = (candidate, room)
            }
        }
        if let best { return best.route }
        if let searched = search(from: node, to: anchor, others: others, clearance: clearance) {
            return searched
        }
        return crowded?.route ?? [node, anchor]
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

    private static func nearCount(
        of points: [NeuralPoint], others nodes: [NeuralPoint], within reach: Double
    ) -> Int {
        nodes.filter { node in
            (1..<max(points.count, 1)).contains { index in
                distance(from: node, toSegment: points[index - 1], points[index]) < reach
            }
        }.count
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

    /// Every road worth trying: a stub of a few lengths, a diagonal up or down, and either a
    /// straight run at the anchor's level or one along a lane beyond the cluster with a second
    /// diagonal back to the anchor.
    private static func candidates(
        from node: NeuralPoint, to anchor: NeuralPoint, others: [NeuralPoint], clearance: Double
    ) -> [[NeuralPoint]] {
        var out: [[NeuralPoint]] = []
        let ys = others.map(\.y) + [node.y]
        for side in [-1.0, 1.0] {
            let beyond = side < 0 ? (ys.min() ?? node.y) - clearance - 8 : (ys.max() ?? node.y) + clearance + 8
            for length in stubs {
                let first = NeuralPoint(node.x + length, node.y)
                if let direct = direct(node: node, first: first, anchor: anchor, side: side) {
                    out.append(direct)
                }
                for extra in [0.0, 16, 32] {
                    if let road = lane(
                        node: node, first: first, anchor: anchor, side: side,
                        laneY: beyond + side * extra)
                    {
                        out.append(road)
                    }
                }
            }
        }
        if abs(anchor.y - node.y) < epsilon { out.append(simplified([node, anchor])) }
        return out
    }

    private static func direct(
        node: NeuralPoint, first: NeuralPoint, anchor: NeuralPoint, side: Double
    ) -> [NeuralPoint]? {
        let rise = anchor.y - first.y
        guard rise * side > epsilon else {
            return abs(rise) < epsilon && first.x <= anchor.x ? simplified([node, first, anchor]) : nil
        }
        let corner = NeuralPoint(first.x + abs(rise), anchor.y)
        guard corner.x <= anchor.x - epsilon else { return nil }
        return simplified([node, first, corner, anchor])
    }

    private static func lane(
        node: NeuralPoint, first: NeuralPoint, anchor: NeuralPoint, side: Double, laneY: Double
    ) -> [NeuralPoint]? {
        let climb = laneY - first.y
        guard climb * side > epsilon else { return nil }
        let leave = NeuralPoint(first.x + abs(climb), laneY)
        let fall = anchor.y - laneY
        let enter = NeuralPoint(anchor.x - runIn, anchor.y)
        let turn = NeuralPoint(enter.x - abs(fall), laneY)
        guard turn.x >= leave.x - epsilon else { return nil }
        return simplified([node, first, leave, turn, enter, anchor])
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
