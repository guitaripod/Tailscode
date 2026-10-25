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

    /// The grid once the first tile takes two columns: one cell more than the count, in the
    /// shape that keeps the cells closest to square.
    static func spanned(count: Int, shape: Shape) -> (columns: Int, rows: Int) {
        if shape == .portrait {
            switch count {
            case 4, 5: return (2, 3)
            default: return (2, 4)
            }
        }
        switch count {
        case 2: return (3, 1)
        case 3: return (2, 2)
        case 4, 5: return (3, 2)
        default: return (4, 2)
        }
    }

    static func place(_ tiles: [WallTile], aspect: Double) -> (tiles: [WallTile], columns: Int, rows: Int) {
        guard !tiles.isEmpty else { return ([], 0, 0) }
        let shape = Shape(aspect: aspect)
        let flat = base(count: tiles.count, shape: shape)
        let wide = tiles.count >= 2 && flat.columns >= 2 && tiles[0].state.isNeedsYou
        let grid = wide ? spanned(count: tiles.count, shape: shape) : flat
        var spans = [Int](repeating: 1, count: tiles.count)
        if wide { spans[0] = 2 }
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
        }
        return (placed, grid.columns, row + 1)
    }
}
