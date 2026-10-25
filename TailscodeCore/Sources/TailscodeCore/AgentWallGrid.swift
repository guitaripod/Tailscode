import Foundation

/// Where the wall's tiles go: a grid chosen from the count and the screen's shape, filled
/// row-major with no empty cell, so the wall is one clean packing at any count.
enum WallGrid {
    enum Shape {
        case landscape
        case portrait
        case squarish

        init(aspect: Double) {
            if aspect >= 1.2 {
                self = .landscape
            } else if aspect <= 0.9 {
                self = .portrait
            } else {
                self = .squarish
            }
        }
    }

    static func base(count: Int, shape: Shape) -> (columns: Int, rows: Int) {
        switch count {
        case ...0: return (0, 0)
        case 1: return (1, 1)
        case 2: return shape == .landscape ? (2, 1) : (1, 2)
        case 3:
            switch shape {
            case .landscape: return (3, 1)
            case .portrait: return (1, 3)
            case .squarish: return (2, 2)
            }
        case 4: return (2, 2)
        default: return shape == .portrait ? (2, 3) : (3, 2)
        }
    }

    /// `aspect` is the screen's shape and picks the grid; `areaAspect` is the shape of the area the
    /// grid fills, which is what each cell's own shape is measured from.
    static func place(
        _ tiles: [WallTile], aspect: Double, areaAspect: Double? = nil
    ) -> (tiles: [WallTile], columns: Int, rows: Int) {
        guard !tiles.isEmpty else { return ([], 0, 0) }
        let shape = Shape(aspect: aspect)
        let flat = base(count: tiles.count, shape: shape)
        let grid = flat
        var spans = [Int](repeating: 1, count: tiles.count)
        var cells: [(column: Int, row: Int)] = []
        var column = 0
        var row = 0
        for span in spans {
            if column + span > grid.columns {
                column = 0
                row += 1
            }
            cells.append((column, row))
            column += span
        }
        let last = cells.indices.filter { cells[$0].row == row }
        var spare = grid.columns - column
        var turn = 0
        while spare > 0 {
            spans[last[turn % last.count]] += 1
            spare -= 1
            turn += 1
        }
        var offset = 0
        for index in last {
            cells[index].column = offset
            offset += spans[index]
        }
        var placed = tiles
        for index in placed.indices {
            placed[index].span = spans[index]
            placed[index].column = cells[index].column
            placed[index].row = cells[index].row
            placed[index].squad = WallSquad.plan(
                workers: placed[index].workers, sessions: tiles.count,
                cellAspect: (areaAspect ?? aspect) * Double(spans[index] * (row + 1)) / Double(grid.columns))
        }
        return (placed, grid.columns, row + 1)
    }
}
