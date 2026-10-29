import Foundation

/// A rectangle in points, origin at the top leading corner.
public struct WallRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public static let zero = WallRect(x: 0, y: 0, width: 0, height: 0)

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The part of this rectangle a frame in its own units, `0...1` across and down, covers.
    public func inside(_ frame: WallFrame) -> WallRect {
        WallRect(
            x: x + frame.x * width, y: y + frame.y * height, width: frame.width * width,
            height: frame.height * height)
    }

    /// Smaller by `amount` on every side; a negative amount grows it.
    public func inset(_ amount: Double) -> WallRect {
        WallRect(x: x + amount, y: y + amount, width: width - 2 * amount, height: height - 2 * amount)
    }

    public func inset(_ insets: WallInsets) -> WallRect {
        WallRect(
            x: x + insets.leading, y: y + insets.top,
            width: width - insets.leading - insets.trailing,
            height: height - insets.top - insets.bottom)
    }

    /// Whether the two share any area; touching edges do not count.
    public func intersects(_ other: WallRect) -> Bool {
        x < other.maxX - 1e-6 && other.x < maxX - 1e-6 && y < other.maxY - 1e-6
            && other.y < maxY - 1e-6
    }

    /// The part of this rectangle inside `outer`; an empty one when they do not meet.
    public func clamped(to outer: WallRect) -> WallRect {
        let left = min(max(x, outer.x), outer.maxX)
        let top = min(max(y, outer.y), outer.maxY)
        let right = min(max(maxX, left), outer.maxX)
        let bottom = min(max(maxY, top), outer.maxY)
        return WallRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// What the screen keeps for itself on each edge: the camera column, the home indicator, a rounded
/// corner. The ground bleeds under it and the content stays out of it.
public struct WallInsets: Sendable, Equatable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = WallInsets()
}

/// The division region of a folding screen, in points along x for a vertical fold and along y for a
/// horizontal one. Nothing is drawn or laid in it.
public struct WallFold: Sendable, Equatable {
    public enum Axis: Sendable { case vertical, horizontal }

    public var axis: Axis
    public var from: Double
    public var to: Double

    public init(axis: Axis, from: Double, to: Double) {
        self.axis = axis
        self.from = from
        self.to = to
    }

    var isUsable: Bool { to > from }
}

/// Where a session's own tile and its workers go inside the session's cell.
public struct WallSquadRects: Sendable, Equatable {
    public var parent: WallRect
    public var slots: [WallRect]
    public var more: WallRect?

    public init(parent: WallRect, slots: [WallRect], more: WallRect?) {
        self.parent = parent
        self.slots = slots
        self.more = more
    }
}

/// Where everything on the wall goes, from the screen's size, what it keeps, its fold and the wall
/// alone: every rectangle in points. Every size is a multiple of one unit, a hundredth of the shorter
/// side, so a phone, an iPad and a monitor read the same from where they are watched. The tiles'
/// places are Core's columns, rows and spans scaled to the grid; nothing here decides which tile goes
/// where.
public struct WallLayout: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case stack, side, book, laptop
    }

    public enum Alignment: Sendable, Equatable {
        case leading, trailing
    }

    public internal(set) var mode: Mode
    public internal(set) var width: Double
    public internal(set) var height: Double
    public internal(set) var unit: Double
    public internal(set) var headline: WallRect
    public internal(set) var headlineLines: Int
    public internal(set) var watchLine: WallRect
    public internal(set) var watchLines: Int
    public internal(set) var clock: WallRect
    public internal(set) var clockAlignment: Alignment
    public internal(set) var date: WallRect
    public internal(set) var grid: WallRect
    /// One cell per `wall.tiles` index.
    public internal(set) var tiles: [WallRect]
    public internal(set) var squads: [WallSquadRects?]
    public internal(set) var ribbon: WallRect?
    public internal(set) var recentRail: WallRect?
    public internal(set) var listedRail: WallRect?
    /// The laptop base's foot, 48 pt tall; nil in every other mode.
    public internal(set) var controls: WallRect?
    /// The calm orb's square.
    public internal(set) var centre: WallRect
    public internal(set) var calmLine: WallRect
    /// The two pages of a book, left then right; empty in every other mode.
    public internal(set) var pages: [WallRect]
    /// The space between cells, in points.
    public internal(set) var gutter: Double

    static let sideRatio = 1.35
    static let sideBelow = 560.0

    public static func unit(width: Double, height: Double) -> Double {
        max(1, min(width, height) / 100)
    }

    /// `units` hundredths of the shorter side as a type size, never below `floor`.
    public func type(_ units: Double, floor: Double = 11) -> Double {
        max(floor, units * unit)
    }

    static func chooseMode(width: Double, height: Double, fold: WallFold?) -> Mode {
        if let fold, fold.isUsable { return fold.axis == .vertical ? .book : .laptop }
        if height > 0, width / height >= sideRatio, height < sideBelow { return .side }
        return .stack
    }

    static func safeFrame(width: Double, height: Double, safe: WallInsets) -> WallRect {
        WallRect(
            x: safe.leading, y: safe.top, width: width - safe.leading - safe.trailing,
            height: height - safe.top - safe.bottom)
    }

    public static func make(
        width: Double, height: Double, safe: WallInsets, fold: WallFold?, wall: AgentWall,
        style: WallStyle, drift: (x: Double, y: Double) = (0, 0)
    ) -> WallLayout {
        var layout = chrome(
            width: width, height: height, safe: safe, fold: fold, style: style, drift: drift,
            roomy: wall.isCalm && wall.tiles.isEmpty)
        layout.place(wall, style: style)
        return layout
    }

    /// What to read the wall with so its grid suits the mode: the screen's shape for a stack, the
    /// grid area's own for a side or laptop base, and pages for a book.
    public static func reading(
        width: Double, height: Double, safe: WallInsets, fold: WallFold?, style: WallStyle
    ) -> (aspect: Double, gridAspect: Double, pages: Bool) {
        let layout = chrome(
            width: width, height: height, safe: safe, fold: fold, style: style, drift: (0, 0), roomy: false)
        let area = layout.grid.height > 0 ? layout.grid.width / layout.grid.height : 1
        switch layout.mode {
        case .stack: return (height > 0 ? width / height : 1, area, false)
        case .side, .laptop: return (area, area, false)
        case .book:
            let span = layout.pages.reduce(0) { $0 + $1.width }
            let aspect = layout.grid.height > 0 ? span / layout.grid.height : 1
            return (aspect, aspect, true)
        }
    }

    static func chrome(
        width: Double, height: Double, safe: WallInsets, fold: WallFold?, style: WallStyle,
        drift: (x: Double, y: Double), roomy: Bool
    ) -> WallLayout {
        let mode = Self.chooseMode(width: width, height: height, fold: fold)
        let frame = safeFrame(width: width, height: height, safe: safe)
        let unit = Self.unit(width: width, height: height)
        let ground = Ground(
            frame: frame, unit: unit, style: style, drift: drift, roomy: roomy, fold: fold)
        var layout: WallLayout
        switch mode {
        case .stack: layout = ground.stack()
        case .side: layout = ground.side()
        case .book: layout = ground.book()
        case .laptop: layout = ground.laptop()
        }
        layout.width = width
        layout.height = height
        layout.clampChrome(to: frame)
        return layout
    }

    mutating func clampChrome(to frame: WallRect) {
        headline = headline.clamped(to: frame)
        watchLine = watchLine.clamped(to: frame)
        clock = clock.clamped(to: frame)
        date = date.clamped(to: frame)
        grid = grid.clamped(to: frame)
        ribbon = ribbon?.clamped(to: frame)
        recentRail = recentRail?.clamped(to: frame)
        listedRail = listedRail?.clamped(to: frame)
        controls = controls?.clamped(to: frame)
        centre = centre.clamped(to: frame)
        calmLine = calmLine.clamped(to: frame)
        pages = pages.map { $0.clamped(to: frame) }
    }

    mutating func place(_ wall: AgentWall, style: WallStyle) {
        let columns = max(1, wall.columns)
        let rows = max(1, wall.rows)
        let cellHeight = max(0, (grid.height - gutter * Double(rows - 1)) / Double(rows))
        let cellWidth = max(0, (grid.width - gutter * Double(columns - 1)) / Double(columns))
        tiles = wall.tiles.map { tile in
            let top = grid.y + Double(tile.row) * (cellHeight + gutter)
            if mode == .book, !pages.isEmpty {
                let page = pages[min(max(0, tile.column), pages.count - 1)]
                return WallRect(x: page.x, y: top, width: page.width, height: cellHeight)
            }
            let span = Double(max(1, tile.span))
            return WallRect(
                x: grid.x + Double(tile.column) * (cellWidth + gutter), y: top,
                width: span * cellWidth + (span - 1) * gutter, height: cellHeight)
        }
        squads = zip(wall.tiles, tiles).map { tile, cell in
            guard style.showsSquads, let squad = tile.squad else { return nil }
            return WallSquadRects(
                parent: cell.inside(squad.parent), slots: squad.slots.map(cell.inside),
                more: squad.more.map(cell.inside))
        }
    }
}
