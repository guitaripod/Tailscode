import Foundation
import TailscodeCore

struct WatchRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

/// Where everything on the wall goes, from the window's size and the wall alone. Every size is a
/// multiple of one unit, a hundredth of the shorter side, so a 4K monitor and a 1080p one read the
/// same from across a room. The tiles' places are Core's columns, rows and spans, scaled to the
/// grid area; nothing here decides which tile goes where.
struct WatchGeometry: Equatable {
    static let minimumText = 1.6
    static let gutter = 1.2

    let width: Double
    let height: Double
    let unit: Double
    let isPortrait: Bool
    let headline: WatchRect
    let watchLine: WatchRect
    let clock: WatchRect
    let date: WatchRect
    let grid: WatchRect
    let tiles: [WatchRect]
    let ribbon: WatchRect
    let recentRail: WatchRect
    let listedRail: WatchRect
    let centre: WatchRect

    /// The class of screen Core lays the grid out for: wide, tall or nearly square.
    static func shape(aspect: Double) -> Int {
        aspect >= 1.2 ? 0 : (aspect <= 0.9 ? 1 : 2)
    }

    static func unit(width: Double, height: Double) -> Double { max(1, min(width, height) / 100) }

    static func make(
        width: Double, height: Double, tiles: [WallTile], columns: Int, rows: Int, isCalm: Bool,
        drift: (x: Double, y: Double) = (0, 0)
    ) -> WatchGeometry {
        let unit = unit(width: width, height: height)
        let portrait = height > width
        let margin = 3.0 * unit
        let clockWidth = (portrait ? 27.0 : 30.0) * unit
        let topY = 2.4 * unit + drift.y
        let bandHeight = (portrait ? 19.0 : 14.0) * unit
        let headlineWidth = max(10 * unit, width - 2 * margin - clockWidth - 2 * unit)
        let headline = WatchRect(x: margin + drift.x, y: topY, width: headlineWidth, height: bandHeight - 4.2 * unit)
        let watchLine = WatchRect(
            x: margin + drift.x, y: headline.maxY + 0.2 * unit, width: headlineWidth, height: 3.0 * unit)
        let clockX = width - margin - clockWidth + drift.x
        let clock = WatchRect(x: clockX, y: topY, width: clockWidth, height: 8.4 * unit)
        let date = WatchRect(x: clockX, y: clock.maxY + 0.2 * unit, width: clockWidth, height: 3.0 * unit)

        let ribbonHeight = (isCalm && tiles.isEmpty ? 14.0 : 8.8) * unit
        let railHeight = 4.4 * unit
        let bottom = height - 1.8 * unit + drift.y
        let rail = WatchRect(x: margin + drift.x, y: bottom - railHeight, width: width - 2 * margin, height: railHeight)
        let ribbon = WatchRect(
            x: margin + drift.x, y: rail.y - 0.8 * unit - ribbonHeight, width: width - 2 * margin,
            height: ribbonHeight)
        let leftWidth = rail.width * 0.56
        let recent = WatchRect(x: rail.x, y: rail.y, width: leftWidth - unit, height: rail.height)
        let listed = WatchRect(x: rail.x + leftWidth, y: rail.y, width: rail.width - leftWidth, height: rail.height)

        let gridTop = max(watchLine.maxY, date.maxY) + 1.6 * unit
        let gridBottom = ribbon.y - 1.4 * unit
        let grid = WatchRect(
            x: margin, y: gridTop, width: width - 2 * margin, height: max(0, gridBottom - gridTop))
        let gutter = Self.gutter * unit
        let cols = max(1, columns)
        let rowCount = max(1, rows)
        let cellWidth = (grid.width - gutter * Double(cols - 1)) / Double(cols)
        let cellHeight = (grid.height - gutter * Double(rowCount - 1)) / Double(rowCount)
        let placed = tiles.map { tile -> WatchRect in
            let span = Double(tile.span)
            return WatchRect(
                x: grid.x + Double(tile.column) * (cellWidth + gutter),
                y: grid.y + Double(tile.row) * (cellHeight + gutter),
                width: span * cellWidth + (span - 1) * gutter, height: cellHeight)
        }
        let side = min(grid.width, grid.height) * 0.62
        let centre = WatchRect(
            x: grid.x + (grid.width - side) / 2, y: grid.y + (grid.height - side) / 2, width: side,
            height: side)
        return WatchGeometry(
            width: width, height: height, unit: unit, isPortrait: portrait, headline: headline,
            watchLine: watchLine, clock: clock, date: date, grid: grid, tiles: placed,
            ribbon: ribbon, recentRail: recent, listedRail: listed, centre: centre)
    }
}

extension AgentWall {
    /// Whether two readings put the same thing on the wall: everything but the moment read.
    func sameShown(as other: AgentWall) -> Bool {
        mood == other.mood && headline == other.headline && watchLine == other.watchLine
            && tiles == other.tiles && columns == other.columns && rows == other.rows
            && listed == other.listed && listedOverflow == other.listedOverflow
            && recent == other.recent && calm == other.calm
    }

    var hasFailure: Bool {
        tiles.contains { if case .finished(.failed) = $0.state { return true } else { return false } }
    }

    var hasOverdue: Bool {
        tiles.contains { if case .needsYou(.overdue) = $0.state { return true } else { return false } }
    }

    var needsYouIndex: Int? { tiles.firstIndex { $0.state.isNeedsYou } }
}
