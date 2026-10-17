import Foundation

extension NeuralLeader {
    /// How a bend is priced in the search, in design units of walking: a leader would sooner be
    /// longer than turn.
    private static let bend45 = 6.0
    private static let bend90 = 20.0
    private static let bend135 = 60.0
    private static let leftward = 0.3

    private static let steps: [(dx: Int, dy: Int)] = [
        (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1),
    ]

    private static func bend(from a: Int, to b: Int) -> Double {
        let turn = min((a - b + 8) % 8, (b - a + 8) % 8)
        switch turn {
        case 0: return 0
        case 1: return bend45
        case 2: return bend90
        case 3: return bend135
        default: return .infinity
        }
    }

    /// A road found by searching a lattice laid on the node, moving the eight ways a wire may,
    /// for the crowded heads where no stub-and-diagonal clears: it can leave a node between its
    /// neighbours, run along a column and come back, and it is priced to turn as little as it can.
    /// The lattice is fitted so the anchor's row is on it and the road ends level with the
    /// anchor. Nil where nothing reaches the anchor.
    static func search(
        from node: NeuralPoint, to anchor: NeuralPoint, others: [NeuralPoint], clearance: Double
    ) -> [NeuralPoint]? {
        let rise = anchor.y - node.y
        let pitch = abs(rise) < 1 ? 4.0 : abs(rise) / max(1, (abs(rise) / 4).rounded())
        let goalColumn = Int(((anchor.x - runIn - node.x) / pitch).rounded(.down))
        guard goalColumn >= 1 else { return nil }
        let goalRow = Int((rise / pitch).rounded())
        let ys = others.map(\.y) + [node.y, anchor.y]
        let xs = others.map(\.x) + [node.x]
        let minColumn = Int(((xs.min() ?? node.x) - 60 - node.x) / pitch) - 1
        let minRow = Int(((ys.min() ?? node.y) - 60 - node.y) / pitch) - 1
        let maxRow = Int(((ys.max() ?? node.y) + 60 - node.y) / pitch) + 1
        let width = goalColumn - minColumn + 1
        let height = maxRow - minRow + 1
        guard width > 1, height > 1, width * height <= 400_000 else { return nil }
        let index = NodeIndex(others)

        func point(_ column: Int, _ row: Int) -> NeuralPoint {
            NeuralPoint(node.x + Double(column) * pitch, node.y + Double(row) * pitch)
        }
        func slot(_ column: Int, _ row: Int, _ direction: Int) -> Int {
            ((row - minRow) * width + (column - minColumn)) * 8 + direction
        }

        let capacity = width * height * 8
        var cost = [Double](repeating: .infinity, count: capacity)
        var parent = [Int32](repeating: -1, count: capacity)
        var heap = SearchHeap()
        let eastward = 0
        let startSlot = slot(0, 0, eastward)
        cost[startSlot] = 0
        func heuristic(_ column: Int, _ row: Int) -> Double {
            let dx = Double(abs(goalColumn - column))
            let dy = Double(abs(goalRow - row))
            return pitch * (max(dx, dy) + (2.0.squareRoot() - 1) * min(dx, dy))
        }
        heap.push(heuristic(0, 0), startSlot)
        var finish: (slot: Int, cost: Double)?
        while let (estimate, current) = heap.pop() {
            if let finish, estimate >= finish.cost { break }
            let direction = current % 8
            let cell = current / 8
            let column = cell % width + minColumn
            let row = cell / width + minRow
            let here = cost[current]
            if column == goalColumn, row == goalRow {
                let total = here + (current == startSlot ? 0 : bend(from: direction, to: eastward))
                if finish == nil || total < finish!.cost { finish = (current, total) }
                continue
            }
            for (next, move) in steps.enumerated() {
                let stepColumn = column + move.dx
                let stepRow = row + move.dy
                guard stepColumn >= minColumn, stepColumn <= goalColumn, stepRow >= minRow,
                    stepRow <= maxRow
                else { continue }
                let turn = current == startSlot ? 0 : bend(from: direction, to: next)
                guard turn.isFinite else { continue }
                let length = pitch * (move.dx != 0 && move.dy != 0 ? 2.0.squareRoot() : 1)
                let from = point(column, row)
                let to = point(stepColumn, stepRow)
                guard index.clears(from: from, to: to, clearance: clearance) else { continue }
                let total = here + length + turn + (move.dx < 0 ? leftward * length : 0)
                let target = slot(stepColumn, stepRow, next)
                if total < cost[target] {
                    cost[target] = total
                    parent[target] = Int32(current)
                    heap.push(total + heuristic(stepColumn, stepRow), target)
                }
            }
        }
        guard let finish else { return nil }
        var chain: [NeuralPoint] = []
        var cursor = finish.slot
        while cursor >= 0 {
            let cell = cursor / 8
            chain.append(point(cell % width + minColumn, cell / width + minRow))
            cursor = Int(parent[cursor])
        }
        chain.reverse()
        chain.append(anchor)
        return simplified(chain)
    }

    /// The nodes bucketed by place, so an edge of the search asks only the few nodes near it.
    private struct NodeIndex {
        private static let cell = 40.0
        private var buckets: [Int: [NeuralPoint]] = [:]

        init(_ nodes: [NeuralPoint]) {
            for node in nodes {
                buckets[Self.key(Int((node.x / Self.cell).rounded(.down)), Int((node.y / Self.cell).rounded(.down))), default: []].append(node)
            }
        }

        private static func key(_ x: Int, _ y: Int) -> Int { x &* 100_003 &+ y }

        func clears(from a: NeuralPoint, to b: NeuralPoint, clearance: Double) -> Bool {
            let cx = Int((a.x / Self.cell).rounded(.down))
            let cy = Int((a.y / Self.cell).rounded(.down))
            for x in (cx - 1)...(cx + 1) {
                for y in (cy - 1)...(cy + 1) {
                    for node in buckets[Self.key(x, y)] ?? []
                    where NeuralLeader.distance(from: node, toSegment: a, b) < clearance - epsilon {
                        return false
                    }
                }
            }
            return true
        }
    }

    /// A binary min-heap of (priority, state).
    private struct SearchHeap {
        private var items: [(Double, Int)] = []

        mutating func push(_ priority: Double, _ value: Int) {
            items.append((priority, value))
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].0 < items[parent].0 else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> (Double, Int)? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var parent = 0
                while true {
                    let left = parent * 2 + 1
                    let right = left + 1
                    var smallest = parent
                    if left < items.count, items[left].0 < items[smallest].0 { smallest = left }
                    if right < items.count, items[right].0 < items[smallest].0 { smallest = right }
                    if smallest == parent { break }
                    items.swapAt(parent, smallest)
                    parent = smallest
                }
            }
            return top
        }
    }
}
